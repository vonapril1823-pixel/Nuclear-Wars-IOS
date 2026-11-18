import Foundation
import Capacitor
import Darwin

/// Same-hotspot discovery and pairing for Nuclear Wars Versus (iOS twin of NWLan.java).
/// UDP: a host broadcasts a small "lobby" note every second; other phones listen and show a list.
/// TCP: a joiner opens a line channel to the host to swap the WebRTC offer and answer.
/// The match itself still runs over WebRTC in the page. The JS side is identical to the Android app:
///   methods: udpListen, udpStop, udpBroadcast, tcpListen, tcpStopListen, tcpConnect, tcpSend, tcpClose, stopAll
///   events:  "udp" {ip, text}   "tcp" {id, kind: open|line|close, line?, ip?}
@objc(NWLan)
public class NWLan: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NWLan"
    public let jsName = "NWLan"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "udpListen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "udpStop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "udpBroadcast", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tcpListen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tcpStopListen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tcpConnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tcpSend", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "tcpClose", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopAll", returnType: CAPPluginReturnPromise)
    ]

    private let lock = NSLock()
    private var udpFd: Int32 = -1
    private var serverFd: Int32 = -1
    private var socks: [Int: Int32] = [:]
    private var nextId = 1

    // MARK: helpers

    private func emitUdp(_ ip: String, _ text: String) {
        DispatchQueue.main.async { self.notifyListeners("udp", data: ["ip": ip, "text": text]) }
    }

    private func emitTcp(_ id: Int, _ kind: String, _ line: String?, _ ip: String?) {
        var o: [String: Any] = ["id": id, "kind": kind]
        if let l = line { o["line"] = l }
        if let i = ip { o["ip"] = i }
        DispatchQueue.main.async { self.notifyListeners("tcp", data: o) }
    }

    private func makeAddr(_ port: Int, _ ip: String? = nil) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        if let ip = ip {
            inet_pton(AF_INET, ip, &a.sin_addr)
        } else {
            a.sin_addr.s_addr = in_addr_t(0)
        }
        return a
    }

    private func setOpt(_ fd: Int32, _ level: Int32, _ name: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, level, name, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private func bindFd(_ fd: Int32, _ port: Int) -> Bool {
        var a = makeAddr(port)
        let r = withUnsafePointer(to: &a) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    private func ipString(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN) + 1)
        inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    // MARK: UDP

    @objc func udpListen(_ call: CAPPluginCall) {
        let port = call.getInt("port", 47321)
        lock.lock()
        if udpFd >= 0 { lock.unlock(); call.resolve(); return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { lock.unlock(); call.reject("udp: socket failed"); return }
        setOpt(fd, SOL_SOCKET, SO_REUSEADDR)
        setOpt(fd, SOL_SOCKET, SO_REUSEPORT)
        setOpt(fd, SOL_SOCKET, SO_BROADCAST)
        if !bindFd(fd, port) { close(fd); lock.unlock(); call.reject("udp: bind failed"); return }
        udpFd = fd
        lock.unlock()

        let t = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n: Int = buf.withUnsafeMutableBytes { raw -> Int in
                    withUnsafeMutablePointer(to: &from) { fp -> Int in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                            recvfrom(fd, raw.baseAddress, raw.count, 0, sp, &fromLen)
                        }
                    }
                }
                if n < 0 { if errno == EINTR { continue }; break }
                guard let me = self else { break }
                let text = String(decoding: buf[0..<n], as: UTF8.self)
                me.emitUdp(me.ipString(from), text)
            }
        }
        t.name = "nwlan-udp"
        t.start()
        call.resolve()
    }

    @objc func udpStop(_ call: CAPPluginCall) {
        lock.lock()
        if udpFd >= 0 { shutdown(udpFd, SHUT_RDWR); close(udpFd); udpFd = -1 }
        lock.unlock()
        call.resolve()
    }

    @objc func udpBroadcast(_ call: CAPPluginCall) {
        let port = call.getInt("port", 47321)
        let text = call.getString("text", "")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let me = self else { return }
            let data = [UInt8](text.utf8)
            var sent = 0
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            if s >= 0 {
                me.setOpt(s, SOL_SOCKET, SO_BROADCAST)
                var ifap: UnsafeMutablePointer<ifaddrs>? = nil
                if getifaddrs(&ifap) == 0 {
                    var cur = ifap
                    while let p = cur {
                        let ifa = p.pointee
                        let flags = Int32(ifa.ifa_flags)
                        if (flags & IFF_UP) != 0 && (flags & IFF_BROADCAST) != 0 && (flags & IFF_LOOPBACK) == 0,
                           let a = ifa.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                           let d = ifa.ifa_dstaddr {
                            var dst = sockaddr_in()
                            memcpy(&dst, d, MemoryLayout<sockaddr_in>.size)
                            dst.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
                            let r = withUnsafePointer(to: &dst) { dp -> Int in
                                dp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    sendto(s, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                            if r >= 0 { sent += 1 }
                        }
                        cur = ifa.ifa_next
                    }
                    freeifaddrs(ifap)
                }
                if sent == 0 {
                    var dst = me.makeAddr(port, "255.255.255.255")
                    let r = withUnsafePointer(to: &dst) { dp -> Int in
                        dp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(s, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if r >= 0 { sent += 1 }
                }
                close(s)
            }
            call.resolve(["sent": sent])
        }
    }

    // MARK: TCP

    @objc func tcpListen(_ call: CAPPluginCall) {
        let port = call.getInt("port", 47322)
        lock.lock()
        if serverFd >= 0 { lock.unlock(); call.resolve(); return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { lock.unlock(); call.reject("tcp: socket failed"); return }
        setOpt(fd, SOL_SOCKET, SO_REUSEADDR)
        if !bindFd(fd, port) || listen(fd, 8) != 0 { close(fd); lock.unlock(); call.reject("tcp: bind failed"); return }
        serverFd = fd
        lock.unlock()

        let t = Thread { [weak self] in
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let c: Int32 = withUnsafeMutablePointer(to: &from) { fp -> Int32 in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
                }
                if c < 0 { if errno == EINTR { continue }; break }
                guard let me = self else { close(c); break }
                me.setOpt(c, SOL_SOCKET, SO_NOSIGPIPE)
                me.setOpt(c, IPPROTO_TCP, TCP_NODELAY)
                me.lock.lock()
                let id = me.nextId; me.nextId += 1
                me.socks[id] = c
                me.lock.unlock()
                me.emitTcp(id, "open", nil, me.ipString(from))
                me.startReader(id, c)
            }
        }
        t.name = "nwlan-accept"
        t.start()
        call.resolve()
    }

    @objc func tcpStopListen(_ call: CAPPluginCall) {
        lock.lock()
        if serverFd >= 0 { shutdown(serverFd, SHUT_RDWR); close(serverFd); serverFd = -1 }
        lock.unlock()
        call.resolve()
    }

    private func startReader(_ id: Int, _ fd: Int32) {
        let t = Thread { [weak self] in
            var pending = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n < 0 { if errno == EINTR { continue }; break }
                if n == 0 { break }
                pending.append(contentsOf: buf[0..<n])
                while let nl = pending.firstIndex(of: 10) {
                    var lineData = pending.subdata(in: pending.startIndex..<nl)
                    pending.removeSubrange(pending.startIndex...nl)
                    if lineData.last == 13 { lineData.removeLast() }
                    self?.emitTcp(id, "line", String(decoding: lineData, as: UTF8.self), nil)
                }
            }
            guard let me = self else { return }
            me.lock.lock()
            let had = me.socks.removeValue(forKey: id) != nil
            me.lock.unlock()
            if had { close(fd) }
            me.emitTcp(id, "close", nil, nil)
        }
        t.name = "nwlan-read-\(id)"
        t.start()
    }

    @objc func tcpConnect(_ call: CAPPluginCall) {
        let ip = call.getString("ip", "")
        let port = call.getInt("port", 47322)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let me = self else { return }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { call.reject("connect: socket failed"); return }
            me.setOpt(fd, SOL_SOCKET, SO_NOSIGPIPE)
            me.setOpt(fd, IPPROTO_TCP, TCP_NODELAY)
            var a = me.makeAddr(port, ip)
            if a.sin_addr.s_addr == 0 { close(fd); call.reject("connect: bad address"); return }
            let oldFlags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
            var ok = false
            let r = withUnsafePointer(to: &a) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if r == 0 {
                ok = true
            } else if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, 4000)
                if pr > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    ok = (err == 0)
                }
            }
            if !ok { close(fd); call.reject("connect: failed"); return }
            _ = fcntl(fd, F_SETFL, oldFlags)
            me.lock.lock()
            let id = me.nextId; me.nextId += 1
            me.socks[id] = fd
            me.lock.unlock()
            call.resolve(["id": id])
            me.startReader(id, fd)
        }
    }

    @objc func tcpSend(_ call: CAPPluginCall) {
        let id = call.getInt("id", -1)
        let line = (call.getString("line", "")).replacingOccurrences(of: "\n", with: " ") + "\n"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let me = self else { return }
            me.lock.lock(); let fd = me.socks[id]; me.lock.unlock()
            guard let f = fd else { call.reject("closed"); return }
            let bytes = [UInt8](line.utf8)
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { send(f, $0.baseAddress! + off, bytes.count - off, 0) }
                if n < 0 { if errno == EINTR { continue }; call.reject("send: failed"); return }
                off += n
            }
            call.resolve()
        }
    }

    @objc func tcpClose(_ call: CAPPluginCall) {
        let id = call.getInt("id", -1)
        lock.lock(); let fd = socks.removeValue(forKey: id); lock.unlock()
        if let f = fd { shutdown(f, SHUT_RDWR); close(f) }
        call.resolve()
    }

    @objc func stopAll(_ call: CAPPluginCall) {
        lock.lock()
        for (_, f) in socks { shutdown(f, SHUT_RDWR); close(f) }
        socks.removeAll()
        if serverFd >= 0 { shutdown(serverFd, SHUT_RDWR); close(serverFd); serverFd = -1 }
        if udpFd >= 0 { shutdown(udpFd, SHUT_RDWR); close(udpFd); udpFd = -1 }
        lock.unlock()
        call.resolve()
    }
}

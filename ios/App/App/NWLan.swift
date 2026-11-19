import Foundation
import UIKit
import Capacitor
import Darwin

/// Same-hotspot discovery and pairing for Nuclear Wars Versus (iPhone/iPad twin of the Android NWLan plugin).
/// UDP: hosts broadcast a small "lobby" note; phones listen. iOS only allows broadcast with Apple's multicast entitlement,
///      so `lanScan` also finds hosts by asking every address on the local subnet over TCP (no entitlement needed).
/// TCP: a joiner opens a line channel to the host to swap the WebRTC offer and answer. The match itself runs over WebRTC in the page.
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
        CAPPluginMethod(name: "lanScan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "keepAwake", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopAll", returnType: CAPPluginReturnPromise)
    ]

    private let lock = NSLock()
    private var udpFd: Int32 = -1
    private var serverFd: Int32 = -1
    private var socks: [Int: Int32] = [:]
    private var nextId = 1
    private let q = DispatchQueue(label: "nwlan.io", qos: .userInitiated, attributes: .concurrent)
    private let scanQ = DispatchQueue(label: "nwlan.scan", qos: .utility, attributes: .concurrent)

    // MARK: helpers
    private func setOpt(_ fd: Int32, _ level: Int32, _ name: Int32, _ v: Int32 = 1) {
        var x = v
        setsockopt(fd, level, name, &x, socklen_t(MemoryLayout<Int32>.size))
    }

    private func makeAddr(_ ip: String, _ port: Int) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
        return a
    }

    private func ipString(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private func bindAny(_ fd: Int32, _ port: Int) -> Bool {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(port).bigEndian
        a.sin_addr.s_addr = 0
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func register(_ fd: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId; nextId += 1; socks[id] = fd
        return id
    }

    private func emitTcp(_ id: Int, _ kind: String, _ line: String?, _ ip: String?) {
        var o: [String: Any] = ["id": id, "kind": kind]
        if let l = line { o["line"] = l }
        if let i = ip { o["ip"] = i }
        notifyListeners("tcp", data: o)
    }

    // MARK: UDP
    @objc func udpListen(_ call: CAPPluginCall) {
        let port = call.getInt("port") ?? 47321
        lock.lock(); let already = udpFd >= 0; lock.unlock()
        if already { call.resolve(); return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { call.reject("udp: socket"); return }
        setOpt(fd, SOL_SOCKET, SO_REUSEADDR); setOpt(fd, SOL_SOCKET, SO_REUSEPORT); setOpt(fd, SOL_SOCKET, SO_BROADCAST)
        if !bindAny(fd, port) { close(fd); call.reject("udp: bind"); return }
        lock.lock(); udpFd = fd; lock.unlock()
        q.async { [weak self] in self?.udpLoop(fd) }
        call.resolve()
    }

    private func udpLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock(); let alive = (udpFd == fd); lock.unlock()
            if !alive { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 500) <= 0 { continue }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) {
                notifyListeners("udp", data: ["ip": ipString(from), "text": text])
            }
        }
        close(fd)
    }

    @objc func udpStop(_ call: CAPPluginCall) {
        lock.lock(); udpFd = -1; lock.unlock()
        call.resolve()
    }

    @objc func udpBroadcast(_ call: CAPPluginCall) {
        let port = call.getInt("port") ?? 47321
        let text = call.getString("text") ?? ""
        q.async {
            var sent = 0
            let data = Array(text.utf8)
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            if fd >= 0 {
                self.setOpt(fd, SOL_SOCKET, SO_BROADCAST)
                var targets: [sockaddr_in] = []
                var ifap: UnsafeMutablePointer<ifaddrs>?
                if getifaddrs(&ifap) == 0 {
                    var cur = ifap
                    while let ifa = cur {
                        let fl = Int32(ifa.pointee.ifa_flags)
                        if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                           (fl & IFF_UP) != 0, (fl & IFF_BROADCAST) != 0, (fl & IFF_LOOPBACK) == 0,
                           let da = ifa.pointee.ifa_dstaddr {
                            var b = da.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                            b.sin_port = UInt16(port).bigEndian
                            targets.append(b)
                        }
                        cur = ifa.pointee.ifa_next
                    }
                    freeifaddrs(ifap)
                }
                if targets.isEmpty, let b = self.makeAddr("255.255.255.255", port) { targets.append(b) }
                for var t in targets {
                    let r = withUnsafePointer(to: &t) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if r >= 0 { sent += 1 }
                }
                close(fd)
            }
            call.resolve(["sent": sent])
        }
    }

    // MARK: TCP
    @objc func tcpListen(_ call: CAPPluginCall) {
        let port = call.getInt("port") ?? 47322
        lock.lock(); let already = serverFd >= 0; lock.unlock()
        if already { call.resolve(); return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { call.reject("tcp: socket"); return }
        setOpt(fd, SOL_SOCKET, SO_REUSEADDR)
        if !bindAny(fd, port) || listen(fd, 8) != 0 { close(fd); call.reject("tcp: bind"); return }
        lock.lock(); serverFd = fd; lock.unlock()
        q.async { [weak self] in self?.acceptLoop(fd) }
        call.resolve()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            lock.lock(); let alive = (serverFd == fd); lock.unlock()
            if !alive { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 500) <= 0 { continue }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if c < 0 { continue }
            setOpt(c, SOL_SOCKET, SO_NOSIGPIPE); setOpt(c, Int32(IPPROTO_TCP), TCP_NODELAY)
            let id = register(c)
            emitTcp(id, "open", nil, ipString(from))
            q.async { [weak self] in self?.readLoop(id, c) }
        }
        close(fd)
    }

    @objc func tcpStopListen(_ call: CAPPluginCall) {
        lock.lock(); serverFd = -1; lock.unlock()
        call.resolve()
    }

    private func readLoop(_ id: Int, _ fd: Int32) {
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            pending.append(buf, count: n)
            while let i = pending.firstIndex(of: 10) {
                let lineData = pending.subdata(in: pending.startIndex..<i)
                pending.removeSubrange(pending.startIndex..<(i + 1))
                if let s = String(data: lineData, encoding: .utf8) { emitTcp(id, "line", s, nil) }
            }
        }
        lock.lock(); socks.removeValue(forKey: id); lock.unlock()
        close(fd)
        emitTcp(id, "close", nil, nil)
    }

    private func connectTcp(_ ip: String, _ port: Int, _ timeoutMs: Int32) -> Int32? {
        guard var a = makeAddr(ip, port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        setOpt(fd, SOL_SOCKET, SO_NOSIGPIPE); setOpt(fd, Int32(IPPROTO_TCP), TCP_NODELAY)
        let fl = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 {
            if errno != EINPROGRESS { close(fd); return nil }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&p, 1, timeoutMs) <= 0 { close(fd); return nil }
            var err: Int32 = 0
            var l = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l)
            if err != 0 { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, fl)
        return fd
    }

    @objc func tcpConnect(_ call: CAPPluginCall) {
        let ip = call.getString("ip") ?? ""
        let port = call.getInt("port") ?? 47322
        q.async {
            guard let fd = self.connectTcp(ip, port, 4000) else { call.reject("connect: failed"); return }
            let id = self.register(fd)
            call.resolve(["id": id])
            self.q.async { self.readLoop(id, fd) }
        }
    }

    @objc func tcpSend(_ call: CAPPluginCall) {
        let id = call.getInt("id") ?? -1
        let line = (call.getString("line") ?? "").replacingOccurrences(of: "\n", with: " ") + "\n"
        q.async {
            self.lock.lock(); let fd = self.socks[id]; self.lock.unlock()
            guard let f = fd else { call.reject("closed"); return }
            let bytes = Array(line.utf8)
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBufferPointer { send(f, $0.baseAddress! + off, bytes.count - off, 0) }
                if n <= 0 { call.reject("send: failed"); return }
                off += n
            }
            call.resolve()
        }
    }

    @objc func tcpClose(_ call: CAPPluginCall) {
        let id = call.getInt("id") ?? -1
        lock.lock(); let fd = socks[id]; lock.unlock()
        if let f = fd { shutdown(f, SHUT_RDWR) } /* the read loop notices, closes the socket and reports "close" */
        call.resolve()
    }

    // MARK: subnet scan (finds hosts without needing UDP broadcast)
    private func localNets() -> [(ip: UInt32, mask: UInt32)] {
        var out: [(ip: UInt32, mask: UInt32)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        var cur = ifap
        while let ifa = cur {
            let fl = Int32(ifa.pointee.ifa_flags)
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
               (fl & IFF_UP) != 0, (fl & IFF_LOOPBACK) == 0, let nm = ifa.pointee.ifa_netmask {
                let name = String(cString: ifa.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") {
                    let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                    let mk = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                    if (ip >> 16) != 0xA9FE { out.append((ip: ip, mask: mk)) } /* skip 169.254.x.x */
                }
            }
            cur = ifa.pointee.ifa_next
        }
        freeifaddrs(ifap)
        return out
    }

    private func probe(_ host: UInt32, _ port: Int) {
        let ip = "\((host >> 24) & 255).\((host >> 16) & 255).\((host >> 8) & 255).\(host & 255)"
        guard let fd = connectTcp(ip, port, 700) else { return }
        defer { close(fd) }
        let ask = Array("{\"t\":\"probe\"}\n".utf8)
        if send(fd, ask, ask.count, 0) <= 0 { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        var got = Data()
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 1.2 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 300) > 0 {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                got.append(buf, count: n)
                if got.contains(10) { break }
            }
        }
        if let i = got.firstIndex(of: 10), let s = String(data: got.subdata(in: got.startIndex..<i), encoding: .utf8) {
            notifyListeners("udp", data: ["ip": ip, "text": s, "scan": true])
        }
    }

    @objc func lanScan(_ call: CAPPluginCall) {
        let port = call.getInt("port") ?? 47322
        scanQ.async {
            var cands: [UInt32] = []
            for n in self.localNets() {
                let mask = n.mask | 0xFFFFFF00 /* never sweep more than one /24 */
                let net = n.ip & mask
                let bcast = net | ~mask
                var h = net + 1
                while h < bcast { if h != n.ip { cands.append(h) }; h += 1 }
            }
            let sem = DispatchSemaphore(value: 24)
            let group = DispatchGroup()
            for h in cands {
                sem.wait(); group.enter()
                self.scanQ.async { defer { sem.signal(); group.leave() }; self.probe(h, port) }
            }
            group.wait()
            call.resolve(["scanned": cands.count])
        }
    }

    // MARK: misc
    @objc func keepAwake(_ call: CAPPluginCall) {
        let on = call.getBool("on") ?? true
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
        call.resolve()
    }

    @objc func stopAll(_ call: CAPPluginCall) {
        lock.lock()
        for (_, fd) in socks { shutdown(fd, SHUT_RDWR) }
        udpFd = -1; serverFd = -1
        lock.unlock()
        call.resolve()
    }
}

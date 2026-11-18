import UIKit
import Capacitor

/// Hosts the game page full screen, landscape only, and registers the local NWLan plugin.
class ViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(NWLan())
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }
}

import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct TmpCI {
    @Test("tmp ci rail move", arguments: [80, 250])
    func ciRailMove(duration: Int) {
        let result = Scenario.run("tmp ci duration=\(duration)") { s in
            s.mac.setScreen(ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 737)))
            let app = s.mac.launch()
            let ids = (0..<5).map { _ in app.open(WindowSpec(frame: CGRect(x: 100, y: 100, width: 1024 * 0.45, height: 400), positionAcceptance: .screenEdges)) }
            app.select(ids[0])
            let tessel = s.startTessel(); s.settle()
            tessel.changeConfig("[experiments]\ncarousel = true\n[animation]\nduration = \(duration)\n"); s.settle()
            print("TMP setup", ids.map { s.mac.frame($0)! }, "focus", String(describing: s.mac.focusedWindow))
            tessel.pressKey("alt-shift-j"); s.settle()
            print("TMP after", ids.map { (s.mac.frame($0)!, s.mac.isVisible($0)) }, "focus", String(describing: s.mac.focusedWindow), "front", String(describing: s.mac.frontmostApp), tessel.windows.map { "\($0.id) rail=\(String(describing: $0.rail))" })
        }
        print("TMP failures", result.failures.prefix(3))
    }
}

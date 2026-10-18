import Foundation
import CoreGraphics
import Simulator
@testable import Policy

@MainActor struct RailFixture {
    let scenario: Scenario
    let app: SimulatedApp
    let tessel: Tessel
    let ids: [UInt32]
    let area: CGRect
    var mac: SimulatedMac { scenario.mac }

    init(_ scenario: Scenario, widths: [Double] = [0.3, 0.3, 0.3]) {
        self.scenario = scenario
        let mac = scenario.mac
        let screen = mac.screens.primaryScreen!
        let area = CGRect(x: screen.visibleFrame.minX + 10,
                      y: screen.frame.height - screen.visibleFrame.maxY + 10,
                      width: screen.visibleFrame.width - 20, height: screen.visibleFrame.height - 20)
        self.area = area
        let app = mac.launch()
        self.app = app
        ids = widths.map { app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: floor(area.width * $0), height: 400))) }
        if let first = ids.first { app.select(first) }
        tessel = scenario.startTessel()
        scenario.settle()
        tessel.configure(.rails)
        scenario.settle()
        scenario.expect("setup: every opened window is listed", tessel.windows.map(\.id) == ids)
        if let first = ids.first { focus(first) }
    }

    func press(_ command: String, focus id: UInt32? = nil) {
        scenario.step(command) { tessel.press(command) }
        scenario.settle()
        if let id { focus(id) }
    }
    func select(_ id: UInt32) {
        scenario.step("external selection of window \(id)") { app.select(id) }
        scenario.settle()
        focus(id)
    }
    func focus(_ id: UInt32) {
        scenario.expect("window \(id) has focus (actual \(mac.focusedWindow.map(String.init) ?? "none"))", mac.focusedWindow == id)
        scenario.expect("window \(id) is fully visible", mac.isFullyOnScreen(id))
    }
    func order(_ ids: [UInt32], rail: Int = 1, workspace: Int = 1) {
        let actual = tessel.windows.filter { $0.workspace == workspace && $0.rail == rail }.sorted { $0.slot! < $1.slot! }
        scenario.expect("workspace \(workspace) rail \(rail) order is \(ids), actual \(actual.map(\.id))", actual.map(\.id) == ids)
        scenario.expect("slots are contiguous", actual.enumerated().allSatisfy { $0.element.slot == $0.offset + 1 })
    }
    func frame(_ id: UInt32) -> CGRect { mac.frame(id)! }
    func frames(_ ids: [UInt32]) -> [CGRect] { ids.map(frame) }
    func near(_ actual: Double, _ expected: Double, _ message: String) {
        scenario.expect("\(message): expected \(expected), actual \(actual)", abs(actual - expected) <= 1)
    }
    func unchanged(_ ids: [UInt32], _ before: [CGRect]) {
        for (id, expected) in zip(ids, before) {
            let actual = frame(id)
            near(actual.minX, expected.minX, "window \(id) x stays")
            near(actual.minY, expected.minY, "window \(id) y stays")
            near(actual.width, expected.width, "window \(id) width stays")
            near(actual.height, expected.height, "window \(id) height stays")
        }
    }
    func invariants(_ ids: [UInt32], sizes: [CGSize]) {
        for (id, size) in zip(ids, sizes) {
            let frame = frame(id)
            near(frame.width, size.width, "window \(id) keeps width")
            near(frame.height, size.height, "window \(id) keeps height")
            scenario.expect("window \(id) stays below the menu bar", frame.minY >= area.minY - 10 - 1)
            if mac.isVisible(id) {
                for other in ids where other > id && mac.isVisible(other) {
                    scenario.expect("visible windows \(id) and \(other) do not overlap", !frame.intersects(self.frame(other)))
                }
            } else {
                scenario.expect("off-screen window \(id) is in the closet", mac.isInCloset(id))
            }
        }
    }
}

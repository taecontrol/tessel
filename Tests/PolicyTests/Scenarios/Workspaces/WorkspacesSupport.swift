import Foundation
import CoreGraphics
import Simulator
@testable import Policy

@MainActor enum WorkspaceScenarios {
    static let enabled = "[experiments]\nworkspaces = true\n"

    static func row(_ tessel: Tessel, _ id: UInt32) -> WindowRecord? { tessel.windows.first { $0.id == id } }

    static func area(_ mac: SimulatedMac, gap: Double = 10) -> CGRect {
        let screen = mac.screenGeometry
        let frame = screen.visibleFrame
        return CGRect(x: frame.minX + gap, y: screen.frame.height - frame.maxY + gap,
                      width: frame.width - 2 * gap, height: frame.height - 2 * gap)
    }

    static func shown(_ scenario: Scenario, _ id: UInt32, gap: Double = 10, floating: Bool = false, sheet: UInt32? = nil) {
        let mac = scenario.mac
        scenario.expect("window \(id) is visible", mac.isVisible(id))
        scenario.expect("window \(id) is main", mac.isMain(id))
        scenario.expect("window \(sheet ?? id) has focus (actual \(mac.focusedWindow.map(String.init) ?? "none"))", mac.focusedWindow == (sheet ?? id))
        if !floating {
            let expected = area(mac, gap: gap)
            let actual = mac.frame(id) ?? .zero
            scenario.expect("window \(id) fills \(expected) within one point (actual \(actual))",
                            abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1
                                && abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1)
        }
    }

    static func press(_ scenario: Scenario, _ tessel: Tessel, _ command: String, shown id: UInt32? = nil,
                      floating: Bool = false, sheet: UInt32? = nil) {
        scenario.step(command) { tessel.press(command) }
        scenario.settle()
        if let id { shown(scenario, id, floating: floating, sheet: sheet) }
    }

    static func empty(_ scenario: Scenario) {
        scenario.expect("no managed window is visible", scenario.mac.visibleOrder.isEmpty)
        scenario.expect("Finder's desktop owns focus", scenario.mac.frontmostApp == scenario.mac.finder.pid)
    }

    static func split(_ scenario: Scenario) -> (SimulatedApp, Tessel) {
        let app = scenario.mac.launch(windows: 2)
        let tessel = scenario.startTessel(.stack)
        scenario.settle()
        shown(scenario, 2)
        press(scenario, tessel, "send 2", shown: 2)
        press(scenario, tessel, "workspace 1", shown: 1)
        return (app, tessel)
    }
}

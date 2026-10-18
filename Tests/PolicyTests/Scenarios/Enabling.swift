import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@MainActor enum EnablingScenarios {
    enum Step: String, CaseIterable, Sendable { case select, read, deliver, enable }
    static var schedules: [OrderedSteps<Step>] {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        return mac.orders(of: Step.allCases, requiring: [.init(.select, before: .read), .init(.read, before: .deliver)])
    }

    static func run(_ order: OrderedSteps<Step>, layout: Layout) -> ScenarioResult {
        Scenario.run("enable \(layout.rawValue)", writes: order.writes) { scenario in
            let mac = scenario.mac
            let app = mac.launch(windows: 3)
            let tessel = scenario.startTessel()
            scenario.settle()
            scenario.expect("setup: production catalog lists all three windows", tessel.windows.map(\.id) == [1, 2, 3])
            scenario.expect("setup: window 3 has native focus", mac.focusedWindow == 3)
            for step in order.steps {
                switch step {
                case .select: scenario.step("user selects window 1") { app.select(1) }
                case .read:
                    scenario.step("read app-A taken, not delivered") {
                        let outcome = mac.pause(after: .read(app))
                        if case .paused = outcome {} else { scenario.expect("expected captured read, got \(outcome)", false) }
                    }
                case .deliver:
                    scenario.step("deliver app-A read") {
                        let outcome = mac.deliver(app)
                        if case .paused = outcome {} else { scenario.expect("expected delivered read, got \(outcome)", false) }
                    }
                case .enable: scenario.step("enable \(layout.rawValue)") { tessel.configure(layout) }
                }
            }
            scenario.settle()
            scenario.expect("window 1 ends focused (actual \(mac.focusedWindow.map(String.init) ?? "none"))", mac.focusedWindow == 1)
            scenario.expect("window 1 ends fully visible (frame \(mac.frame(1).map(String.init(describing:)) ?? "none"))", mac.isFullyOnScreen(1))
        }
    }
}

@Suite @MainActor struct Enabling {
    @Test("#2 E2; #17 E2: startup and enabling preserve membership, native focus, rail widths and arrival order",
          arguments: [false, true], [Layout.stack, .rails])
    func existingWindows(startup: Bool, layout: Layout) {
        for secondWidth in [0.4, 1.2] {
            requireScenario(Scenario.run("existing windows startup=\(startup) layout=\(layout) width=\(secondWidth)") { scenario in
                let mac = scenario.mac, area = WorkspaceScenarios.area(mac)
                let app = mac.launch()
                let first = app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: floor(area.width * 0.25), height: 400)))
                let second = app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: floor(area.width * secondWidth), height: 400)))
                app.select(first)
                let widths = [mac.frame(first)!.width, mac.frame(second)!.width]
                let tessel = scenario.startTessel(startup ? layout : .off)
                scenario.settle()
                if !startup { tessel.configure(layout); scenario.settle() }
                scenario.expect("every existing window belongs to workspace 1", tessel.windows.count == 2 && tessel.windows.allSatisfy { $0.workspace == 1 })
                scenario.expect("workspace 1 and the native selection remain active", tessel.status.active == 1 && mac.focusedWindow == first)
                if layout == .stack {
                    WorkspaceScenarios.shown(scenario, first)
                    scenario.expect("the other stack window is hidden", !mac.isVisible(second))
                } else {
                    let rows = tessel.windows.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }
                    scenario.expect("one rail keeps arrival order", rows.map(\.id) == [first, second] && rows.map(\.rail) == [1, 1] && rows.map(\.slot) == [1, 2])
                    for (index, id) in [first, second].enumerated() {
                        let frame = mac.frame(id)!
                        scenario.expect("window \(id) keeps its width capped at the rail area", frame.width == min(widths[index], area.width))
                        scenario.expect("window \(id) takes the rail height and top", frame.height == area.height && frame.minY == area.minY)
                        scenario.expect("window \(id) starts in arrival order", frame.minX == area.minX + (index == 0 ? 0 : widths[0] + 10))
                    }
                }
            })
        }
    }

    @Test("#17 E2; #2 E2: enabling preserves native selection under every allowed order", arguments: [Layout.rails, .stack])
    func enabling(layout: Layout) {
        let schedules = EnablingScenarios.schedules
        #expect(schedules.count == 12)
        for schedule in schedules { requireScenario(EnablingScenarios.run(schedule, layout: layout)) }
    }

    @Test("#17 E2; #2 E2: enabling immediately before selection keeps the unread selection", arguments: [Layout.rails, .stack])
    func enableBeforeSelect(layout: Layout) {
        // This order was absent from the CI failures that exposed 6b80843.
        let schedule = EnablingScenarios.schedules.first { $0.steps == [.enable, .select, .read, .deliver] && $0.writes == .writesFirst }!
        requireScenario(EnablingScenarios.run(schedule, layout: layout))
    }
}

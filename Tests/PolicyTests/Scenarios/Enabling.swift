import Foundation
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

import Simulator
import Testing

@Suite @MainActor struct DiagnosticFramework {
    @Test("E5: a returned failure report carries expectation, schedule, and private trace")
    func failureReport() {
        let result = Scenario.run("deliberate failing scenario") { scenario in
            let app = scenario.mac.launch(windows: 1)
            _ = scenario.startTessel()
            scenario.settle()
            scenario.step("user selects window 1") { app.select(1) }
            scenario.settle()
            scenario.expect("window 2 must have focus", scenario.mac.focusedWindow == 2)
        }
        #expect(result.failures == ["window 2 must have focus"])
        #expect(result.report.contains("Expectation: window 2 must have focus"))
        #expect(result.report.contains("Schedule:"))
        #expect(result.report.contains("user selects window 1"))
        #expect(result.report.contains("Trace:"))
        #expect(result.report.contains("ms]"))
        #expect(result.report.contains("window 1 app-A"))
        #expect(!result.report.contains("AXTitle"))
        #expect(!result.report.contains("Finder"))
        #expect(!result.report.contains("Application "))
    }
}

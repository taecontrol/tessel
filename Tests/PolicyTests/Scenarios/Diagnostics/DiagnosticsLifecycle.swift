import Ports
import Simulator
import Testing
@testable import Policy

extension DiagnosticsScenarios {
    @Test("policy enablement and app lifecycle record once with the terminated window count")
    func lifecycleRecordsObservedApps() {
        requireCarousel(Scenario.run("diagnostic lifecycle of an observed application") { s in
            let tessel = s.startTessel()
            s.settle()
            s.expect("initial enablement is recorded once", s.mac.diagnosticEvents.filter { $0.diagnostic == .enabled }.count == 1)
            s.mac.clearDiagnosticHistory()
            // Opening the initial windows delivers activation before launch.
            // The catalog must still record the eventual launch notification.
            let app = s.mac.launch(windows: 2)
            s.settle()
            let bundle = tessel.windows.first { $0.id == app.windows[0] }!.bundleId
            app.activate()
            s.settle()
            app.quit()
            s.settle()
            let lifecycle = s.mac.diagnosticEvents.map(\.diagnostic).filter {
                switch $0 { case .appLaunched, .appTerminated: true; default: false }
            }
            s.expect("activation is not another launch and termination retains the old window count; actual \(lifecycle)", lifecycle == [
                .appLaunched(pid: app.pid, bundleID: bundle), .appTerminated(pid: app.pid, bundleID: bundle, windows: 2),
            ])
        })
    }

}

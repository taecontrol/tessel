import Ports
import Simulator
import Testing
@testable import Policy

extension DiagnosticsScenarios {
    @Test("a command ignored while the pointer is held still records its receipt without applying it")
    func heldPointerCommandRecordsReceipt() {
        requireCarousel(Scenario.run("diagnostic for a command ignored during a drag") { s in
            let f = RailFixture(s, widths: [0.3, 0.3])
            f.mac.pointerDown()
            f.mac.clearDiagnosticHistory()
            let receipt = Diagnostic.command("workspace 2", workspace: 1, rail: 1, focused: f.ids[0])
            f.tessel.press("workspace 2")
            s.expect("the ignored key records one receipt immediately", f.mac.diagnosticEvents.map(\.diagnostic) == [receipt])
            s.settle()
            f.mac.pointerUp()
            s.settle()
            let commands = f.mac.diagnosticEvents.map(\.diagnostic).filter { if case .command = $0 { true } else { false } }
            s.expect("the ignored command never executes or records twice", f.tessel.status.active == 1 && commands == [receipt])
        })
    }
}

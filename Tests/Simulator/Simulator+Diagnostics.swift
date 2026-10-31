import Ports

extension SimulatedMac {
    package struct DiagnosticEvent: Equatable, Sendable {
        package let at: Int
        package let diagnostic: Diagnostic
    }

    package var diagnostics: any DiagnosticsPort { Diagnostics(mac: self) }
    @MainActor package var diagnosticEvents: [DiagnosticEvent] { diagnosticHistory }
    @MainActor package func clearDiagnosticHistory() { diagnosticHistory.removeAll() }

    private struct Diagnostics: DiagnosticsPort {
        let mac: SimulatedMac

        func record(_ diagnostic: Diagnostic) {
            // Only the baton holder touches simulator state, on main or an AX
            // lane. Logging must never call scheduler.call or submit work.
            mac.diagnosticHistory.append(DiagnosticEvent(at: mac.scheduler.now, diagnostic: diagnostic))
            mac.scheduler.note("diagnostic \(diagnostic)")
        }
    }
}

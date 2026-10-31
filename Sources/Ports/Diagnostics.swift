// Payloads contain identifiers and Tessel's vocabulary, never AX text.
package enum Diagnostic: Equatable, Sendable {
    case started(version: String, permission: Bool, config: String)
    case enabled, disabled(reason: String), quit
    case appLaunched(pid: Int32, bundleID: String)
    case appTerminated(pid: Int32, bundleID: String, windows: Int)
    case command(String, workspace: Int, rail: Int?, focused: UInt32?)
    case window(WindowChange, after: String)
    case focus(from: UInt32?, to: UInt32?, after: String)
    case readFailed(pid: Int32, bundleID: String, attempts: Int)
    case configLoaded(state: String, revision: UInt64)
    case configError(line: Int, message: String)

    package var level: DiagnosticLevel {
        switch self {
        case .disabled, .readFailed, .configError: .error
        default: .notice
        }
    }
}

package enum DiagnosticLevel: Sendable { case notice, error }

package enum WindowChange: Equatable, Sendable {
    case appeared(DiagnosticWindow)
    case changed(from: DiagnosticWindow, to: DiagnosticWindow)
    case gone(DiagnosticWindow)
}

package struct DiagnosticWindow: Equatable, Sendable {
    package let id: UInt32
    package let pid: Int32
    package let bundleID: String
    package let state: String
    package let reason: String
    package let workspace: Int?
    package let rail: Int?
    package let slot: Int?
    package let visible: Bool

    package init(id: UInt32, pid: Int32, bundleID: String, state: String, reason: String,
                 workspace: Int?, rail: Int?, slot: Int?, visible: Bool) {
        self.id = id; self.pid = pid; self.bundleID = bundleID
        self.state = state; self.reason = reason; self.workspace = workspace
        self.rail = rail; self.slot = slot; self.visible = visible
    }
}

package protocol DiagnosticsPort: Sendable {
    func record(_ diagnostic: Diagnostic)
}

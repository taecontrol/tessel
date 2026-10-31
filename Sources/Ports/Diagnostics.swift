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
    case system(DiagnosticSystemEvent)

    package var level: DiagnosticLevel {
        switch self {
        case .disabled, .readFailed, .configError: .error
        default: .notice
        }
    }

    package var category: DiagnosticCategory {
        switch self {
        case .started, .enabled, .disabled, .quit: .lifecycle
        case .appLaunched, .appTerminated, .readFailed: .apps
        case .command: .commands
        case .window, .focus: .windows
        case .configLoaded, .configError: .config
        case .system: .system
        }
    }

    package var text: String {
        switch self {
        case let .started(version, permission, config):
            "started version \(version), permission \(permission ? "granted" : "needed"), config \(config)"
        case .enabled: "enabled"
        case .disabled(let reason): "disabled: \(reason)"
        case .quit: "quit"
        case let .appLaunched(pid, bundle): "app launched \(bundle) pid \(pid)"
        case let .appTerminated(pid, bundle, windows): "app terminated \(bundle) pid \(pid), \(windows) windows"
        case let .command(command, workspace, rail, focused):
            "command \(command), workspace \(workspace), rail \(rail.map(String.init) ?? "none"), focused \(focused.map(String.init) ?? "none")"
        case let .window(change, after):
            switch change {
            case .appeared(let window):
                "window \(window.identity) appeared \(window.classification), \(window.location), visible \(window.visible), \(after)"
            case let .changed(from, to):
                "window \(to.identity) changed from \(from.classification), \(from.location), visible \(from.visible) to \(to.classification), \(to.location), visible \(to.visible), \(after)"
            case .gone(let window):
                "window \(window.identity) gone from \(window.location), \(window.classification), visible \(window.visible), \(after)"
            }
        case let .focus(from, to, after):
            "focus \(from.map(String.init) ?? "none") -> \(to.map(String.init) ?? "none"), \(after)"
        case let .readFailed(pid, bundle, attempts): "read failed \(bundle) pid \(pid) after \(attempts) attempts"
        case let .configLoaded(state, revision): "config loaded, state \(state), revision \(revision)"
        case let .configError(line, message): "config error line \(line): \(message)"
        case .system(let event):
            switch event {
            case .screenLocked: "screen locked"
            case .screenUnlocked: "screen unlocked"
            case .screenSaverStarted: "screen saver started"
            case .screenSaverStopped: "screen saver stopped"
            case .screensSlept: "screens slept"
            case .screensWoke: "screens woke"
            case .slept: "sleep"
            case .woke: "wake"
            case .sessionResigned: "session resigned active"
            case .sessionBecameActive: "session became active"
            case .spaceChanged: "active Space changed"
            case .screenParametersChanged: "screen parameters changed"
            }
        }
    }
}

package enum DiagnosticLevel: Sendable { case notice, error }
package enum DiagnosticCategory: String, CaseIterable, Sendable { case lifecycle, apps, commands, windows, config, system }
package enum DiagnosticSystemEvent: Sendable {
    case screenLocked, screenUnlocked, screenSaverStarted, screenSaverStopped
    case screensSlept, screensWoke, slept, woke, sessionResigned, sessionBecameActive, spaceChanged, screenParametersChanged
}

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

    fileprivate var identity: String { "\(id) (\(bundleID)) pid \(pid)" }
    fileprivate var classification: String { "\(state) (\(reason))" }
    fileprivate var location: String {
        "workspace \(workspace.map(String.init) ?? "none"), rail \(rail.map(String.init) ?? "none"), slot \(slot.map(String.init) ?? "none")"
    }
}

package protocol DiagnosticsPort: Sendable {
    func record(_ diagnostic: Diagnostic)
}

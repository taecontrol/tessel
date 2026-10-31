import Foundation
#if SWIFT_PACKAGE
import Ports
#endif

/// Compares publications, so membership changes have one logging home even
/// when they complete in a later render callback. Recording never schedules.
@MainActor
final class DiagnosticJournal {
    enum Trigger {
        case command(WorkspaceCommand), snapshot(pid: Int32, bundleID: String), appTerminated(pid: Int32, bundleID: String)
        case pointerRelease, config, enable, disable

        var after: String {
            switch self {
            case .command(let command): "after command \(command.text)"
            case let .snapshot(pid, bundle): "after snapshot \(bundle.isEmpty ? "pid \(pid)" : bundle)"
            case let .appTerminated(pid, bundle): "after app terminated \(bundle.isEmpty ? "pid \(pid)" : bundle)"
            case .pointerRelease: "after pointer release"
            case .config: "after config"
            case .enable: "after enable"
            case .disable: "after disable"
            }
        }
    }

    private let port: any DiagnosticsPort
    private var windows: [UInt32: DiagnosticWindow] = [:]
    private var focused: UInt32?
    private var finished = false
    var trigger = Trigger.enable

    init(port: any DiagnosticsPort) { self.port = port }

    func published(_ rows: [Int32: [WindowRecord]], focused nextFocus: UInt32?) {
        guard !finished else { return }
        var next: [UInt32: DiagnosticWindow] = [:]
        for (pid, records) in rows {
            for row in records {
                next[row.id] = DiagnosticWindow(id: row.id, pid: pid, bundleID: row.bundleId, state: row.state.rawValue,
                                                reason: row.reason, workspace: row.workspace, rail: row.rail,
                                                slot: row.slot, visible: row.visible)
            }
        }
        let after = trigger.after
        for id in Set(windows.keys).union(next.keys).sorted() {
            switch (windows[id], next[id]) {
            case let (nil, window?): port.record(.window(.appeared(window), after: after))
            case let (window?, nil): port.record(.window(.gone(window), after: after))
            case let (before?, window?):
                if before.state != window.state || before.reason != window.reason || before.workspace != window.workspace
                    || before.rail != window.rail || before.visible != window.visible {
                    port.record(.window(.changed(from: before, to: window), after: after))
                }
            case (nil, nil): break
            }
        }
        windows = next
        if focused != nextFocus { port.record(.focus(from: focused, to: nextFocus, after: after)) }
        focused = nextFocus
    }

    func finish() {
        guard !finished else { return }
        finished = true
        port.record(.quit)
    }
}

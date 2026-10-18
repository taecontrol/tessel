import AppKit

/// SPIKE (deterministic policy): the system facts and effects workspace policy
/// reads directly. The app uses the real system; a simulator substitutes it.
@MainActor
protocol WorkspaceSystem {
    var frontmostPID: pid_t? { get }
    var runningPIDs: [pid_t] { get }
    /// The main screen's frame and visible frame, in AppKit coordinates.
    var screen: (frame: CGRect, visibleFrame: CGRect)? { get }
    func onScreenOrder() -> [UInt32]
    func isRunning(_ pid: pid_t) -> Bool
    func after(milliseconds: Int, _ item: DispatchWorkItem)
    func activateDesktop(_ activate: () -> Void)
}

extension WorkspaceSystem {
    func after(milliseconds: Int, _ work: @escaping @MainActor () -> Void) {
        after(milliseconds: milliseconds, DispatchWorkItem { MainActor.assumeIsolated { work() } })
    }
}

struct RealWorkspaceSystem: WorkspaceSystem {
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var runningPIDs: [pid_t] { NSWorkspace.shared.runningApplications.map(\.processIdentifier) }
    var screen: (frame: CGRect, visibleFrame: CGRect)? { NSScreen.screens.first.map { ($0.frame, $0.visibleFrame) } }
    func onScreenOrder() -> [UInt32] {
        // Only IDs survive this query. Drain Objective-C bridge temporaries
        // without waiting for AppKit's next input event on the main thread.
        autoreleasepool {
            (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
    }
    func isRunning(_ pid: pid_t) -> Bool { !(kill(pid, 0) == -1 && errno == ESRCH) }
    func after(milliseconds: Int, _ item: DispatchWorkItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
    }
    func activateDesktop(_ activate: () -> Void) { activate() }
}

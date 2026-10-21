import AppKit

@MainActor
struct SystemApplications: ApplicationPort {
    var ownPID: Int32 { getpid() }
    var runningApplications: [RunningApplication] { NSWorkspace.shared.runningApplications.map(Self.info) }
    var frontmostPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func application(_ pid: Int32) -> RunningApplication? { NSRunningApplication(processIdentifier: pid).map(Self.info) }
    func applications(bundleID: String) -> [RunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(Self.info)
    }
    func observe(_ receive: @escaping @MainActor (ApplicationEvent, RunningApplication) -> Void) -> any ApplicationObservation {
        SystemApplicationObservation(receive: receive)
    }
    func activate(_ pid: Int32) { NSRunningApplication(processIdentifier: pid)?.activate() }
    func isAlive(_ pid: Int32) -> Bool { !(kill(pid, 0) == -1 && errno == ESRCH) }
    static func info(_ app: NSRunningApplication) -> RunningApplication {
        RunningApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName,
                           hidden: app.isHidden, terminated: app.isTerminated, prohibited: app.activationPolicy == .prohibited)
    }
}

@MainActor
private final class SystemApplicationObservation: NSObject, ApplicationObservation {
    private let receive: @MainActor (ApplicationEvent, RunningApplication) -> Void
    init(receive: @escaping @MainActor (ApplicationEvent, RunningApplication) -> Void) {
        self.receive = receive
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }
    @objc private func changed(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let event: ApplicationEvent
        switch notification.name {
        case NSWorkspace.didLaunchApplicationNotification: event = .launched
        case NSWorkspace.didActivateApplicationNotification: event = .activated
        case NSWorkspace.didHideApplicationNotification: event = .hidden
        case NSWorkspace.didUnhideApplicationNotification: event = .unhidden
        default: event = .terminated
        }
        receive(event, SystemApplications.info(app))
    }
}

@MainActor
struct SystemScreen: ScreenPort {
    var primaryScreen: ScreenGeometry? { NSScreen.screens.first.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) } }
}

@MainActor
struct SystemWindowOrder: WindowOrderPort {
    // The acceptance-first change exposes the seam; the native read arrives
    // with the catalog behavior that consumes it.
    nonisolated func windowLevels() -> [UInt32: Int] { [:] }

    func onScreenOrder() -> [UInt32] {
        // Drain bridge temporaries without waiting for AppKit's next input event.
        autoreleasepool {
            (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
    }
}

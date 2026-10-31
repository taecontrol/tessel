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
    private var runningApplicationObservation: NSKeyValueObservation?
    private var runningApplications: [NSRunningApplication] = []
    init(receive: @escaping @MainActor (ApplicationEvent, RunningApplication) -> Void) {
        self.receive = receive
        super.init()
        // The catalog enumerates existing apps at startup. Only later PID
        // changes are lifecycle events, including apps that never activate.
        runningApplications = NSWorkspace.shared.runningApplications
        runningApplicationObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applicationsChanged(NSWorkspace.shared.runningApplications) }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }

    private func applicationsChanged(_ current: [NSRunningApplication]) {
        let previous = runningApplications
        runningApplications = current
        // Read the complete list rather than trusting KVO's change kind or
        // indexed payload. Replacing an array does not relaunch its survivors.
        let oldPIDs = Set(previous.map(\.processIdentifier)), newPIDs = Set(current.map(\.processIdentifier))
        for app in current where !oldPIDs.contains(app.processIdentifier) {
            receive(.launched, SystemApplications.info(app))
        }
        for app in previous where !newPIDs.contains(app.processIdentifier) {
            receive(.terminated, SystemApplications.info(app))
        }
    }

    @objc private func changed(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let event: ApplicationEvent
        switch notification.name {
        case NSWorkspace.didActivateApplicationNotification: event = .activated
        case NSWorkspace.didHideApplicationNotification: event = .hidden
        case NSWorkspace.didUnhideApplicationNotification: event = .unhidden
        default: return
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
    nonisolated func listings(_ windows: Set<UInt32>) -> [UInt32: WindowListing] { WindowServerListings.read(windows) }

    nonisolated func windowLevels(_ windows: Set<UInt32>) -> [UInt32: Int] {
        guard !windows.isEmpty else { return [:] }
        return autoreleasepool {
            var pointers: [UnsafeRawPointer?] = windows.sorted().map { UnsafeRawPointer(bitPattern: UInt($0)) }
            let array = CFArrayCreate(nil, &pointers, pointers.count, nil)
            let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
            return Dictionary(uniqueKeysWithValues: descriptions.compactMap { row in
                guard let id = row[kCGWindowNumber as String] as? UInt32,
                      let level = row[kCGWindowLayer as String] as? Int else { return nil }
                return (id, level)
            })
        }
    }

    func onScreenOrder() -> [UInt32] {
        // Drain bridge temporaries without waiting for AppKit's next input event.
        autoreleasepool {
            (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
    }
}

/// Shared by instant presentation and the stage's reveal/capture checks.
enum WindowServerListings {
    nonisolated static func read(_ windows: Set<UInt32>) -> [UInt32: WindowListing] {
        guard !windows.isEmpty else { return [:] }
        return autoreleasepool {
            var pointers: [UnsafeRawPointer?] = windows.sorted().map { UnsafeRawPointer(bitPattern: UInt($0)) }
            let array = CFArrayCreate(nil, &pointers, pointers.count, nil)
            let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
            var result: [UInt32: WindowListing] = [:]
            for row in descriptions {
                guard let id = row[kCGWindowNumber as String] as? UInt32,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
                result[id] = WindowListing(frame: frame, onScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false)
            }
            return result
        }
    }
}

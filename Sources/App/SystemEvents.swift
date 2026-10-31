import AppKit

/// Log-only context. None of these notifications changes Policy or starts work
/// at rest. AppDelegate retains the observers until termination calls stop().
@MainActor
final class SystemEvents: NSObject {
    private let diagnostics: any DiagnosticsPort
    private let distributedEvents: [String: DiagnosticSystemEvent] = [
        "com.apple.screenIsLocked": .screenLocked, "com.apple.screenIsUnlocked": .screenUnlocked,
        "com.apple.screensaver.didstart": .screenSaverStarted, "com.apple.screensaver.didstop": .screenSaverStopped,
    ]
    private var observations: [(NotificationCenter, any NSObjectProtocol)] = []

    init(diagnostics: any DiagnosticsPort) {
        self.diagnostics = diagnostics
        super.init()
        let distributed = DistributedNotificationCenter.default()
        for name in distributedEvents.keys.sorted() {
            distributed.addObserver(self, selector: #selector(distributedChanged), name: Notification.Name(name),
                                    object: nil, suspensionBehavior: .deliverImmediately)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event): (Notification.Name, DiagnosticSystemEvent) in [
            (NSWorkspace.screensDidSleepNotification, .screensSlept), (NSWorkspace.screensDidWakeNotification, .screensWoke),
            (NSWorkspace.willSleepNotification, .slept), (NSWorkspace.didWakeNotification, .woke),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
            (NSWorkspace.activeSpaceDidChangeNotification, .spaceChanged),
        ] {
            observe(workspace, name, event, diagnostics)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification, .screenParametersChanged, diagnostics)
    }

    // Foundation delivers distributed notifications on the main thread. Their
    // object and userInfo are untrusted and deliberately never inspected.
    @objc private func distributedChanged(_ notification: Notification) {
        if let event = distributedEvents[notification.name.rawValue] { diagnostics.record(.system(event)) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: DiagnosticSystemEvent,
                         _ diagnostics: any DiagnosticsPort) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in diagnostics.record(.system(event)) }
        observations.append((center, token))
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
    }
}

import AppKit

/// The login session's lock report and its unlock wake-up. The report is read
/// from the session each time it is needed. No notification decides the lock
/// state: any process can post `com.apple.screenIsLocked`.
@MainActor
struct SystemSession: SessionPort {
    nonisolated func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func observeUnlock(_ receive: @escaping @MainActor () -> Void) -> any SessionObservation { Observation(receive) }

    @MainActor
    private final class Observation: NSObject, SessionObservation {
        private let receive: @MainActor () -> Void

        init(_ receive: @escaping @MainActor () -> Void) {
            self.receive = receive
            super.init()
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlocked),
                                                                name: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                                                suspensionBehavior: .deliverImmediately)
        }

        isolated deinit { DistributedNotificationCenter.default().removeObserver(self) }

        // Foundation delivers distributed notifications on the main thread.
        // Their object and userInfo are untrusted and never inspected.
        @objc private func unlocked() { receive() }
    }
}

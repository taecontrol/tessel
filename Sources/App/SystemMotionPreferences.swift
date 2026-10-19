import AppKit

@MainActor
struct SystemMotionPreferences: MotionPreferencePort {
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func observe(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) -> any MotionPreferenceObservation {
        Observation(receive)
    }

    @MainActor
    private final class Observation: NSObject, MotionPreferenceObservation {
        private let receive: @MainActor @Sendable (Bool) -> Void
        init(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) {
            self.receive = receive
            super.init()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(changed),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        @objc private func changed() { receive(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
    }
}

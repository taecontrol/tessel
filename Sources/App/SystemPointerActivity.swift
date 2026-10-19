import AppKit

@MainActor
struct SystemPointerActivity: PointerActivityPort {
    func observePress(_ receive: @escaping @MainActor @Sendable () -> Void) -> any MotionPreferenceObservation {
        Observation(receive)
    }

    @MainActor
    private final class Observation: MotionPreferenceObservation {
        private var monitor: Any?
        init(_ receive: @escaping @MainActor @Sendable () -> Void) {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
                MainActor.assumeIsolated { receive() }
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

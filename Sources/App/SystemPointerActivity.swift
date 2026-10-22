import AppKit

@MainActor
struct SystemPointerActivity: PointerActivityPort {
    func observeButtons(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) -> any MotionPreferenceObservation {
        Observation(receive)
    }

    @MainActor
    private final class Observation: MotionPreferenceObservation {
        private var monitor: Any?
        init(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]) { event in
                let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
                MainActor.assumeIsolated { receive(down || NSEvent.pressedMouseButtons != 0) }
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

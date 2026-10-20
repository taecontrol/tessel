import Foundation

@MainActor
package protocol MotionPreferenceObservation: AnyObject {}

@MainActor
package protocol MotionPreferencePort {
    var reduceMotion: Bool { get }
    func observe(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) -> any MotionPreferenceObservation
}

/// No coordinates or target application cross this boundary. A mouse press
/// transfers geometry control to the user before a drag can race an AX write.
@MainActor
package protocol PointerActivityPort {
    func observePress(_ receive: @escaping @MainActor @Sendable () -> Void) -> any MotionPreferenceObservation
}

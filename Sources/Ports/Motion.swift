import Foundation

/// One-shot display frames. A client requests another frame only while moving.
@MainActor
package protocol DisplayFramePort {
    var now: TimeInterval { get }
    @discardableResult
    func requestFrame(_ receive: @escaping @MainActor @Sendable (TimeInterval) -> Void) -> any ScheduledWork
}

@MainActor
package protocol MotionPreferenceObservation: AnyObject {}

@MainActor
package protocol MotionPreferencePort {
    var reduceMotion: Bool { get }
    func observe(_ receive: @escaping @MainActor @Sendable (Bool) -> Void) -> any MotionPreferenceObservation
}

import Foundation

@MainActor
package protocol SessionObservation: AnyObject {}

@MainActor
package protocol SessionPort {
    /// Whether the login session reports its screen locked. The answer comes
    /// from the session's own state: it needs no Accessibility call.
    nonisolated func screenLocked() -> Bool
    /// Calls back after the screen unlocks. A wake-up only: the lock state is
    /// always asked through `screenLocked()`.
    func observeUnlock(_ receive: @escaping @MainActor () -> Void) -> any SessionObservation
}

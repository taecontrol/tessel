import Foundation
import Ports

extension SimulatedMac {
    @MainActor final class UnlockToken: SessionObservation {
        let receive: @MainActor () -> Void
        init(_ receive: @escaping @MainActor () -> Void) { self.receive = receive }
    }
    struct WeakUnlock { weak var value: UnlockToken? }

    @MainActor package var session: any SessionPort { Session(mac: self) }
    @MainActor package var isScreenLocked: Bool { screenLocked }

    /// The user locks the screen. From here every window handle answers as a
    /// closed window does, while WindowServer keeps listing the windows.
    @MainActor package func lockScreen() {
        assume(.lockedSessionWindows)
        action("lock screen")
        screenLocked = true
    }

    /// The user unlocks the screen. The handles answer truthfully before the
    /// session posts its notification.
    @MainActor package func unlockScreen() {
        assume(.lockedSessionWindows)
        action("unlock screen")
        screenLocked = false
        for box in unlocks {
            guard let token = box.value else { continue }
            scheduler.nativeEvent { [weak token] in
                self.scheduler.note("SessionEvent.unlocked")
                token?.receive()
            }
        }
    }

    @MainActor struct Session: SessionPort {
        let mac: SimulatedMac
        nonisolated func screenLocked() -> Bool {
            mac.assume(.lockedSessionWindows)
            mac.scheduler.call("SessionPort.screenLocked")
            return mac.screenLocked
        }
        func observeUnlock(_ receive: @escaping @MainActor () -> Void) -> any SessionObservation {
            mac.assume(.lockedSessionWindows)
            mac.scheduler.call("SessionPort.observeUnlock")
            let token = UnlockToken(receive)
            mac.unlocks.append(WeakUnlock(value: token))
            return token
        }
    }
}

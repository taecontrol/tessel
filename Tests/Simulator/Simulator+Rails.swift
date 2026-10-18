import Foundation
import CoreGraphics

extension SimulatedApp {
    @MainActor package func beginMinimize(_ window: UInt32) {
        mac.assume(.minimizeFocusInterruption)
        mac.action("begin Dock minimization of window \(window)")
        mac.windows[window]?.minimizing = true
    }
    @MainActor package func finishMinimize(_ window: UInt32, selecting successor: UInt32?) {
        mac.assume(.minimizeFocusInterruption)
        mac.action("complete Dock minimization of window \(window)")
        guard mac.windows[window]?.minimizing == true else { return }
        mac.windows[window]?.minimizing = false
        mac.minimize(window, successor: successor)
    }
    @MainActor package func deferNextActivation() {
        mac.assume(.deferredAXActivation)
        mac.action("\(alias) defer its next AX activation")
        mac.apps[pid]?.deferredActivations += 1
    }
    @MainActor package func limitSize(_ window: UInt32, maximum: CGSize) {
        mac.assume(.sizeLimitChanges)
        mac.action("\(alias) limit window \(window) to \(maximum.width)x\(maximum.height)")
        mac.windows[window]?.spec.maximumSize = maximum
    }
    @MainActor package func terminate(activating successor: UInt32, crash: Bool, publishesNotification: Bool = true) {
        mac.assume(.terminationActivationOrder)
        mac.action("\(crash ? "crash" : "quit") \(alias), promoting window \(successor) before notification")
        mac.apps[pid]?.terminated = true
        for id in mac.windows.keys.sorted() where mac.windows[id]?.pid == pid { mac.windows[id]?.closed = true }
        mac.focus(successor)
        if publishesNotification { mac.post(.terminated, pid: pid) }
    }
    @MainActor package func publishTermination() {
        mac.assume(.terminationActivationOrder)
        mac.action("publish termination of \(alias)")
        mac.post(.terminated, pid: pid)
    }
    @MainActor package func publishWindows(_ windows: [UInt32]?) {
        mac.assume(.nativeTabPublication)
        mac.action("\(alias) publish AXWindows \(windows.map(String.init(describing:)) ?? "normally")")
        mac.apps[pid]?.publishedWindows = windows
    }
    @MainActor package func publishFocus(_ published: Bool) {
        mac.assume(.nativeTabPublication)
        mac.action("\(alias) publish AXFocusedWindow=\(published)")
        mac.apps[pid]?.publishesFocus = published
        if published {
            mac.notify(.focusedWindowChanged, node: .application(pid))
            mac.notify(.mainWindowChanged, node: .application(pid))
        }
    }
}

extension SimulatedMac {
    func activateFromAX(_ pid: Int32) {
        if apps[pid]!.deferredActivations > 0 {
            assume(.deferredAXActivation)
            apps[pid]?.deferredActivations -= 1
            apps[pid]?.activationPending = true
        } else {
            apps[pid]?.activationPending = false
            front = pid
            post(.activated, pid: pid)
        }
    }
    func selectFromAX(_ id: UInt32) {
        if windows[id]?.minimizing == true {
            assume(.minimizeFocusInterruption)
            windows[id]?.minimizing = false
        }
        let pending = apps[windows[id]!.pid]?.activationPending == true
        if pending { assume(.deferredAXActivation) }
        focus(id, activating: !pending)
    }

    @MainActor package func isInCloset(_ id: UInt32) -> Bool {
        assume(.closetMembership)
        guard let space = windows[id]?.space else { return false }
        return space >= 2 && space < 10_000
    }
}

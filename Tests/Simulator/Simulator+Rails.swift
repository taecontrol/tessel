import Foundation
import CoreGraphics
import Ports

package enum DeferredActivationCompletion: String, CaseIterable, Sendable {
    case focusWrite, nativeEvent, nextRequest
}
package enum TerminationExitOrder: String, CaseIterable, Sendable { case beforePromotion, afterPromotion }

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
        guard mac.windows[window]?.restoresAfterMinimize == true else { return }
        mac.windows[window]?.restoresAfterMinimize = false
        mac.scheduler.nativeEvent { [mac] in
            mac.action("restore window \(window) for the raise that timed out during its minimization")
            mac.restoreWindow(window)
        }
    }
    @MainActor package func deferNextActivation(completion: DeferredActivationCompletion = .focusWrite) {
        mac.assume(.deferredAXActivation)
        mac.action("\(alias) defer its next AX activation until \(completion.rawValue)")
        mac.apps[pid]?.deferredActivations += 1
        mac.apps[pid]?.activationCompletion = completion
    }
    /// The native request can remain pending across a selection made another
    /// way. This observes the simulated OS record, not tessel's focus intent.
    @MainActor package var activationPending: Bool { mac.apps[pid]?.activationPending == true }
    /// Its next AX activation names it frontmost at once, but AppKit finishes
    /// it `milliseconds` later, past the main and raise writes that follow:
    /// a selection in the closet then loses key to the previous key window.
    @MainActor package func restoreKeyOverClosetOnNextActivation(afterMilliseconds milliseconds: Int = 30) {
        mac.assume(.activationKeyRestoration)
        mac.action("\(alias) finish its next AX activation after \(milliseconds) ms, keying its previous window over a closeted selection")
        mac.apps[pid]?.keyRestorationDelay = milliseconds
    }
    @MainActor package func limitSize(_ window: UInt32, maximum: CGSize) {
        mac.assume(.sizeLimitChanges)
        mac.action("\(alias) limit window \(window) to \(maximum.width)x\(maximum.height)")
        mac.windows[window]?.spec.maximumSize = maximum
    }
    @MainActor package func terminate(activating successor: UInt32, crash: Bool, publishesNotification: Bool = true,
                                     exitOrder: TerminationExitOrder = .afterPromotion) {
        mac.assume(.terminationActivationOrder)
        mac.action("\(crash ? "crash" : "quit") \(alias), promoting window \(successor) before notification, exit=\(exitOrder.rawValue)")
        mac.apps[pid]?.terminated = true
        mac.apps[pid]?.processExists = exitOrder == .afterPromotion
        for id in mac.windows.keys.sorted() where mac.windows[id]?.pid == pid { mac.windows[id]?.closed = true }
        mac.focus(successor)
        if publishesNotification {
            if exitOrder == .afterPromotion { mac.scheduler.nativeEvent { self.publishTermination() } }
            else { mac.post(.terminated, pid: pid) }
        }
    }
    @MainActor package func publishTermination() {
        mac.assume(.terminationActivationOrder)
        mac.action("publish termination of \(alias)")
        mac.apps[pid]?.processExists = false
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
        if let delay = apps[pid]?.keyRestorationDelay, delay > 0 {
            assume(.activationKeyRestoration)
            apps[pid]?.keyRestorationDelay = 0
            let previous = apps[pid]?.key
            front = pid
            orderActivatedWindows(pid)
            _ = scheduler.main.after(milliseconds: delay) { [self] in
                guard apps[pid]?.terminated == false else { return }
                func closeted(_ id: UInt32) -> Bool {
                    guard let spaces = windows[id]?.spaces else { return false }
                    return !spaces.isEmpty && spaces.allSatisfy { $0 >= 2 && $0 < 10_000 }
                }
                if let key = apps[pid]?.key, closeted(key), let previous, previous != key,
                   windows[previous]?.closed == false, !closeted(previous) { focus(previous, activating: false) }
                post(.activated, pid: pid)
            }
        } else if apps[pid]!.deferredActivations > 0 {
            assume(.deferredAXActivation)
            apps[pid]?.deferredActivations -= 1
            apps[pid]?.activationPending = true
            if apps[pid]?.activationCompletion == .nativeEvent {
                scheduler.nativeEvent {
                    if self.apps[pid]?.activationPending == true { self.completeAXActivation(pid) }
                }
            }
        } else {
            completeAXActivation(pid)
        }
    }
    func completeAXActivation(_ pid: Int32) {
        guard apps[pid]?.terminated == false else { return }
        apps[pid]?.activationPending = false
        front = pid
        orderActivatedWindows(pid)
        post(.activated, pid: pid)
    }
    /// AXFrontmost activation brings every window of the app forward,
    /// keeping their relative order.
    private func orderActivatedWindows(_ pid: Int32) {
        assume(.axFrontmostActivation)
        let owned = zOrder.filter { windows[$0]?.pid == pid }
        zOrder.removeAll { windows[$0]?.pid == pid }
        zOrder.insert(contentsOf: owned, at: 0)
    }
    func selectFromAX(_ id: UInt32, raising: Bool = false) -> AXStatus {
        motion.focusRequests.append(FocusRequest(window: id, hidden: isCloseted(id)))
        if windows[id]?.minimized == true {
            assume(.minimizeFocusInterruption)
            guard raising else { return .success }
        }
        if windows[id]?.minimizing == true {
            assume(.minimizeFocusInterruption)
            if raising && windows[id]?.spec.pendingMinimizeRaise == .restoresAfterMinimize {
                windows[id]?.restoresAfterMinimize = true
                return .cannotComplete
            }
            windows[id]?.minimizing = false
        }
        let pid = windows[id]!.pid
        if apps[pid]?.activationPending == true {
            assume(.deferredAXActivation)
            if apps[pid]?.activationCompletion == .focusWrite { completeAXActivation(pid) }
        }
        if windows[id]?.minimized == true {
            restoreWindow(id, activating: apps[pid]?.activationPending != true)
            return windows[id]?.spec.minimizedRaiseReply == .cannotComplete ? .cannotComplete : .success
        }
        if raising {
            assume(.axRaiseAcrossApplications)
            let activeWindow = front.flatMap { apps[$0]?.key }
            focus(id, activating: false)
            if front != pid, let activeWindow, zOrder.contains(activeWindow) {
                zOrder.removeAll { $0 == id }
                let index = zOrder.firstIndex(of: activeWindow)!
                // The regular frontmost app keeps its window above a background
                // AXRaise. Other background apps can still be reordered.
                zOrder.insert(id, at: min(index + 1,zOrder.count))
            }
        } else {
            if front != pid { assume(.axRaiseAcrossApplications) }
            focus(id, activating: false)
        }
        return .success
    }

    @MainActor package func isInCloset(_ id: UInt32) -> Bool {
        assume(.closetMembership)
        guard let spaces = windows[id]?.spaces else { return false }
        return !spaces.isEmpty && spaces.allSatisfy { $0 >= 2 && $0 < 10_000 }
    }
}

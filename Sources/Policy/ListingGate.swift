import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

/// One transition's bounded wait for the app-committed geometry. AX readiness
/// belongs to the presenter; this gate knows only the frames AX accepted.
@MainActor final class ListingGate {
    private struct Wait {
        let frame: CGRect
        var limit: (any ScheduledWork)?
        var expired = false
        var listed = false
        var onScreen = false
        var needsScreen = false
    }
    private static let limit = 100, interval = 4
    private let order: any WindowOrderPort
    private let scheduler: any SchedulingPort
    private var frames: [UInt32: Wait] = [:]
    private var waiting = Set<UInt32>()
    private var tick: (any ScheduledWork)?
    private var recheck: (@MainActor () -> Void)?
    private var batch: [UInt32: WindowListing]?
    private var cancelled = false

    init(order: any WindowOrderPort, scheduler: any SchedulingPort) {
        self.order = order; self.scheduler = scheduler
    }

    /// The limit starts when AX accepts, even if focus is still being moved.
    func track(_ accepted: [UInt32: CGRect]) {
        guard !cancelled else { return }
        for id in accepted.keys.sorted() where frames[id] == nil {
            frames[id] = Wait(frame: accepted[id]!)
            frames[id]?.limit = scheduler.main.after(milliseconds: Self.limit) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.frames[id]?.expired = true
                self.frames[id]?.limit = nil
                guard self.waiting.remove(id) != nil else { return }
                self.tick?.cancel(); self.tick = nil
                self.check()
            }
        }
    }

    func settled(_ windows: Set<UInt32>, onScreen: Bool) -> Set<UInt32> {
        guard !cancelled else { return [] }
        let pending = windows.filter { id in
            guard var frame = frames[id] else { return false }
            frame.needsScreen = frame.needsScreen || onScreen
            frames[id] = frame
            return !frame.expired && !(frame.listed && (!onScreen || frame.onScreen))
        }
        if !pending.isEmpty {
            waiting.formUnion(pending)
            // A recheck shares one read across returning and covering windows.
            let live = batch ?? order.listings(waiting)
            for id in pending {
                guard let listed = live[id], let accepted = frames[id]?.frame,
                      abs(listed.frame.minX - accepted.minX) <= 1, abs(listed.frame.minY - accepted.minY) <= 1,
                      abs(listed.frame.width - accepted.width) <= 1, abs(listed.frame.height - accepted.height) <= 1 else { continue }
                frames[id]?.listed = true
                frames[id]?.onScreen = listed.onScreen
                if listed.onScreen {
                    frames[id]?.limit?.cancel(); frames[id]?.limit = nil
                }
                if frames[id]?.needsScreen != true || listed.onScreen { waiting.remove(id) }
            }
        }
        return windows.filter { id in
            guard let frame = frames[id] else { return false }
            return frame.expired || frame.listed && (!onScreen || frame.onScreen)
        }
    }

    func scheduleRecheck(_ recheck: @escaping @MainActor () -> Void) {
        guard !cancelled else { return }
        guard !waiting.isEmpty else {
            tick?.cancel(); tick = nil; self.recheck = nil
            return
        }
        self.recheck = recheck
        // Keep the earliest tick when another AX completion joins the wait.
        guard tick == nil else { return }
        tick = scheduler.main.after(milliseconds: Self.interval) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.tick = nil
            self.check()
        }
    }

    private func check() {
        batch = waiting.isEmpty ? [:] : order.listings(waiting)
        recheck?()
        batch = nil
    }

    func cancel() {
        cancelled = true
        recheck = nil
        tick?.cancel(); tick = nil
        for id in frames.keys.sorted() { frames[id]?.limit?.cancel() }
        frames.removeAll(); waiting.removeAll(); batch = nil
    }
}

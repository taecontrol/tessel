import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct WindowServerHandoff {
    @Test("#40 E2: a departure waits for the covering tile's app commit and the first recheck", arguments: WriteOrder.allCases)
    func departureWaitsForListing(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("departure waits for WindowServer", writes: writes) { s in
            let exit = heldExit(s), f = exit.fixture
            s.after(milliseconds: 2, "AX has answered but the app has not committed") {
                s.expect("AX has accepted the tile's target", f.frame(exit.tile).minX == 869)
                s.expect("WindowServer still serves the tile's old frame", f.mac.servedFrame(exit.tile)?.minX == 1100)
                s.expect("the departing float stays visible until the app commits", f.mac.isVisible(exit.float))
            }
            s.settle()
            let commit = f.mac.windowServerCommits.last { $0.windows.contains(exit.tile) }?.at
            let hidden = f.mac.visibilityChanges.first { !$0.showing && $0.windows.contains(exit.float) }?.at
            s.expect("the app committed and the departure hid", commit != nil && hidden != nil)
            if let commit, let hidden {
                s.expect("the departure hides at the first recheck after commit (commit \(commit), hide \(hidden))", hidden >= commit && hidden <= commit + 4)
            }
        })
    }

    @Test("#40 E5: an app that stops after answering cannot retain a departure beyond 100 ms", arguments: WriteOrder.allCases)
    func departureHasAHundredMillisecondLimit(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("departure with an uncommitted, stopped replacement", writes: writes) { s in
            let exit = heldExit(s), f = exit.fixture, acceptedAt = f.mac.scheduler.now + 1
            s.after(milliseconds: 1, "the tile app stops after answering AXSize") { f.apps[1].hang() }
            s.after(milliseconds: 100, "one millisecond before the listing limit") {
                s.expect("the departure remains visible for the full 100 ms wait", f.mac.isVisible(exit.float))
            }
            s.settle()
            let hidden = f.mac.visibilityChanges.first { !$0.showing && $0.windows.contains(exit.float) }?.at
            s.expect("the departure hides exactly at the 100 ms limit (accepted \(acceptedAt), hidden \(String(describing: hidden)))", hidden == acceptedAt + 100)
            s.expect("the bounded handoff reaches its terminal state", !placementPending(f.tessel))
            s.expect("the app remains stopped with its old served frame", f.mac.servedFrame(exit.tile)?.minX == 1100)
            f.apps[1].resume(); s.settle()
            s.expect("resuming commits the accepted frame", f.mac.servedFrame(exit.tile) == f.mac.frame(exit.tile))
        })
    }

    @Test("#40 E6; #40 E7: an uncommitted returning tile shows at 100 ms and focus targets only visible windows", arguments: WriteOrder.allCases)
    func returningWindowHasAHundredMillisecondLimit(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("return with an uncommitted, stopped app", writes: writes) { s in
            let f = returningWorkspace(s), returning = f.ids[1], acceptedAt = f.mac.scheduler.now + 1
            s.after(milliseconds: 1, "the returning app stops after its readback") { f.apps[1].hang() }
            s.after(milliseconds: 100, "one millisecond before the return limit") {
                s.expect("the unconfirmed return stays in the closet for 100 ms", f.mac.isInCloset(returning) && !f.mac.isVisible(returning))
            }
            s.settle()
            let shown = f.mac.visibilityChanges.first { $0.showing && $0.windows.contains(returning) }?.at
            s.expect("the return shows exactly at the 100 ms limit (accepted \(acceptedAt), shown \(String(describing: shown)))", shown == acceptedAt + 100)
            s.expect("the returning handoff reaches its terminal state", !placementPending(f.tessel))
            s.expect("native focus is never requested in the closet", f.mac.focusRequests.allSatisfy { !$0.hidden })
        })
    }

    @Test("#40 E3: an unchanged returning float still waits for its accepted frame", arguments: WriteOrder.allCases)
    func unchangedReturnWaitsForItsListing(_ writes: WriteOrder) throws {
        requireCarousel(Scenario.run("unchanged return with an earlier uncommitted placement", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0)
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
            s.settle(); f.select(f.ids[0]); f.press("toggle layer"); f.press("toggle layer")
            s.expect("the float starts in the closet", f.mac.isInCloset(float))
            f.app.delayCommits(milliseconds: 80)
            let ax = f.mac.ax, application = ax.application(f.app.pid)
            guard let element = ax.copy(.windows, of: application).value?.elements?.first(where: { ax.windowID($0).value == float }) else {
                s.expect("the hidden float has a retained AX handle", false); return
            }
            let target = f.frame(float).offsetBy(dx: 50, dy: 0)
            _ = ax.set(.position, of: element, to: .point(target.origin))
            let read = f.mac.pause(after: .read(f.app))
            if case .paused = read {} else { s.expect("the hidden geometry snapshot is held: \(read)", false) }
            let delivered = f.mac.deliver(f.app)
            if case .paused = delivered {} else { s.expect("the hidden geometry snapshot is delivered: \(delivered)", false) }
            f.mac.clearMotionHistory(); f.mac.beginPresentationTrace()
            f.tessel.press("toggle layer"); s.settle()
            s.expect("an unchanged return needs no geometry write", f.mac.geometryWrites.allSatisfy { $0.window != float })
            let showing = f.mac.presentationStates.first { $0.operation == "show" && $0.frames[float] != nil }
            s.expect("the unchanged float is first shown at its accepted frame", showing?.frames[float] == target)
            s.expect("focus waits until the unchanged return is visible", f.mac.focusRequests.allSatisfy { !$0.hidden })
        })
    }

    @Test("#40 E8: a current WindowServer view preserves the zero-delay effect order without rechecks", arguments: WriteOrder.allCases)
    func immediateCommitsPreserveOrdering(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("zero-delay WindowServer", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.app.delayCommits(milliseconds: 0); f.select(b)
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            f.press("focus right")
            let effects = f.mac.scheduler.trace.dropFirst(start).compactMap { line -> String? in
                if line.contains("AccessibilityPort.set AXPosition="), line.contains("window \(c) ") { return "place return" }
                if line.contains("ClosetPort.show windows=[\(c)]") { return "show return" }
                if line.contains("AccessibilityPort.set AXPosition="), line.contains("window \(b) ") { return "place replacement" }
                if line.contains("AccessibilityPort.set AXFrontmost=true") { return "focus" }
                if line.contains("ClosetPort.hide windows=[\(a)]") { return "hide departure" }
                return nil
            }
            s.expect("zero-delay effects keep their original order: \(effects)", effects == ["place return", "show return", "focus", "place replacement", "hide departure"])
            s.expect("a current listing schedules no recheck", !f.mac.scheduler.trace.dropFirst(start).contains { $0.contains("SchedulingPort.after +4ms") })
        })
    }

    @Test("#40 E9: a new transition, pointer press or disable cancels the pending listing wait", arguments: WriteOrder.allCases, ["transition", "pointer", "disable"])
    func supersedingActionsCancelTheWait(_ writes: WriteOrder, _ action: String) {
        requireCarousel(Scenario.run("cancel a listing wait with \(action)", writes: writes) { s in
            let exit = heldExit(s, commit: 80), f = exit.fixture
            let before = f.mac.listingReads.count, cancelled = CancellationObservation()
            s.after(milliseconds: 2, "cancel the listing wait") {
                s.expect("the old transition was waiting on a listing", f.mac.listingReads.count > before)
                switch action {
                case "transition": f.tessel.press("toggle layer")
                case "pointer": f.mac.pointerDown()
                default: f.tessel.workspaces.disable(reason: "test interruption")
                }
                cancelled.reads = f.mac.listingReads.count
            }
            s.settle()
            s.expect("cancelled listing waits do no more reads", f.mac.listingReads.count == cancelled.reads)
            s.expect("the old transition cannot hide the float after cancellation", !f.mac.visibilityChanges.contains { !$0.showing && $0.windows.contains(exit.float) })
            if action == "transition" { s.expect("the new transition completes cleanly", f.tessel.status.layer?.state == "shown" && !placementPending(f.tessel)) }
            let trace = f.mac.scheduler.trace.count, reads = f.mac.listingReads.count
            s.settle()
            s.expect("nothing runs at rest", f.mac.scheduler.trace.count == trace && f.mac.listingReads.count == reads)
        })
    }

    @Test("#40 E10; #40 E11: a missing listing is bounded and reads only its waiting replacement", arguments: WriteOrder.allCases)
    func missingListingsCannotStrandDepartures(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("a replacement that WindowServer never lists", writes: writes) { s in
            let exit = heldExit(s), f = exit.fixture, acceptedAt = f.mac.scheduler.now + 1
            f.mac.omitListings(of: [exit.tile])
            let first = f.mac.listingReads.count, start = f.mac.scheduler.trace.count
            s.settle()
            let hidden = f.mac.visibilityChanges.first { !$0.showing && $0.windows.contains(exit.float) }?.at
            s.expect("a missing listing retires the departure at 100 ms", hidden == acceptedAt + 100)
            s.expect("a missing listing cannot strand the handoff", !placementPending(f.tessel))
            let reads = Array(f.mac.listingReads.dropFirst(first))
            s.expect("listing reads ask only for the waiting replacement", !reads.isEmpty && reads.allSatisfy { $0.windows == [exit.tile] })
            s.expect("one wait needs at most 26 listing reads", reads.count <= 26)
            let rechecks = f.mac.scheduler.trace.dropFirst(start).filter { $0.contains("SchedulingPort.after +4ms") }.count
            s.expect("one wait needs at most 26 rechecks", rechecks <= 26)
            s.expect("a recheck makes at most one listing read", Dictionary(grouping: reads, by: \.at).values.allSatisfy { $0.count == 1 })
            let idleReads = f.mac.listingReads.count, idleTrace = f.mac.scheduler.trace.count
            s.settle()
            s.expect("a resolved gate leaves no work at rest", f.mac.listingReads.count == idleReads && f.mac.scheduler.trace.count == idleTrace)
        })
    }

    @Test("#40 E10: a missing listing cannot leave a returning window in the closet", arguments: WriteOrder.allCases)
    func missingListingsCannotStrandReturns(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("a return that WindowServer never lists", writes: writes) { s in
            let f = returningWorkspace(s), returning = f.ids[1], acceptedAt = f.mac.scheduler.now + 1
            f.mac.omitListings(of: [returning]); s.settle()
            let shown = f.mac.visibilityChanges.first { $0.showing && $0.windows.contains(returning) }?.at
            s.expect("a missing listing shows the return at 100 ms", shown == acceptedAt + 100)
            s.expect("a missing return listing cannot strand the handoff", !placementPending(f.tessel))
        })
    }

    private struct Exit { let fixture: CarouselFixture; let tile: UInt32; let float: UInt32 }

    /// Holds the tile's last readback call. Its successful reply reaches policy
    /// one millisecond after resuming; its app commit is still pending then.
    private func heldExit(_ s: Scenario, commit: Int = 20) -> Exit {
        let f = CarouselFixture(s, duration: 0, appCount: 2), b = f.ids[1]
        let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
        s.settle(); f.select(f.ids[0]); f.press("toggle layer")
        f.apps[1].moveFromApplication(b, to: CGPoint(x: 1100, y: 43)); s.settle()
        f.apps[1].delayCommits(milliseconds: commit)
        f.mac.clearMotionHistory(); f.mac.beginPresentationTrace()
        f.tessel.press("toggle layer")
        let held = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(b) \(f.apps[1].alias)"))
        if case .paused = held {} else { s.expect("the covering tile's readback is held: \(held)", false) }
        f.mac.scheduler.resume()
        let answered = f.mac.pause(after: .read(f.apps[1]))
        if case .paused = answered {} else { s.expect("the placement has captured its final publication: \(answered)", false) }
        return Exit(fixture: f, tile: b, float: float)
    }

    private func returningWorkspace(_ s: Scenario) -> CarouselFixture {
        let f = CarouselFixture(s, duration: 0, appCount: 2), a = f.ids[0], b = f.ids[1]
        f.select(b); f.press("send 2"); f.press("workspace 1")
        f.select(a); f.press("send 2"); f.press("workspace 1")
        f.apps[1].delayCommits(milliseconds: 20)
        f.mac.clearMotionHistory(); f.mac.beginPresentationTrace()
        f.tessel.press("workspace 2")
        let held = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(b) \(f.apps[1].alias)"))
        if case .paused = held {} else { s.expect("the returning tile's readback is held: \(held)", false) }
        f.mac.scheduler.resume()
        let answered = f.mac.pause(after: .read(f.apps[1]))
        if case .paused = answered {} else { s.expect("the returning placement has captured its final publication: \(answered)", false) }
        return f
    }

    private func placementPending(_ tessel: Tessel) -> Bool {
        guard let token = Mirror(reflecting: tessel.workspaces).children.first(where: { $0.label == "placementToken" }) else {
            Issue.record("the presenter must expose its placementToken to the terminal-state oracle")
            return true
        }
        return !Mirror(reflecting: token.value).children.isEmpty
    }
}

@MainActor private final class CancellationObservation { var reads = 0 }

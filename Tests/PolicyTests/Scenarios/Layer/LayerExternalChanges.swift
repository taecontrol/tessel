import CoreGraphics
import Simulator
import Testing
@testable import Policy

/// #33 E18, amended: tessel's own ordering never exposes the desktop; an
/// external change during a handoff exposes what it would expose at rest, and
/// the exposure ends at the first recheck after that render's app commits. Each change runs
/// once during a layer exit and once at rest, under the same assertion.
///
/// The render is found without looking at coverage: it runs in the main-lane
/// job that delivers the change's snapshot, and its own work never waits for
/// time to pass beyond its bounded listing wait. Exposure ends at the first
/// recheck after its app commits, and the handoff arm may expose the point no longer
/// than the at-rest arm. An arm whose job or timers cannot be identified
/// fails, rather than checking less.
@Suite @MainActor struct LayerExternalChanges {
    private static let floatFrame = CGRect(x: 1000, y: 100, width: 200, height: 200)
    private static let target = CGRect(x: 869, y: 43, width: 849, height: 1064)
    private static let point = CGPoint(x: 1000, y: 100)

    enum Change: String, CaseIterable { case minimize, close, hide }
    enum Moment: String, CaseIterable {
        /// The app changes the tile after the exit rendered and before it
        /// commits, and the exit commits while the change's snapshot read is
        /// held.
        case duringExit
        /// After the exit, at rest.
        case atRest
    }

    /// How long one arm exposed the point, in virtual milliseconds until the
    /// state that ended the exposure.
    private typealias Exposures = [Moment: Int]

    @Test("#33 E18: the render boundary fails when its trace evidence is missing or malformed")
    func renderBoundaryRequiresItsEvidence() throws {
        let trace = [
            "[0ms] main MainLane.async",
            "[10ms] main main begin #5",
            "[10ms] main SchedulingPort.after +20ms",
            "[12ms] tessel.ax.101 SchedulingPort.after +5ms",
            "[17ms] main timer #7 ready",
            "[30ms] main timer #6 ready",
        ]
        #expect(try RenderBoundary.deliveryJob(in: trace, since: 0) == 1)
        #expect(try RenderBoundary.end(in: trace, snapshot: 1) == 4)
        #expect(throws: RenderBoundary.Missing.self) { try RenderBoundary.deliveryJob(in: trace, since: 2) }
        let perturbed = [
            "main begin #": "main-begin-#", "timer #": "timer-#", "SchedulingPort.after +": "SchedulingPort.after+",
            "+5ms": "+5", "[17ms]": "[17 ms]", "[10ms] main main": "[ms] main main",
        ]
        for (marker, replacement) in perturbed {
            let changed = trace.map { $0.replacingOccurrences(of: marker, with: replacement) }
            #expect(throws: RenderBoundary.Missing.self, "\(marker) → \(replacement)") {
                try RenderBoundary.end(in: changed, snapshot: RenderBoundary.deliveryJob(in: changed, since: 0))
            }
        }
        #expect(throws: RenderBoundary.Missing.self, "a scheduled timer that never fired") {
            try RenderBoundary.end(in: Array(trace.dropLast()), snapshot: 1)
        }
        #expect(throws: RenderBoundary.Missing.self, "no timer fired once the render's was due") {
            try RenderBoundary.end(in: [trace[1], trace[4], trace[2]], snapshot: 0)
        }
    }

    @Test("#33 E18; #40 E13: a tile withdrawn by its app during a layer exit exposes no longer than at rest",
          arguments: WriteOrder.allCases, Change.allCases)
    func withdrawalExposesNoLongerThanAtRest(_ writes: WriteOrder, _ change: Change) {
        var exposures = Exposures()
        for moment in Moment.allCases { requireLayer(Scenario.run("\(change.rawValue) a tile \(moment.rawValue) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[1]
            let float = shownFloat(f)
            if moment == .atRest {
                f.press("toggle layer")
                s.expect("at rest, B covers the point", f.mac.isVisible(b) && f.frame(b).contains(Self.point) && !f.mac.isVisible(float))
            }
            if moment == .duringExit { renderExit(f, float) }
            let changed = beginTrace(f)
            switch change {
            case .minimize: app.minimize(b)
            case .close: app.close(b)
            case .hide: app.hide()
            }
            if moment == .duringExit { holdSnapshot(f, app) }
            let snapshot = deliverSnapshot(f, app, held: moment == .duringExit, since: changed)
            s.settle()
            exposures[moment] = expectExposureEndsWithRender(f, changed: changed, snapshot: snapshot, coveredBy: c)
            s.expect("the layer is hidden with focus on the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }) }
        expectNoLongerThanAtRest(exposures)
    }

    @Test("#33 E18: a tile minimized while its layer exit placement is being written exposes no longer than at rest", arguments: WriteOrder.allCases)
    func minimizeDuringPlacementWriteExposesNoLongerThanAtRest(_ writes: WriteOrder) {
        var exposures = Exposures()
        for moment in Moment.allCases { requireLayer(Scenario.run("minimize a tile \(moment == .atRest ? "at rest" : "during its placement write") / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5, 0.5, 0.5], duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], d = f.ids[3], app = f.apps[1]
            let float = shownFloat(f), changed: TraceStart
            if moment == .atRest {
                // The same layout change and exit, unheld.
                f.app.close(c, selecting: float)
                s.settle()
                f.press("toggle layer")
                s.expect("at rest, B covers the point", f.mac.isVisible(b) && f.frame(b).contains(Self.point) && !f.mac.isVisible(float))
                changed = beginTrace(f)
                app.minimize(b)
            } else {
                // A same-size resize starts a snapshot read of B's app, held
                // after it read B. Removing the parked tile then gives B a
                // position request that stays pending into the exit.
                app.resizeFromApplication(b, to: Self.target.size)
                let held = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(b) \(app.alias)"))
                if case .paused = held {} else { s.expect("B's snapshot read is held: \(held)", false) }
                f.app.close(c, selecting: float)
                let closed = f.mac.scheduler.run()
                if case .paused = closed {} else { s.expect("B's lane stays held through the relayout: \(closed)", false) }
                s.step("toggle layer") { f.tessel.press("toggle layer") }
                let exit = f.mac.scheduler.run()
                if case .paused = exit {} else { s.expect("B's lane stays held through the exit: \(exit)", false) }
                s.expect("the float covers B's target while B's placement waits", f.mac.isVisible(float) && f.frame(float).contains(Self.point))
                // B passed its presentability check; the write and its readback
                // succeed on a window that is no longer drawn.
                f.mac.scheduler.resume()
                let write = f.mac.pause(after: .call("AccessibilityPort.set AXPosition=\(Self.target.minX),\(Self.target.minY) window \(b) \(app.alias)"))
                if case .paused = write {} else { s.expect("B's placement write is held: \(write)", false) }
                changed = beginTrace(f)
                app.minimize(b)
            }
            let snapshot = deliverSnapshot(f, app, held: false, since: changed)
            s.settle()
            exposures[moment] = expectExposureEndsWithRender(f, changed: changed, snapshot: snapshot, coveredBy: d)
            s.expect("the layer is hidden with focus on the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }) }
        expectNoLongerThanAtRest(exposures)
    }

    @Test("#33 E18: a tile its app resizes during a layer exit exposes no longer than at rest",
          arguments: WriteOrder.allCases, [false, true])
    func nativeResizeExposesNoLongerThanAtRest(_ writes: WriteOrder, _ fractional: Bool) {
        let width = fractional ? "fractional" : "exact"
        var exposures = Exposures()
        for moment in Moment.allCases { requireLayer(Scenario.run("a tile's app resizes it \(moment.rawValue) / \(width) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, maximumFractions: fractional ? [1: 848.5 / 1708] : [:], appCount: 2)
            let b = f.ids[1], app = f.apps[1], accepted = fractional ? 848.5 : 849
            // The existing size-constraint contract supplies the native
            // maximum: the tile accepts half a point less than its preset.
            if fractional { app.resizeFromApplication(b, to: CGSize(width: accepted, height: f.area.height)); s.settle() }
            let float = shownFloat(f)
            s.expect("the tile has its accepted frame", f.frame(b) == CGRect(x: 869, y: 43, width: accepted, height: 1064))
            if moment == .atRest { f.press("toggle layer") } else { renderExit(f, float) }
            let changed = beginTrace(f)
            app.resizeFromApplication(b, to: CGSize(width: 100, height: f.area.height))
            if moment == .duringExit { holdSnapshot(f, app) }
            let snapshot = deliverSnapshot(f, app, held: moment == .duringExit, since: changed)
            s.settle()
            exposures[moment] = expectExposureEndsWithRender(f, changed: changed, snapshot: snapshot, coveredBy: b)
            s.expect("the tile recovers its accepted width", f.frame(b) == CGRect(x: 869, y: 43, width: accepted, height: 1064))
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }) }
        expectNoLongerThanAtRest(exposures)
    }

    @Test("#33 E18 / #39 E2: a tile its app moves during a layer exit exposes no longer than at rest", arguments: WriteOrder.allCases)
    func nativeMoveExposesNoLongerThanAtRest(_ writes: WriteOrder) {
        // A move's snapshot triggers no render on 0c531ee, so neither arm's
        // exposure ends (#39). Swift Testing reports it once it passes.
        withKnownIssue("#39: a read app move is never placed back") {
        var exposures = Exposures()
        for moment in Moment.allCases { requireLayer(Scenario.run("a tile's app moves it \(moment.rawValue) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1]
            let float = shownFloat(f)
            if moment == .atRest { f.press("toggle layer") } else { renderExit(f, float) }
            let changed = beginTrace(f)
            app.moveFromApplication(b, to: CGPoint(x: 1100, y: 43))
            if moment == .duringExit { holdSnapshot(f, app) }
            let snapshot = deliverSnapshot(f, app, held: moment == .duringExit, since: changed)
            s.settle()
            exposures[moment] = expectExposureEndsWithRender(f, changed: changed, snapshot: snapshot, coveredBy: b)
            s.expect("the tile is placed back at its target: \(f.frame(b))", f.frame(b) == Self.target)
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }) }
        expectNoLongerThanAtRest(exposures)
        }
    }

    /// Renders the layer exit and holds it at its focus request, before it
    /// retires the float.
    private func renderExit(_ f: CarouselFixture, _ float: UInt32) {
        let s = f.s
        // Pressed outside `step`, so the eager order does not run the focus
        // request before it can be held.
        f.tessel.press("toggle layer")
        let focusing = f.mac.pause(after: .call("AccessibilityPort.set AXFrontmost=true \(f.app.alias) pid=\(f.app.pid)"))
        if case .paused = focusing {} else { s.expect("the exit's focus request is held: \(focusing)", false) }
        s.expect("the exit has not retired the float yet", f.mac.isVisible(float))
    }

    /// Lets the exit commit while the change's snapshot read is held, so it
    /// decides on what tessel observed before the change.
    private func holdSnapshot(_ f: CarouselFixture, _ app: SimulatedApp) {
        let s = f.s
        let read = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(app.alias) pid=\(app.pid)"))
        if case .paused = read {} else { s.expect("the change's snapshot read is held: \(read)", false) }
        let commit = f.mac.scheduler.run()
        if case .paused = commit {} else { s.expect("the app's lane stays held through the exit's commit: \(commit)", false) }
    }

    /// Runs until tessel has received the change's snapshot: the app's first
    /// snapshot read that starts after the change. An earlier read can still
    /// be on its way to tessel, so the change's read is found as it starts,
    /// unless it is already held there. Returns the trace index of the
    /// main-lane job that delivered it: that job publishes the snapshot and
    /// starts the render it triggers.
    private func deliverSnapshot(_ f: CarouselFixture, _ app: SimulatedApp, held: Bool, since change: TraceStart) -> Int? {
        if !held {
            f.mac.scheduler.resume()
            let read = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(app.alias) pid=\(app.pid)"))
            if case .paused = read {} else { f.s.expect("the change's snapshot read starts: \(read)", false) }
        }
        let delivered = f.mac.deliver(app)
        guard delivered == .paused("delivery app pid=\(app.pid)") else { f.s.expect("the change's snapshot is delivered: \(delivered)", false); return nil }
        do { return try RenderBoundary.deliveryJob(in: f.mac.scheduler.trace, since: change.traceIndex) } catch {
            f.s.expect("the job that delivered the change's snapshot is identified: \(error)", false)
            return nil
        }
    }

    /// The trace starts at the external change. The render the change's
    /// snapshot triggers ends at the first recheck after its placements commit
    /// to WindowServer. The exposure must end by then, with
    /// the successor covering the point, and no later state may expose it.
    /// Returns how long the point was exposed, or nil when the arm failed.
    private func expectExposureEndsWithRender(_ f: CarouselFixture, changed: TraceStart, snapshot: Int?, coveredBy successor: UInt32) -> Int? {
        let s = f.s, trace = f.mac.scheduler.trace, states = f.mac.presentationStates
        // A missing boundary fails the arm; the exposure is still judged.
        var render: Int?
        if let snapshot {
            do {
                let writes = f.mac.geometryWrites.filter { $0.traceIndex >= snapshot }
                let commits = try writes.map { write in
                    guard let commit = f.mac.windowServerCommits.first(where: { $0.traceIndex > write.traceIndex && $0.windows.contains(write.window) }) else {
                        throw RenderBoundary.Missing(description: "no app commit after render placement of window \(write.window)")
                    }
                    return commit.at
                }
                render = try RenderBoundary.end(in: trace, snapshot: snapshot, notBefore: commits.max())
                if let commit = commits.max(), let end = states.lastIndex(where: { !$0.frames.values.contains { $0.contains(Self.point) } }).map({ $0 + 1 }), end < states.count {
                    s.expect("the exposure ends by the first recheck after the render's app commit", states[end].at <= commit + 4)
                }
            } catch {
                s.expect("the render boundary is identified: \(error)", false)
            }
        } else { s.expect("the render boundary needs the change's snapshot delivery", false) }
        let exposed = states.indices.filter { !states[$0].frames.values.contains { $0.contains(Self.point) } }
        guard let first = exposed.first, let last = exposed.last else { return render.map { _ in 0 } }
        let end = last + 1
        guard end < states.count else { s.expect("the exposure ends: \(states[first...].map(\.operation))", false); return nil }
        s.expect("the successor covers the point when the exposure ends", states[end].frames[successor]?.contains(Self.point) == true)
        guard let render else { return nil }
        do {
            let endTime = try RenderBoundary.time(trace, before: states[end].traceIndex)
            let boundaryTime = try RenderBoundary.time(trace[render])
            s.expect("the exposure ends with the render the change's snapshot triggers, at \(endTime) ms, not after the first timer following its app commit",
                     endTime <= boundaryTime)
            // A change that exposes the point by itself records no state.
            return endTime - (first == 0 ? changed.time : try RenderBoundary.time(trace, before: states[first].traceIndex))
        } catch {
            s.expect("the exposure's times are read: \(error)", false)
            return nil
        }
    }

    private func expectNoLongerThanAtRest(_ exposures: Exposures, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let during = exposures[.duringExit], let rest = exposures[.atRest] else {
            Issue.record("both arms must measure their exposure: \(exposures)", sourceLocation: sourceLocation)
            return
        }
        #expect(during <= rest, "the handoff exposes the point for \(during) ms, at rest for \(rest) ms", sourceLocation: sourceLocation)
    }

    private struct TraceStart { let time: Int; let traceIndex: Int }

    /// Starts the presentation trace at the external change.
    private func beginTrace(_ f: CarouselFixture) -> TraceStart {
        f.mac.beginPresentationTrace()
        return TraceStart(time: f.mac.scheduler.now, traceIndex: f.mac.scheduler.trace.count)
    }

    /// Shows a dialog over tile B and enters the layer from tile A.
    private func shownFloat(_ f: CarouselFixture) -> UInt32 {
        let s = f.s
        let float = f.app.open(WindowSpec(frame: Self.floatFrame, subrole: "AXDialog"))
        s.settle()
        f.select(f.ids[0])
        f.press("toggle layer")
        s.expect("the shown float covers tile B at its target", f.frame(f.ids[1]).contains(Self.point)
                 && f.tessel.status.layer?.state == "shown" && f.mac.isVisible(float))
        return float
    }
}

/// The scheduler records its jobs and timers only in its trace, so the render
/// boundary is read from there. Each line the boundary needs must have the
/// scheduler's exact spelling; anything missing or malformed throws, so the
/// oracle never checks against a weaker boundary.
enum RenderBoundary {
    struct Missing: Error, CustomStringConvertible { let description: String }

    /// The last main-lane job to begin since `start`. Main-lane jobs do not
    /// nest, so when tessel has just received a delivery, it is the job that
    /// delivered it.
    static func deliveryJob(in trace: [String], since start: Int) throws(Missing) -> Int {
        guard let job = trace.indices.last(where: {
            $0 >= start && trace[$0].contains(" begin #") && trace[$0].wholeMatch(of: #/\[\d+ms\] main main begin #\d+/#) != nil
        }) else {
            throw Missing(description: "no main-lane job began after trace index \(start)")
        }
        return job
    }

    /// The trace index of the first timer to fire at or after the earliest
    /// due time scheduled from the delivery job on. Every timer must have
    /// fired, so a missing firing cannot hide the boundary.
    static func end(in trace: [String], snapshot: Int, notBefore commit: Int? = nil) throws(Missing) -> Int {
        var due: Int?, scheduled = 0, fired: [Int] = []
        for index in trace.indices {
            let line = trace[index]
            if line.contains("SchedulingPort.after") {
                guard let match = line.wholeMatch(of: #/\[(\d+)ms\] \S+ SchedulingPort\.after \+(-?\d+)ms/#),
                      let at = Int(match.1), let delay = Int(match.2) else { throw Missing(description: "malformed timer request: \(line)") }
                scheduled += 1
                if index >= snapshot { due = min(due ?? .max, at + max(0, delay)) }
            } else if line.hasSuffix(" ready"), line.wholeMatch(of: #/\[\d+ms\] main timer #\d+ ready/#) != nil {
                fired.append(index)
            }
        }
        guard fired.count == scheduled else { throw Missing(description: "\(scheduled) timers scheduled, \(fired.count) fired") }
        guard let due else { throw Missing(description: "no timer was scheduled from the delivery job at trace index \(snapshot) on") }
        for index in fired where index > snapshot {
            if try time(trace[index]) >= max(due, commit ?? due) { return index }
        }
        throw Missing(description: "no timer fired at or after \(due) ms")
    }

    /// The virtual time of the trace line before `index`: when the state
    /// recorded at `index` began.
    static func time(_ trace: [String], before index: Int) throws(Missing) -> Int {
        guard trace.indices.contains(index - 1) else { throw Missing(description: "no trace line before index \(index)") }
        return try time(trace[index - 1])
    }

    static func time(_ line: String) throws(Missing) -> Int {
        guard let match = line.prefixMatch(of: #/\[(\d+)ms\] /#), let time = Int(match.1) else {
            throw Missing(description: "no timestamp: \(line)")
        }
        return time
    }
}

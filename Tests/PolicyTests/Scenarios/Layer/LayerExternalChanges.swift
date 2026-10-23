import CoreGraphics
import Simulator
import Testing
@testable import Policy

/// #33 E18, amended: tessel's own ordering never exposes the desktop; an
/// external change during a handoff exposes what it would expose at rest, and
/// the exposure ends with the render its snapshot triggers. Each change runs
/// once during a layer exit and once at rest, under the same assertion.
///
/// The render is found without looking at coverage: it runs in the main-lane
/// job that delivers the change's snapshot, and its own work never waits for
/// time to pass. The exposure must end before any timed work scheduled from
/// that job on comes due, and the handoff arm may expose the point no longer
/// than the at-rest arm.
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

    @Test("#33 E18: a tile withdrawn by its app during a layer exit exposes no longer than at rest",
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
            let snapshot = deliverSnapshot(f, app, held: moment == .duringExit)
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
            let float = shownFloat(f), changed: Int
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
            let snapshot = deliverSnapshot(f, app, held: false)
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
            let snapshot = deliverSnapshot(f, app, held: moment == .duringExit)
            s.settle()
            exposures[moment] = expectExposureEndsWithRender(f, changed: changed, snapshot: snapshot, coveredBy: b)
            s.expect("the tile recovers its accepted width", f.frame(b) == CGRect(x: 869, y: 43, width: accepted, height: 1064))
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }) }
        expectNoLongerThanAtRest(exposures)
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
    private func deliverSnapshot(_ f: CarouselFixture, _ app: SimulatedApp, held: Bool) -> Int? {
        if !held {
            f.mac.scheduler.resume()
            let read = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(app.alias) pid=\(app.pid)"))
            if case .paused = read {} else { f.s.expect("the change's snapshot read starts: \(read)", false) }
        }
        let delivered = f.mac.deliver(app)
        guard case .paused = delivered else { f.s.expect("the change's snapshot is delivered: \(delivered)", false); return nil }
        return f.mac.scheduler.trace.lastIndex { $0.contains("] main main begin #") }
    }

    /// The trace starts at the external change. The render the change's
    /// snapshot triggers ends before the first timer, scheduled from the
    /// snapshot's delivery on, comes due. The exposure must end by then, with
    /// the successor covering the point, and no later state may expose it.
    /// Returns how long the point was exposed.
    private func expectExposureEndsWithRender(_ f: CarouselFixture, changed: Int, snapshot: Int?, coveredBy successor: UInt32) -> Int? {
        let s = f.s, trace = f.mac.scheduler.trace, states = f.mac.presentationStates
        guard let snapshot else { return nil }
        let due = trace[snapshot...].compactMap { line -> Int? in
            guard let after = line.range(of: "SchedulingPort.after +") else { return nil }
            return Self.time(line) + (Int(line[after.upperBound...].dropLast(2)) ?? 0)
        }.min()
        let render = trace.indices.first { index in
            index > snapshot && trace[index].contains("] main timer #") && due.map { Self.time(trace[index]) >= $0 } == true
        } ?? trace.count
        let exposed = states.indices.filter { !states[$0].frames.values.contains { $0.contains(Self.point) } }
        guard let first = exposed.first, let last = exposed.last else { return 0 }
        let end = last + 1
        guard end < states.count else { s.expect("the exposure ends: \(states[first...].map(\.operation))", false); return nil }
        let endTime = Self.time(trace[states[end].traceIndex - 1])
        s.expect("the exposure ends with the render the change's snapshot triggers, at \(endTime) ms, not after the render's first due timer",
                 states[end].traceIndex <= render)
        s.expect("the successor covers the point when the exposure ends", states[end].frames[successor]?.contains(Self.point) == true)
        // A change that exposes the point by itself records no state.
        return endTime - (first == 0 ? changed : Self.time(trace[states[first].traceIndex - 1]))
    }

    private func expectNoLongerThanAtRest(_ exposures: Exposures, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let during = exposures[.duringExit], let rest = exposures[.atRest] else { return }
        #expect(during <= rest, "the handoff exposes the point for \(during) ms, at rest for \(rest) ms", sourceLocation: sourceLocation)
    }

    /// Starts the presentation trace at the external change and returns its
    /// virtual time.
    private func beginTrace(_ f: CarouselFixture) -> Int {
        f.mac.beginPresentationTrace()
        return f.mac.scheduler.now
    }

    private static func time(_ line: String) -> Int {
        Int(line.dropFirst().prefix { $0.isNumber }) ?? 0
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

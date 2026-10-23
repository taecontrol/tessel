import CoreGraphics
import Simulator
import Testing
@testable import Policy

/// #33 E18, amended: tessel's own ordering never exposes the desktop; an
/// external change during a handoff exposes what it would expose at rest, and
/// the exposure ends with the render its snapshot triggers. Each change runs
/// once during a layer exit and once at rest, under the same assertion.
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

    @Test("#33 E18: a tile withdrawn by its app during a layer exit exposes no longer than at rest",
          arguments: WriteOrder.allCases, Change.allCases)
    func withdrawalExposesNoLongerThanAtRest(_ writes: WriteOrder, _ change: Change) {
        for moment in Moment.allCases { requireLayer(Scenario.run("\(change.rawValue) a tile \(moment.rawValue) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[1]
            let float = shownFloat(f)
            if moment == .atRest {
                f.press("toggle layer")
                s.expect("at rest, B covers the point", f.mac.isVisible(b) && f.frame(b).contains(Self.point) && !f.mac.isVisible(float))
            }
            if moment == .duringExit { renderExit(f, float) }
            f.mac.beginPresentationTrace()
            switch change {
            case .minimize: app.minimize(b)
            case .close: app.close(b)
            case .hide: app.hide()
            }
            if moment == .duringExit { commitBeforeSnapshot(f, app) }
            s.settle()
            expectExposureEndsWithRender(s, f.mac.presentationStates, coveredBy: c)
            s.expect("the layer is hidden with focus on the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }) }
    }

    @Test("#33 E18: a tile minimized while its layer exit placement is being written exposes no longer than at rest", arguments: WriteOrder.allCases)
    func minimizeDuringPlacementWriteExposesNoLongerThanAtRest(_ writes: WriteOrder) {
        let result = Scenario.run("minimize a tile during its placement write / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5, 0.5, 0.5], duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], d = f.ids[3], app = f.apps[1]
            let float = shownFloat(f)
            // A same-size resize starts a snapshot read of B's app, held after
            // it read B. Removing the parked tile then gives B a position
            // request that stays pending into the exit.
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
            f.mac.beginPresentationTrace()
            app.minimize(b)
            s.settle()
            expectExposureEndsWithRender(s, f.mac.presentationStates, coveredBy: d)
            s.expect("the layer is hidden with focus on the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#33 E18: a tile its app resizes during a layer exit exposes no longer than at rest",
          arguments: WriteOrder.allCases, [false, true])
    func nativeResizeExposesNoLongerThanAtRest(_ writes: WriteOrder, _ fractional: Bool) {
        let width = fractional ? "fractional" : "exact"
        for moment in Moment.allCases { requireLayer(Scenario.run("a tile's app resizes it \(moment.rawValue) / \(width) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, maximumFractions: fractional ? [1: 848.5 / 1708] : [:], appCount: 2)
            let b = f.ids[1], app = f.apps[1], accepted = fractional ? 848.5 : 849
            // The existing size-constraint contract supplies the native
            // maximum: the tile accepts half a point less than its preset.
            if fractional { app.resizeFromApplication(b, to: CGSize(width: accepted, height: f.area.height)); s.settle() }
            let float = shownFloat(f)
            s.expect("the tile has its accepted frame", f.frame(b) == CGRect(x: 869, y: 43, width: accepted, height: 1064))
            if moment == .atRest { f.press("toggle layer") } else { renderExit(f, float) }
            f.mac.beginPresentationTrace()
            app.resizeFromApplication(b, to: CGSize(width: 100, height: f.area.height))
            if moment == .duringExit { commitBeforeSnapshot(f, app) }
            s.settle()
            expectExposureEndsWithRender(s, f.mac.presentationStates, coveredBy: b)
            s.expect("the tile recovers its accepted width", f.frame(b) == CGRect(x: 869, y: 43, width: accepted, height: 1064))
            s.expect("the float leaves the desktop", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }) }
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
    private func commitBeforeSnapshot(_ f: CarouselFixture, _ app: SimulatedApp) {
        let s = f.s
        let read = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(app.alias) pid=\(app.pid)"))
        if case .paused = read {} else { s.expect("the change's snapshot read is held: \(read)", false) }
        let commit = f.mac.scheduler.run()
        if case .paused = commit {} else { s.expect("the app's lane stays held through the exit's commit: \(commit)", false) }
    }

    /// The trace starts at the external change. The first state in which the
    /// successor covers the point is the render the change's snapshot
    /// triggered; no state from then on may expose the point.
    private func expectExposureEndsWithRender(_ s: Scenario, _ states: [SimulatedMac.PresentationState], coveredBy successor: UInt32) {
        let render = states.firstIndex { $0.frames[successor]?.contains(Self.point) == true }
        s.expect("the render the change's snapshot triggers covers the point", render != nil)
        let after = render.map { states[$0...].filter { state in !state.frames.values.contains { $0.contains(Self.point) } } } ?? []
        s.expect("the exposure ends with that render: \(after.map(\.operation))", after.isEmpty)
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

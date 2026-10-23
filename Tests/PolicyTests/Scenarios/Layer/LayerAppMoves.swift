import CoreGraphics
import Simulator
import Testing
@testable import Policy

/// #39: a rail tile its app moves, after tessel has read the move, is never
/// placed back. `update` re-renders on a size change, not on a position
/// change, and a render positions only pending, redrawn, newly shown or
/// departure-covering tiles.
///
/// Each scenario fails on 0c531ee in every scheduler and is kept as a known
/// issue until #39 is decided; Swift Testing reports it once it passes.
@Suite @MainActor struct LayerAppMoves {
    private static let target = CGRect(x: 869, y: 43, width: 849, height: 1064)
    private static let moved = CGPoint(x: 1100, y: 43)
    private static let point = CGPoint(x: 1000, y: 100)

    @Test("#39: a tile its app moved at rest is placed back, and stays placed across focus commands", arguments: WriteOrder.allCases)
    func tileItsAppMovedAtRestIsPlacedBack(_ writes: WriteOrder) {
        let result = Scenario.run("app moves a rail tile at rest / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1]
            f.select(a)
            s.expect("B starts at its target", f.frame(b) == Self.target)
            let publications = f.tessel.windowPublications.count
            f.apps[1].moveFromApplication(b, to: Self.moved)
            s.settle()
            s.expect("tessel reads a snapshot of B's app after the move", f.tessel.windowPublications.dropFirst(publications).contains {
                $0.pid == f.apps[1].pid && $0.windows?.contains { $0.id == b } == true
            })
            s.expect("the snapshot of the move places B back: B is at \(f.frame(b))", f.frame(b) == Self.target)
            f.press("focus right")
            f.press("focus left")
            s.expect("focus commands that keep the layout place B back: B is at \(f.frame(b))", f.frame(b) == Self.target)
        }
        withKnownIssue("#39: a read app move is never placed back") { requireLayer(result) }
    }

    @Test("#39: a tile its app moved before a layer exit is read covers the float's point once the float leaves", arguments: WriteOrder.allCases)
    func unreadMoveBeforeLayerExit(_ writes: WriteOrder) {
        let result = Scenario.run("app moves a tile, then the layer exits before the move is read / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], app = f.apps[1]
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
            s.settle()
            f.select(a)
            f.press("toggle layer")
            s.expect("the shown float covers B at its target", f.frame(b) == Self.target && f.mac.isVisible(float))
            app.moveFromApplication(b, to: Self.moved)
            // Hold the move's snapshot so the exit decides on the frame tessel
            // read before the move, as within the ~10 ms debounce.
            let read = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(app.alias) pid=\(app.pid)"))
            if case .paused = read {} else { s.expect("the move's snapshot read is held: \(read)", false) }
            f.mac.beginPresentationTrace()
            s.step("toggle layer") { f.tessel.press("toggle layer") }
            _ = f.mac.scheduler.run()
            s.settle()
            let states = f.mac.presentationStates
            let exposed = states.filter { !$0.frames.values.contains { $0.contains(Self.point) } }
            s.expect("the layer is hidden with focus on A", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("B ends at its target: B is at \(f.frame(b))", f.frame(b) == Self.target)
            s.expect("the exposure ends: last state \(states.last.map { $0.operation } ?? "none"), \(exposed.count) exposed of \(states.count)",
                     states.last.map { $0.frames.values.contains { $0.contains(Self.point) } } ?? false)
        }
        withKnownIssue("#39: a read app move is never placed back") { requireLayer(result) }
    }

    @Test("#39: an exposure the unanswered-app fallback admits ends once the app answers", arguments: WriteOrder.allCases)
    func fallbackExposureEndsWhenTheAppAnswers(_ writes: WriteOrder) {
        let result = Scenario.run("app moves a tile and hangs before the layer exit / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[1]
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
            s.settle()
            f.select(a)
            f.press("toggle layer")
            s.expect("the shown float covers B at its target", f.frame(b) == Self.target && f.mac.isVisible(float))
            // The app moves B and hangs before tessel can read the move.
            app.moveFromApplication(b, to: Self.moved)
            app.hang()
            // Removing the parked tile redraws the layout, so B's position
            // stays pending through placements its hung app never answers.
            f.app.close(c, selecting: float)
            s.settle()
            let exit = f.mac.scheduler.trace.count
            f.press("toggle layer")
            let attempts = f.mac.scheduler.trace.dropFirst(exit).filter {
                $0.contains("AccessibilityPort.copy AXHidden reply \(app.alias) pid=\(app.pid) cannotComplete")
            }
            s.expect("the exit's placement of B exhausts its initial attempt and four retries", attempts.count == 5)
            s.expect("the layer is hidden with focus on A", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            // The fallback admits B on its cached frame, which predates the
            // move: an external change during a handoff, as #33 E18 allows.
            s.expect("the fallback retires the float while B is away from the point",
                     f.mac.isInCloset(float) && !f.frame(b).contains(Self.point))
            app.resume()
            // A position-only notification starts a fresh snapshot. A resize
            // would be clamped at the screen edge and re-render through the
            // size path, hiding the gap.
            app.moveFromApplication(b, to: Self.moved)
            s.settle()
            s.expect("once the app answers, B is placed back over the point: B is at \(f.frame(b))", f.frame(b) == Self.target)
        }
        withKnownIssue("#39: a read app move is never placed back") { requireLayer(result) }
    }
}

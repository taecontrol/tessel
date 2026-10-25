import CoreGraphics
import Simulator
import Testing
@testable import Policy

/// A presentation's readiness stays with it. Under a hung sibling, a held or
/// exhausted read, a stream of native moves, or a quit, the windows it waits on
/// are decided within bounded time, without waiting for an app's next event.
/// Handoffs a failed placement can strand are #41's.
@Suite @MainActor struct LayerReadinessResolution {
    private static let floatFrame = CGRect(x: 1000, y: 100, width: 200, height: 200)
    private static let target = CGRect(x: 869, y: 43, width: 849, height: 1064)

    @Test("#33 E18: readiness from one layer exit never releases a departure in the transition that replaces it", arguments: WriteOrder.allCases)
    func readinessStaysWithItsTransition(_ writes: WriteOrder) {
        let result = Scenario.run("a read crosses into a restored tile's transition / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 0, appCount: 3)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            // Restoring a known half-width tile keeps this handoff independent of
            // the default width of newly opened windows (#49).
            let e = f.apps[1].open(WindowSpec(frame: CGRect(x: 40, y: 60, width: f.width(0.5), height: 1064)))
            f.apps[1].minimize(e)
            s.settle()
            let ignored = f.app.open(WindowSpec(subrole: "AXUnknown"), background: true)
            s.settle()
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 650, height: 300), subrole: "AXDialog"))
            s.settle()
            f.select(a)
            f.press("toggle layer")
            // A's app moves an ignored window and stops answering, so the
            // exit is still open when the next layout renders.
            f.app.moveFromApplication(ignored, to: CGPoint(x: 50, y: 100))
            f.app.hang()
            s.settle()
            let origin = f.frame(b).origin
            f.apps[1].moveFromApplication(b, to: CGPoint(x: origin.x + 20, y: origin.y))
            f.apps[1].moveFromApplication(b, to: origin)
            let read = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(f.apps[1].alias) pid=\(f.apps[1].pid)"))
            if case .paused = read {} else { s.expect("B's snapshot read is held: \(read)", false) }
            s.step("toggle layer") { f.tessel.press("toggle layer") }
            let exit = f.mac.scheduler.run()
            if case .paused = exit {} else { s.expect("B's lane stays held through the exit: \(exit)", false) }
            // B's app restores a tile before the held read finishes, so that
            // read's publication starts a new layout in which B moves right.
            f.apps[1].restore(e)
            f.mac.scheduler.resume()
            let moved = f.mac.pause(after: .call("AccessibilityPort.set AXPosition=1441.6666666666665,43.0 window \(b) \(f.apps[1].alias)"))
            if case .paused = moved {} else { s.expect("B's move in the new layout is held: \(moved)", false) }
            let pending = f.mac.scheduler.run()
            if case .paused = pending {} else { s.expect("B's lane stays held before it moves: \(pending)", false) }
            let edge = CGPoint(x: 1600, y: 300)
            s.expect("B has not moved yet", f.frame(b).origin == origin)
            s.expect("the right edge stays covered until B moves", (f.ids + [float, e]).contains { f.mac.isVisible($0) && f.frame($0).contains(edge) })
            s.expect("C stays visible while its replacement is elsewhere", f.mac.isVisible(c))
            f.app.resume()
            s.settle()
            s.expect("B reaches the new layout and covers the right edge", f.mac.isVisible(b) && f.frame(b).contains(edge))
            s.expect("the float leaves the desktop once B covers it", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7: an ignored sibling's move and exhausted reads do not strand a float over a tile that never moved", arguments: WriteOrder.allCases)
    func ignoredSiblingDoesNotStrandFloat(_ writes: WriteOrder) {
        let result = Scenario.run("ignored sibling moves, then its app hangs / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1]
            let ignored = f.apps[1].open(WindowSpec(frame: CGRect(x: 30, y: 80, width: 200, height: 200), subrole: "AXUnknown"), background: true)
            s.settle()
            let float = shownFloat(f)
            f.apps[1].moveFromApplication(ignored, to: CGPoint(x: 50, y: 100))
            f.apps[1].hang()
            s.settle()
            f.press("toggle layer")
            s.expect("the tile never left its target", f.frame(b) == Self.target)
            s.expect("leaving the layer returns focus to the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the float hides while the app is still hung", f.mac.isInCloset(float) && !f.mac.isVisible(float))
            f.apps[1].resume()
            s.settle()
            s.expect("the float stays hidden after the app resumes", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7: a held read after an ignored sibling's move does not hold back its app's tiles", arguments: WriteOrder.allCases)
    func ignoredSiblingDoesNotHoldBackTiles(_ writes: WriteOrder) {
        let result = Scenario.run("ignored sibling moves while its app's read is held / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0]
            let ignored = f.apps[1].open(WindowSpec(frame: CGRect(x: 30, y: 80, width: 200, height: 200), subrole: "AXUnknown"), background: true)
            s.settle()
            let float = shownFloat(f)
            f.apps[1].moveFromApplication(ignored, to: CGPoint(x: 50, y: 100))
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(f.apps[1].alias) pid=\(f.apps[1].pid)"))
            if case .paused = held {} else { s.expect("the sibling's app read is held: \(held)", false) }
            s.step("toggle layer") { f.tessel.press("toggle layer") }
            let pending = f.mac.scheduler.run()
            if case .paused = pending {} else { s.expect("the sibling's app lane stays held: \(pending)", false) }
            s.expect("leaving the layer returns focus to the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the float hides over a tile whose own geometry is current", f.mac.isInCloset(float) && !f.mac.isVisible(float))
            s.settle()
        }
        requireLayer(result)
    }

    @Test("#19 E7: a tile's unread move resolves after its hung app exhausts the read retries", arguments: WriteOrder.allCases)
    func unreadMoveResolvesAfterExhaustedReads(_ writes: WriteOrder) {
        let result = Scenario.run("a tile moves and returns, then its app hangs / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1]
            let float = shownFloat(f)
            f.apps[1].moveFromApplication(b, to: CGPoint(x: Self.target.minX + 20, y: Self.target.minY))
            f.apps[1].moveFromApplication(b, to: Self.target.origin)
            f.apps[1].hang()
            // The snapshot read after the moves exhausts its retries before
            // the exit, so tessel never read the tile away from its target.
            s.settle()
            let start = f.mac.scheduler.now
            f.press("toggle layer")
            s.expect("leaving the layer returns focus to the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the float hides on the last read geometry while the app stays hung", f.mac.isInCloset(float) && !f.mac.isVisible(float))
            s.expect("everything settles within the read retries, with no further event", f.mac.scheduler.now - start <= 3_000)
            f.apps[1].resume()
            s.settle()
            s.expect("the tile stays at its target", f.frame(b) == Self.target)
            s.expect("the float stays hidden", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7: a float hides while the tile's app keeps moving it", arguments: WriteOrder.allCases)
    func continuousNativeMovesDoNotDelayReadiness(_ writes: WriteOrder) {
        let result = Scenario.run("layer exit during a stream of app-driven moves / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1]
            let float = shownFloat(f)
            // The app animates its tile within the presenter's one-point
            // tolerance every 5 ms, faster than the snapshot read's debounce.
            for step in 1...400 {
                let x = Self.target.minX + (step % 2 == 0 ? 0 : 0.5)
                s.after(milliseconds: 5 * step, "B's app moves it") { f.apps[1].moveFromApplication(b, to: CGPoint(x: x, y: Self.target.minY)) }
            }
            s.after(milliseconds: 102, "toggle layer") { f.tessel.press("toggle layer") }
            let midStream = Observed()
            s.after(milliseconds: 1_000, "check mid-stream") {
                midStream.value = f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a
                    && f.mac.isInCloset(float) && !f.mac.isVisible(float)
            }
            s.settle()
            s.expect("the float hides while the stream continues", midStream.value)
            s.expect("the tile stays within a point of its target", abs(f.frame(b).minX - Self.target.minX) <= 1 && f.frame(b).size == Self.target.size)
            s.expect("the float stays hidden", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7: quitting during a layer exit releases the presenter", arguments: WriteOrder.allCases, [false, true])
    func quittingReleasesPresenter(_ writes: WriteOrder, _ unread: Bool) {
        weak var owner: Workspaces?
        let result = Scenario.run("quit during a layer exit with the tile's app \(unread ? "hung" : "answering") / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            owner = f.tessel.workspaces
            let b = f.ids[1]
            _ = shownFloat(f)
            if unread {
                f.apps[1].moveFromApplication(b, to: CGPoint(x: Self.target.minX + 20, y: Self.target.minY))
                f.apps[1].moveFromApplication(b, to: Self.target.origin)
                f.apps[1].hang()
                s.settle()
            }
            s.step("toggle layer") { f.tessel.press("toggle layer") }
            f.tessel.quit()
            s.settle()
            s.expect("quitting disables management", !f.tessel.status.enabled)
        }
        requireLayer(result)
        #expect(owner == nil, "the presenter is released after quit")
    }

    /// Shows a dialog over tile B and enters the layer from tile A.
    private func shownFloat(_ f: CarouselFixture) -> UInt32 {
        let s = f.s
        let float = f.app.open(WindowSpec(frame: Self.floatFrame, subrole: "AXDialog"))
        s.settle()
        f.select(f.ids[0])
        f.press("toggle layer")
        s.expect("the shown float overlaps tile B at its target", f.frame(f.ids[1]) == Self.target && Self.target.intersects(Self.floatFrame)
                 && f.tessel.status.layer?.state == "shown" && f.mac.isVisible(float))
        return float
    }
}

@MainActor private final class Observed { var value = false }

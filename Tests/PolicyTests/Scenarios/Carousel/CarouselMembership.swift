import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselMembership {
    @Test("#26 E10: opening after the focused right half reveals the new half with minimal scrolling")
    func newHalfInsertsAfterFocus() {
        requireCarousel(Scenario.run("open after visible pair") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l"); let width = f.frame(b).width
            let id = f.open()
            f.order([f.ids[0], b, id, f.ids[2]])
            f.pair(b, id, focused: id)
            f.near(f.frame(b).width, width, "arrival preserves the neighbour's nominal width")
        })
    }

    @Test("#26 E11: opening at an expanded start restores its nominal half beside the arrival")
    func openingLeavesExpansion() {
        requireCarousel(Scenario.run("open at expanded start") { s in
            let f = CarouselFixture(s), a = f.ids[0]
            let id = f.open()
            f.order([a, id, f.ids[1], f.ids[2]]); f.pair(a, id, focused: id)
        })
    }

    @Test("#26 E12: closing focus selects left, or right for the first tile, and removes empty rails", arguments: ["middle", "first", "below", "above", "only"])
    func closeUsesAdjacentTileOrRail(position: String) {
        requireCarousel(Scenario.run("close selection \(position)") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            switch position {
            case "middle":
                f.press("alt-l"); f.app.close(b, selecting: c); s.settle(); f.focus(a); f.order([a,c])
            case "only":
                f.app.close(b); f.app.close(c); s.settle(); f.app.close(a); s.settle()
                s.expect("closing the last tile removes the final rail", f.tessel.status.railCount == 0 && f.tessel.windows.isEmpty)
                s.expect("closing the last tile selects the native desktop", f.mac.frontmostApp == f.mac.finder.pid && f.mac.focusedWindow == nil)
            case "first":
                f.app.close(a, selecting: c); s.settle(); f.focus(b); f.order([b,c])
            default:
                f.select(b); f.press("alt-shift-j")
                f.select(c); f.press("alt-shift-j"); f.press("alt-shift-j") // three singleton rails
                s.expect("three rails were created", f.tessel.status.railCount == 3)
                if position == "below" { f.select(b); f.app.close(b, selecting: a); s.settle(); f.focus(c) }
                else { f.select(c); f.app.close(c, selecting: a); s.settle(); f.focus(b) }
                s.expect("the empty rail disappears", f.tessel.status.railCount == 2)
                s.expect("the adjacent survivor occupies rail two", f.tessel.status.rail == 2)
            }
        })
    }

    @Test("#26 E13: swaps stop at the edge and vertical transfers insert after destination focus")
    func swapsAndTransfersNeverWrap() {
        requireCarousel(Scenario.run("swap and rail transfer") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.press("alt-shift-l"); f.order([b,a,c]); f.focus(a)
            f.press("alt-shift-l"); f.order([b,c,a]); f.focus(a)
            let before = f.snapshot(); f.press("alt-shift-l"); f.order([b,c,a]); f.focus(a); f.unchanged(before)
            f.press("alt-shift-j"); f.order([a], rail: 2); f.focus(a)
            f.press("alt-k"); f.select(b); f.press("alt-shift-j"); f.order([a,b], rail: 2)
            f.press("alt-h"); f.focus(a)
            f.select(c); f.press("alt-shift-j"); f.order([a,c,b])
            s.expect("an empty source rail is removed", f.tessel.status.railCount == 1)
            f.press("alt-shift-k"); f.order([c]); f.focus(c)
            s.expect("moving above a populated rail creates a new rail", f.tessel.status.railCount == 2)
        })
    }

    @Test("#26 E25: floats stay fixed, workspace switches and sends are instant, and carousel state returns")
    func floatingWindowsAndWorkspaceTransitionsStayInstant() {
        requireCarousel(Scenario.run("floating windows and workspace memory") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            let dialog = f.app.open(WindowSpec(subrole: "AXDialog")); s.settle()
            let original = f.frame(dialog)
            f.select(a); f.press("alt-l"); f.press("alt-l")
            f.select(c); f.press("alt-shift-j"); f.press("alt-k")
            let before = f.snapshot(), focus = f.mac.focusedWindow, rail = f.tessel.status.rail
            s.expect("floating geometry remains untouched", f.frame(dialog) == original)
            f.mac.clearMotionHistory(); f.press("alt-2")
            s.expect("workspace switching requests zero display frames", f.mac.displayFrameRequests == 0)
            f.press("alt-1"); f.unchanged(before)
            s.expect("workspace restores remembered rail and focus", f.tessel.status.rail == rail && f.mac.focusedWindow == focus)
            f.select(b); f.mac.clearMotionHistory(); f.press("alt-shift-2")
            s.expect("send follows instantly without frames", f.mac.displayFrameRequests == 0 && f.tessel.status.active == 2)
            s.expect("floating windows receive no carousel geometry writes", !f.mac.geometryWrites.contains { $0.window == dialog })
            f.near(f.frame(dialog).width, original.width, "floating width stays")
            f.near(f.frame(dialog).minX, original.minX, "floating position stays")
        })
    }
}

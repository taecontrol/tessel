import CoreGraphics
import Simulator
import Testing

@Suite @MainActor struct CarouselWidths {
    @Test("accepted subpoint width differences do not turn focus-only commands into resizes")
    func acceptedSizesRemainStable() {
        requireCarousel(Scenario.run("stable AX width readback") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l")
            let id = f.open(maximum: f.width(0.5) - 0.5)
            f.mac.clearMotionHistory()
            f.press("alt-h"); f.focus(b)
            f.press("alt-l"); f.focus(id)
            s.expect("focus-only commands do not repeat an accepted size within the one-point tolerance", f.mac.geometryWrites.isEmpty)
        })
    }

    @Test("#26 E7: width cycling uses gap-aware presets, anchors the left edge and exits expansion")
    func presetCycleAnchorsAndMinimallyReveals() {
        requireCarousel(Scenario.run("cycle expanded nominal thirds") { s in
            let f = CarouselFixture(s, presets: [1.0/3, 0.5, 1]), a = f.ids[0], b = f.ids[1]
            f.press("alt-r")
            f.near(f.frame(a).width, f.width(0.5), "cycling an expanded nominal third chooses half")
            f.near(f.frame(a).minX, f.area.minX, "cycling leaves expansion at the same left edge")
            for p in [2.0/3, 1, 1.0/3] { f.press("alt-r"); f.near(f.frame(a).width, f.width(p), "next preset \(p)") }
            f.press("alt-l"); f.focus(b)
            let left = f.frame(b).minX
            f.press("alt-r")
            f.near(f.frame(b).width, f.width(2.0/3), "half cycles to two thirds")
            f.near(f.frame(b).minX, left, "two thirds still fits without moving its left edge")
            f.press("alt-r")
            f.near(f.frame(b).width, f.area.width, "two thirds cycles to full")
            f.near(f.frame(b).minX, f.area.minX, "full width shifts only enough to be complete")
            f.focus(b)
        })
    }

    @Test("#26 E8: minimum and maximum widths reject a preset once and skip it thereafter", arguments: [false, true])
    func rejectedWidthsAreLearned(maximum: Bool) {
        requireCarousel(Scenario.run("learn \(maximum ? "maximum" : "minimum") width") { s in
            let f = CarouselFixture(s)
            f.press("alt-l"); f.mac.clearMotionHistory()
            let id = f.open(minimum: maximum ? 1 : f.area.width * 0.62, maximum: maximum ? f.area.width * 0.8 : 100_000)
            let initial = f.mac.geometryWrites.filter { $0.window == id && $0.attribute == .size }
            if !maximum {
                s.expect("new constrained window needs at most two size writes", (1...2).contains(initial.count))
                f.near(Double(initial.first?.requested.size?.width ?? -1), f.width(0.5), "first request is half")
                f.near(f.frame(id).width, f.width(2.0/3), "accepted minimum rounds to two thirds")
                f.mac.clearMotionHistory()
                for p in [1.0, 2.0/3, 1, 2.0/3] { f.press("alt-r"); f.near(f.frame(id).width, f.width(p), "cycle skips rejected smaller presets") }
                let requested = f.mac.geometryWrites.filter { $0.window == id && $0.attribute == .size }.compactMap { $0.requested.size?.width }
                s.expect("a rejected small width is never requested again", !requested.isEmpty && requested.allSatisfy { $0 >= f.width(2.0/3) - 1 })
            } else {
                f.press("alt-r"); f.near(f.frame(id).width, f.width(2.0/3), "maximum fixture reaches two thirds")
                f.press("alt-r"); f.near(f.frame(id).width, f.width(1.0/3), "rejected full width wraps to the next accepted third")
                f.mac.clearMotionHistory()
                for p in [0.5, 2.0/3, 1.0/3, 0.5, 2.0/3, 1.0/3] { f.press("alt-r"); f.near(f.frame(id).width, f.width(p), "cycle skips rejected maximum") }
                let requested = f.mac.geometryWrites.filter { $0.window == id && $0.attribute == .size }.compactMap { $0.requested.size?.width }
                s.expect("the rejected full width is never requested again", !requested.isEmpty && requested.allSatisfy { $0 < f.area.width - 1 })
            }
            f.focus(id)
        })
    }

    @Test("#26 E9: a mouse width remains unsnapped and the next cycle chooses the next larger preset")
    func mouseWidthIsAdoptedUntilCycle() {
        requireCarousel(Scenario.run("mouse width remains forty percent") { s in
            let f = CarouselFixture(s), b = f.ids[1], c = f.ids[2]
            f.press("alt-l"); let left = f.frame(b).minX
            f.mac.clearMotionHistory()
            f.app.resize(b, to: CGSize(width: f.area.width * 0.4, height: f.area.height)); s.settle()
            f.near(f.frame(b).width, f.area.width * 0.4, "mouse width is exactly forty percent")
            f.near(f.frame(b).minX, left, "mouse width retains left edge")
            s.expect("adopting mouse width performs no size writes", !f.mac.geometryWrites.contains { $0.window == b && $0.attribute == .size })
            f.press("alt-l"); f.focus(c)
            f.near(f.frame(c).maxX, f.area.maxX, "the recalculated next stop reveals the third window")
            f.press("alt-h"); f.focus(b)
            f.near(f.frame(b).width, f.area.width * 0.4, "navigation does not snap the mouse width")
            f.press("alt-r"); f.near(f.frame(b).width, f.width(0.5), "next preset above forty percent is half")
        })
    }
}

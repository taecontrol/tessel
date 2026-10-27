import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct MapContent {
    @Test("#18 E10: edge commands show a wall even without motion and the next effective key clears it", arguments: [0, 250])
    func wallsDoNotDependOnMotion(_ animation: Int) {
        for (key, selection, wall) in [("alt-h", 0, MapPicture.Wall.left), ("alt-k", 0, .up), ("alt-shift-l", 5, .right)] {
            requireCarousel(Scenario.run("map wall \(wall) animation=\(animation)") { s in
                let f = MapFixture(s, animation: animation, selection: [selection]), t0 = f.mac.scheduler.now
                f.tessel.pressKey(key)
                s.after(milliseconds: 600, "an effective key clears the wall") { f.tessel.pressKey(selection == 5 ? "alt-h" : "alt-l") }
                s.settle()
                f.expectShown(at: t0)
                s.expect("the edge command draws its wall", f.show(at: t0)?.wall == wall)
                f.expectShown(at: t0 + 600)
                s.expect("the next effective command has no wall", f.show(at: t0 + 600)?.wall == nil)
                f.expectHide(at: t0 + 1600, fade: animation == 0 ? 0 : 0.12)
            })
        }
    }

    @Test("#18 E11: a wall still appears while an earlier stage movement prevents a bounce")
    func wallDuringStageMovement() {
        requireCarousel(Scenario.run("map wall during stage motion") { s in
            let f = MapFixture(s, selection: [5]), t0 = f.mac.scheduler.now
            // A width change moves the stage without leaving the last slot.
            f.tessel.pressKey("alt-r")
            s.after(milliseconds: 120, "hit the right wall while the stage is moving") {
                s.expect("the stage has shown but not yet cleared", f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } }
                    && f.mac.stageEvents.last?.kind != .clear)
                f.tessel.pressKey("alt-l")
            }
            s.settle()
            f.expectShown(at: t0 + 120)
            s.expect("the wall is drawn independently of the skipped stage bounce", f.show(at: t0 + 120)?.wall == .right)
        })
    }

    @Test("#18 E12: the long rail picture carries all ordered gap-aware spans, its offset and the resulting focus")
    func longRailPictureUsesAreaWidths() {
        requireCarousel(Scenario.run("map long rail spans") { s in
            let f = MapFixture(s), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l"); s.settle()
            f.expectShown(at: t0)
            let picture = f.show(at: t0)
            let expected = MapScene.long.picture().rails[0]
            s.expect("one rail contains six spans in prototype order", mapSpansMatch(picture?.rails.first?.spans, expected.spans) && picture?.rails.count == 1)
            let offset = (7.0 / 6) * (1 + 10.0 / 1708)
            s.expect("the first key from tile four advances to the next left-edge stop", abs((picture?.rails.first?.offset ?? -1) - offset) < 0.000001)
            s.expect("the real carousel reaches the independently worked stop", abs((f.mac.frame(f.rails[0][3])?.minX ?? -1)
                - (MapFixture.area.minX + expected.spans[3].start * 1708 - offset * 1708)) < 1)
            s.expect("the real carousel keeps tile four focused at that stop", f.mac.focusedWindow == f.rails[0][3])
            s.expect("the stop retains tile four as the complete focused tile", picture?.focus == .tile(3) && f.mac.focusedWindow == f.rails[0][3])
            s.expect("the picture identifies its current rail", picture?.current == 0)
        })
    }

    @Test("#18 E13: every rail retains its own offset and remembered tile, which vertical traversal selects")
    func railsKeepIndependentMemoryAndOffsets() {
        requireCarousel(Scenario.run("map three independent rails") { s in
            let f = MapFixture(s, scene: .three)
            f.key("alt-k"); f.mac.clearMapHistory()
            let t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-j"); s.settle()
            f.expectShown(at: t0)
            let before = f.show(at: t0), expected = MapScene.three.picture()
            s.expect("rail two is current", before?.current == 1)
            s.expect("all three rails retain their prototype spans, offsets and remembered indices", mapRailsMatch(before?.rails, expected.rails))
            let next = f.mac.scheduler.now
            f.tessel.pressKey("alt-k"); s.settle()
            f.expectShown(at: next)
            s.expect("up lands on exactly the remembered tile shown on rail one", before?.rails.first?.remembered == 1
                && f.show(at: next)?.focus == .tile(1) && f.show(at: next)?.current == 0 && f.mac.focusedWindow == f.rails[0][1])
        })
    }

    @Test("#18 E14: hidden floats are counted and the shown layer selects its MRU then navigates with wrap")
    func floatCountVisibilityAndFocus() {
        requireCarousel(Scenario.run("map floating layer") { s in
            let f = MapFixture(s, scene: .floats, enabled: false)
            // Establish the prototype's most-recent float before enabling the map.
            f.key("alt-z"); f.key("alt-l"); f.key("alt-l"); f.key("alt-z")
            f.configure(); f.mac.clearMapHistory()
            var t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l"); s.settle()
            f.expectShown(at: t0)
            s.expect("all three floats are counted while hidden", f.show(at: t0)?.floats == 3 && f.show(at: t0)?.layerShown == false)
            t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-z"); s.settle()
            f.expectShown(at: t0)
            s.expect("entering the layer selects the most recent float", f.show(at: t0)?.layerShown == true
                && f.show(at: t0)?.focus == .float(2) && f.mac.focusedWindow == f.floats[2])
            for index in [0, 1, 2, 0] {
                t0 = f.mac.scheduler.now
                f.tessel.pressKey("alt-l"); s.settle()
                f.expectShown(at: t0)
                s.expect("layer navigation reaches float \(index), including the wrap", f.show(at: t0)?.focus == .float(index)
                    && f.mac.focusedWindow == f.floats[index])
            }
        })
    }

    @Test("#18 E15: a short rail stays at offset zero and its one-screen viewport extends beyond its final span")
    func shortRailKeepsBlankSpaceInTheViewport() {
        requireCarousel(Scenario.run("map short rail blank chamber") { s in
            let f = MapFixture(s, scene: .short), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l"); s.settle()
            f.expectShown(at: t0)
            let rail = f.show(at: t0)?.rails.first
            s.expect("the short rail has its two nominal spans", mapSpansMatch(rail?.spans, MapScene.short.picture().rails[0].spans))
            s.expect("the short rail never scrolls", rail?.offset == 0)
            let end = rail?.spans.last.map { $0.start + $0.width } ?? 2
            s.expect("the viewport includes trailing blank space", end < 1)
        })
    }

    @Test("#18 E16: switches and sends label only their destination and an empty workspace has no rails or floats")
    func workspaceLabelsBelongOnlyToSwitchesAndSends() {
        requireCarousel(Scenario.run("map destination workspace labels") { s in
            let f = MapFixture(s, enabled: false, selection: [0])
            // The prototype's workspace two contains a full-width singleton.
            let second = f.app.open(); s.settle()
            f.key("alt-shift-2"); f.key("alt-1")
            f.configure(); f.mac.clearMapHistory()
            var t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-2"); s.settle()
            f.expectShown(at: t0)
            s.expect("switching labels workspace two and draws its singleton", f.show(at: t0)?.workspace == 2
                && f.show(at: t0)?.rails.count == 1 && f.show(at: t0)?.rails.first?.spans.count == 1
                && f.mac.focusedWindow == second)
            t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-shift-3"); s.settle()
            f.expectShown(at: t0)
            s.expect("sending draws and labels the destination", f.show(at: t0)?.workspace == 3 && f.show(at: t0)?.focus == .tile(0)
                && f.tessel.status.active == 3 && f.tessel.windows.first { $0.id == second }?.workspace == 3)
            t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l"); s.settle()
            f.expectShown(at: t0)
            s.expect("an ordinary directional command carries no workspace number", f.show(at: t0)?.workspace == nil)
            // Move the only tile away, then switch to the now-empty workspace three.
            f.key("alt-shift-2")
            t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-3"); s.settle()
            f.expectShown(at: t0)
            s.expect("an empty destination still has a workspace label and no content", f.show(at: t0)?.workspace == 3
                && f.show(at: t0)?.rails == [] && f.show(at: t0)?.current == nil && f.show(at: t0)?.floats == 0
                && f.show(at: t0)?.focus == nil)
        })
    }
}

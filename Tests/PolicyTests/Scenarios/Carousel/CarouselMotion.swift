import CoreGraphics
import Foundation
import Simulator
import Ports
import Testing
@testable import Policy

@Suite @MainActor struct CarouselMotion {
    @Test("#26 E14: cards enter from 32 points, leave at the bottom, remember state and bounce at rail ends")
    func verticalCardsRememberEveryRailState() {
        requireCarousel(Scenario.run("vertical card stack") { s in
            let f = CarouselFixture(s, presets: [0.5,0.5,0.5,0.5,0.5]), ids = f.ids
            let topIDs = Array(ids.prefix(3)), bottomIDs = Array(ids.suffix(2))
            f.select(ids[3]); f.press("alt-shift-j")
            f.select(ids[4]); f.press("alt-shift-j"); f.press("alt-l")
            let bottom = f.snapshot(bottomIDs.filter { f.mac.isVisible($0) }), bottomFocus = f.mac.focusedWindow
            f.press("alt-k"); f.select(ids[0]); f.press("alt-l"); f.press("alt-l")
            f.pair(ids[1],ids[2],focused:ids[2])
            let top = f.snapshot(topIDs.filter { f.mac.isVisible($0) }), topFocus = f.mac.focusedWindow
            f.mac.clearMotionHistory(); f.press("alt-j")
            f.unchanged(bottom); f.expanded(ids[4])
            s.expect("bottom focus and expanded end are remembered", f.mac.focusedWindow == bottomFocus)
            let incoming = f.mac.geometryWrites.filter { $0.window == ids[4] && $0.attribute == .position }
            s.expect("incoming card has intermediate frames", f.mac.displaySamples.count >= 2 && incoming.count >= 2)
            f.near(Double(incoming.first?.requested.point?.y ?? -1), 1117 - 32, "incoming card begins at 32 visible points")
            let lastMotion = f.mac.geometryWrites.last?.at ?? Int.max
            s.expect("source rail is hidden at completion", topIDs.allSatisfy { !f.mac.isVisible($0) })
            s.expect("visible source tiles hide only after the last animated frame", top.keys.allSatisfy { id in
                f.mac.visibilityChanges.contains { !$0.showing && $0.windows.contains(id) && $0.at >= lastMotion }
            })
            f.mac.clearMotionHistory(); f.press("alt-k"); f.unchanged(top)
            s.expect("top middle stop and focus return", f.mac.focusedWindow == topFocus)
            let outgoing = f.mac.geometryWrites.filter { $0.window == ids[4] && $0.attribute == .position }
            f.near(Double(outgoing.last?.requested.point?.y ?? -1), 1117 - 32, "outgoing card ends with 32 points visible")
            s.expect("vertical writes never cross the menu bar", f.mac.geometryWrites.allSatisfy { $0.accepted.minY >= 33 })
            for key in ["alt-k", "alt-j", "alt-j"] {
                let rail = f.tessel.status.rail, before = f.snapshot(), focused = f.mac.focusedWindow
                f.mac.clearMotionHistory(); f.press(key)
                if key == "alt-k" || rail == 2 {
                    f.unchanged(before)
                    s.expect("vertical wall retains focus and rail", f.tessel.status.rail == rail && f.mac.focusedWindow == focused)
                    s.expect("vertical wall actually bounces", f.mac.geometryWrites.contains { $0.accepted != before[$0.window] })
                }
            }
        })
    }

    @Test("#26 E16: horizontal motion follows the display spring, writes each moving window once per frame and lands exactly", arguments: [80,400])
    func displayFramesCarryTheNormalizedSpring(duration: Int) {
        requireCarousel(Scenario.run("display spring duration=\(duration)") { s in
            let f = CarouselFixture(s, duration: duration), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.press("alt-l")
            let before = f.snapshot(), start = Double(f.mac.scheduler.now) / 1_000
            f.mac.clearMotionHistory(); f.press("alt-l")
            let samples = f.mac.displaySamples, writes = f.mac.geometryWrites
            s.expect("moving commands request display frames", samples.count >= 2)
            s.expect("frames are on the 120 Hz clock", samples.allSatisfy { abs($0.time * 120 - ($0.time * 120).rounded()) < 1e-6 })
            let positions = writes.filter { $0.attribute == .position && $0.frame > 0 }
            s.expect("the unchanged widths receive no size writes", !writes.contains { $0.attribute == .size })
            for frame in Set(positions.map(\.frame)).sorted() {
                let group = positions.filter { $0.frame == frame }
                s.expect("frame \(frame) has at most one position write per window", Set(group.map(\.window)).count == group.count)
                s.expect("frame \(frame) writes only moving windows", group.allSatisfy { [a,b,c].contains($0.window) })
                let times = group.map(\.at)
                s.expect("AX work fits one 120 Hz frame", (times.max() ?? 0) - (times.min() ?? 0) + 1 <= 8)
                if let sample = samples.indices.contains(frame - 1) ? samples[frame - 1] : nil {
                    let p = min(1, max(0, (sample.time - start) / (Double(duration) / 1_000)))
                    let expected = before[b]!.minX + (f.area.minX - before[b]!.minX) * carouselSpring(p)
                    let moved = group.filter { $0.window == b }
                    s.expect("the middle window gets exactly one position write in each moving frame", moved.count == 1)
                    f.near(Double(moved.first?.requested.point?.x ?? -1), expected, "frame \(frame) spring position")
                }
            }
            s.expect("the moving middle window has multiple frame writes", positions.filter { $0.window == b }.count >= 2)
            f.pair(b,c,focused:c)
            let final = writes.last { $0.window == b && $0.attribute == .position }
            f.near(Double(final?.accepted.minX ?? -1), f.area.minX, "last frame is exactly final")
            s.expect("animation settles by duration plus one screen frame", (samples.last?.time ?? .infinity) <= start + Double(duration)/1_000 + 1.0/120)
            let delivered = f.mac.displaySamples.count, requested = f.mac.displayFrameRequests, writesAtRest = f.mac.geometryWrites.count
            f.mac.scheduler.main.after(milliseconds: 1_000) {}; s.settle()
            s.expect("a completed animation delivers zero further frames or writes while idle", f.mac.displaySamples.count == delivered && f.mac.displayFrameRequests == requested && f.mac.geometryWrites.count == writesAtRest)
        })
    }

    @Test("#26 E16: width animation sizes only the changing tile and never writes an unchanged floating window")
    func widthMotionDoesNotRewriteUnchangedWindows() {
        requireCarousel(Scenario.run("width frame write budget") { s in
            let f = CarouselFixture(s), a = f.ids[0]
            let dialog = f.app.open(WindowSpec(subrole: "AXDialog")); s.settle(); f.select(a)
            f.mac.clearMotionHistory(); f.press("alt-r")
            let writes = f.mac.geometryWrites
            s.expect("width changes produce intermediate frames", f.mac.displaySamples.count >= 2)
            let sizes = writes.filter { $0.attribute == .size }
            s.expect("only the focused tile changes size", sizes.count >= 2 && sizes.allSatisfy { $0.window == a && !$0.hidden })
            for frame in Set(sizes.map(\.frame)) {
                s.expect("one size write per changing tile per frame", sizes.filter { $0.frame == frame }.count == 1)
                let work = writes.filter { $0.frame == frame }.map(\.at)
                s.expect("width frame AX budget fits the screen refresh", (work.max() ?? 0) - (work.min() ?? 0) + 1 <= 8)
            }
            s.expect("unmoved floats receive no writes", !writes.contains { $0.window == dialog })
            f.near(f.frame(a).width, f.width(2.0/3), "width motion restores the nominal cycle target")
        })
    }

    @Test("#26 E16: swaps, rail transfers, arrivals, closes and gap reloads animate on display frames", arguments: ["swap","transfer","open","close","gaps"])
    func everyLayoutChangingActionUsesDisplayFrames(action: String) {
        requireCarousel(Scenario.run("animated action \(action)") { s in
            let f = CarouselFixture(s)
            f.press("alt-l"); f.mac.clearMotionHistory()
            switch action {
            case "swap": f.press("alt-shift-l")
            case "transfer": f.press("alt-shift-j")
            case "open": _ = f.open()
            case "close": f.app.close(f.ids[1]); s.settle()
            default: f.tessel.changeConfig(CarouselFixture.config + "[gaps]\nouter = 12\n"); s.settle()
            }
            s.expect("layout-changing action actually delivers intermediate display frames", f.mac.displaySamples.count >= 2)
            s.expect("layout-changing action positions windows in those frames", f.mac.geometryWrites.contains { $0.frame > 0 && $0.attribute == .position })
            for frame in Set(f.mac.geometryWrites.filter { $0.frame > 0 }.map(\.frame)) {
                let writes = f.mac.geometryWrites.filter { $0.frame == frame }
                for attribute in [Ports.AXAttribute.position,.size] {
                    let selected = writes.filter { $0.attribute == attribute }
                    s.expect("each frame writes an attribute at most once per window", Set(selected.map(\.window)).count == selected.count)
                }
            }
        })
    }

    @Test("#26 E17: interrupt retargets from the displayed frame and keyboard repeats finish within one duration")
    func interruptionsRetargetWithoutQueuing() {
        requireCarousel(Scenario.run("thirty millisecond keyboard repeats") { s in
            let f = CarouselFixture(s, presets: Array(repeating: 0.5, count: 6)), ids = f.ids
            f.press("alt-l"); f.mac.clearMotionHistory()
            let start = f.mac.scheduler.now
            for offset in [0,30,60,90] { s.after(milliseconds: offset, "repeat at \(offset) ms") { f.tessel.pressKey("alt-l") } }
            s.settle(); f.pair(ids[4],ids[5],focused:ids[5])
            let lastPress = start + 90
            s.expect("repeat motion uses intermediate frames", f.mac.displaySamples.count >= 2)
            s.expect("no animation is queued behind the final key", f.mac.geometryWrites.allSatisfy { $0.at <= lastPress + 80 + 9 })
            s.expect("the final display frame is within duration plus one refresh", (f.mac.displaySamples.last?.time ?? .infinity) <= Double(lastPress + 80)/1_000 + 1.0/120)
        })
        requireCarousel(Scenario.run("reverse from current display frame") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l"); let initial = f.frame(b).minX, target = initial
            f.mac.clearMotionHistory(); let start = f.mac.scheduler.now
            var interruptedX = initial
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 30, "reverse at current frame") { interruptedX = f.frame(b).minX; f.tessel.pressKey("alt-h"); f.tessel.pressKey("alt-h") }
            s.settle()
            s.expect("the interruption occurs after real intermediate movement", interruptedX < initial - 1 && interruptedX > f.area.minX + 1)
            let after = f.mac.geometryWrites.filter { $0.window == b && $0.attribute == .position && $0.at >= start + 30 }
            s.expect("retarget has a new frame", !after.isEmpty)
            if let first = after.first, let x = first.requested.point?.x {
                s.expect("reversing starts from the current displayed position", x >= interruptedX - 1 && x < target - 1)
            }
            f.near(f.frame(b).minX, target, "reverse reaches the new target")
        })
    }

    @Test("#26 E17: a mouse drag interrupts motion and its requested frame survives settling")
    func mouseInterruptCancelsTheAnimatedTarget() {
        requireCarousel(Scenario.run("mouse interruption") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l"); f.mac.clearMotionHistory(); f.tessel.pressKey("alt-l")
            var dragged = CGPoint.zero
            s.after(milliseconds:30,"drag the moving window") {
                let current = f.frame(b)
                dragged = CGPoint(x:current.minX+23,y:current.minY+17)
                f.app.drag(b,to:dragged)
            }
            s.settle()
            s.expect("the drag interrupts a real animation", f.mac.displaySamples.count >= 2)
            s.expect("mouse geometry wins over the abandoned animation target", f.frame(b).origin == dragged)
            let count = f.mac.displaySamples.count
            f.mac.scheduler.main.after(milliseconds:1_000) {}; s.settle()
            s.expect("the abandoned animation requests no more frames", f.mac.displaySamples.count == count)
        })
    }

    @Test("#26 E18: zero duration and Reduce Motion write the final layout once without intermediate frames", arguments: ["zero", "startup", "notification"])
    func disabledMotionWritesOnlyFinalFrames(mode: String) {
        requireCarousel(Scenario.run("instant motion \(mode)") { s in
            let f = CarouselFixture(s, duration: mode == "zero" ? 0 : 80, reduced: mode == "startup")
            f.press("alt-l")
            if mode == "notification" {
                s.expect("motion is live before Reduce Motion changes", !f.mac.displaySamples.isEmpty)
                f.mac.setReduceMotion(true); s.settle()
            }
            f.mac.clearMotionHistory(); f.press("alt-l")
            f.pair(f.ids[1],f.ids[2],focused:f.ids[2])
            s.expect("instant commands request no screen frames", f.mac.displayFrameRequests == 0 && f.mac.displaySamples.isEmpty)
            let writes = f.mac.geometryWrites
            s.expect("the final layout is actually written", writes.contains { $0.attribute == .position })
            for id in f.ids {
                for attribute in [Ports.AXAttribute.position, .size] {
                    s.expect("instant command writes each final attribute at most once", writes.filter { $0.window == id && $0.attribute == attribute }.count <= 1)
                }
            }
        })
    }

    @Test("#26 E19: entering and leaving windows retain a one-point sliver, show before motion and hide after it")
    func closetTimingAndScreenEdgesAreSafeThroughoutMotion() {
        requireCarousel(Scenario.run("one-point horizontal edges and closet timing") { s in
            let f = CarouselFixture(s), a = f.ids[0], c = f.ids[2]
            f.press("alt-l"); f.mac.clearMotionHistory(); f.press("alt-l")
            let writes = f.mac.geometryWrites
            s.expect("edge safety is observed over multiple frames", f.mac.displaySamples.count >= 2)
            let animated = writes.filter { $0.frame > 0 && $0.attribute == .position }
            s.expect("windows really cross the screen edge", animated.contains { $0.window == a } && animated.contains { $0.window == c })
            for write in animated {
                if let point = write.requested.point {
                    s.expect("a requested frame keeps at least one point inside the screen", point.x <= 1727 && point.x + write.accepted.width >= 1)
                    f.near(write.accepted.minX, point.x, "macOS never snaps a wholly off-screen animated write back to forty points")
                }
            }
            let first = animated.filter { $0.window == c }.map(\.at).min() ?? -1
            s.expect("entering tile is shown before its first frame", f.mac.visibilityChanges.contains { $0.showing && $0.windows.contains(c) && $0.at <= first })
            let last = animated.map(\.at).max() ?? Int.max
            s.expect("leaving tile is hidden only after motion ends", f.mac.visibilityChanges.contains { !$0.showing && $0.windows.contains(a) && $0.at >= last })
            s.expect("leaving tile rests occluded in the closet", !f.mac.isVisible(a) && f.mac.isInCloset(a))
            f.press("alt-l"); f.press("alt-h"); f.press("alt-r")
            s.expect("no size is ever written in the closet", !f.mac.geometryWrites.contains { $0.hidden && $0.attribute == .size })
        })
    }

    @Test("#26 E20: a wall bounce displaces windows on display frames and returns exactly without changing focus", arguments: [80,400])
    func bounceIsVisibleAndReturnsExactly(duration: Int) {
        requireCarousel(Scenario.run("wall bounce duration=\(duration)") { s in
            let f = CarouselFixture(s, duration: duration), a = f.ids[0]
            let before = f.snapshot(), focus = f.mac.focusedWindow, start = Double(f.mac.scheduler.now)/1_000
            f.mac.clearMotionHistory(); f.press("alt-h")
            let samples = f.mac.displaySamples, bounceDuration = max(0.140, 0.9 * Double(duration)/1_000)
            s.expect("bounce requests frames and actually moves a tile", samples.count >= 2 && f.mac.geometryWrites.contains { $0.window == a && $0.accepted != before[a] })
            for write in f.mac.geometryWrites where write.window == a && write.attribute == .position && write.frame > 0 && write.frame <= samples.count {
                let p = min(1, max(0, (samples[write.frame - 1].time - start)/bounceDuration))
                let offset = sin(.pi * p) * exp(-2*p) * 0.045 * 1728
                f.near(Double(write.requested.point?.x ?? -1), before[a]!.minX + offset, "prototype damped bounce")
            }
            f.unchanged(before)
            s.expect("bounce leaves focus and rail unchanged", f.mac.focusedWindow == focus && f.tessel.status.rail == 1)
        })
    }
}

func carouselSpring(_ p: Double) -> Double { p >= 1 ? 1 : 1 - (1 + 7.43*p) * exp(-7.43*p) }

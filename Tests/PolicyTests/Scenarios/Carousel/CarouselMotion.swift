import CoreGraphics
import Foundation
import Simulator
import Ports
import Testing
@testable import Policy

@Suite @MainActor struct CarouselMotion {
    @Test("a native tab selection during motion publishes its successor after the final frame")
    func nativeTabChangeDuringMotionFinishesEnumeration() {
        requireCarousel(Scenario.run("native tab selection during motion") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5])
            let tabs = f.mac.launch()
            let spec = WindowSpec(frame: CGRect(x: 40, y: 60, width: 849, height: 1064), positionAcceptance: .screenEdges)
            let first = tabs.open(spec), next = tabs.open(spec)
            tabs.groupTabs([first,next], selected: first); s.settle()
            s.expect("the native group is known before motion", f.tessel.windows.first { $0.id == first }?.tabs == 2 && !f.tessel.windows.contains { $0.id == next })
            f.tessel.pressKey("alt-r")
            s.after(milliseconds: 30, "the user selects another native tab") { tabs.selectTab(next) }
            s.settle()
            s.expect("the group publishes only its selected successor", f.tessel.windows.count == 3 && f.tessel.windows.first { $0.id == next }?.tabs == 2 && !f.tessel.windows.contains { $0.id == first })
            f.focus(next)
        })
    }

    @Test("a downward card lands after its app outlasts the bounded preparation focus retries")
    func delayedDownwardFocusEventuallyLands() {
        requireCarousel(Scenario.run("late card focus after a busy app recovers") { s in
            let f = CarouselFixture(s), c = f.ids[2]
            f.select(c); f.press("alt-shift-j"); f.press("alt-k")
            f.app.busy(forMilliseconds: 2_000)
            f.tessel.pressKey("alt-j")
            s.after(milliseconds: 3_000, "the app has recovered") {
                f.expanded(c)
                s.expect("the source rail is hidden after recovered landing", !f.mac.isVisible(f.ids[0]))
            }
            s.settle()
        })
    }

    @Test("a missing display link still lands exactly and releases motion demand", arguments: [false, true])
    func missingDisplayFramesHaveABoundedLanding(stopsDuringMotion: Bool) {
        requireCarousel(Scenario.run("missing display frames during motion=\(stopsDuringMotion)") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.press("alt-l"); f.mac.clearMotionHistory()
            let before = f.snapshot()
            if !stopsDuringMotion { f.mac.setDisplayFramesAvailable(false) }
            f.tessel.pressKey("alt-l")
            if stopsDuringMotion {
                s.after(milliseconds: 30, "the display stops delivering frames") {
                    s.expect("motion began before losing the display", f.frame(b) != before[b])
                    f.mac.setDisplayFramesAvailable(false)
                }
            }
            s.after(milliseconds: 180, "the bounded landing is complete without another display callback") {
                f.pair(b,c,focused:c)
                s.expect("the leaving tile is hidden after landing", !f.mac.isVisible(a) && f.mac.isInCloset(a))
            }
            s.settle()
            s.expect("the absent display never delivered a callback", stopsDuringMotion || f.mac.displaySamples.isEmpty)
            let requests = f.mac.displayFrameRequests, writes = f.mac.geometryWrites.count
            f.mac.setDisplayFramesAvailable(true)
            f.mac.scheduler.main.after(milliseconds: 1_000) {}; s.settle()
            s.expect("landing releases demand and does no recurring idle work", f.mac.displayFrameRequests == requests && f.mac.geometryWrites.count == writes)
        })
    }

    @Test("retargeting while an AX size reply is in flight restores the requested pair")
    func retargetDuringAnUnconfirmedSizeWrite() {
        requireCarousel(Scenario.run("retarget an in-flight AX width") { s in
            let f = CarouselFixture(s, presets: [0.5,0.5], duration: 400), a = f.ids[0], b = f.ids[1]
            f.press("alt-l"); f.press("alt-h")
            f.tessel.pressKey("alt-h")
            let reading = f.mac.pause(after: .call("AccessibilityPort.copy AXPosition window \(a) \(f.app.alias)"))
            if case .paused = reading {} else { s.expect("the width frame is outstanding", false) }
            f.mac.scheduler.resume()
            let writing = f.mac.pause(after: .call("MainLane.async native event"))
            if case .paused = writing {} else { s.expect("the size write is returning", false) }
            s.expect("the native width changed before its reply", f.frame(a).width > 849)
            let interrupted = f.frame(a).width, mark = f.mac.geometryWrites.count
            f.tessel.pressKey("alt-l"); s.settle()
            let first = f.mac.geometryWrites.dropFirst(mark).first { $0.window == a && $0.attribute == .size }?.requested.size?.width ?? 0
            s.expect("the new spring starts from the native intermediate width", first > 849 && first < interrupted)
            f.pair(a,b,focused:b)
        })
        requireCarousel(Scenario.run("mutation reachability: failed current-frame read") { s in
            let f = CarouselFixture(s, presets:[0.5,0.5],duration:400), a=f.ids[0]
            f.press("alt-l"); f.press("alt-h")
            f.tessel.pressKey("alt-h")
            let reading=f.mac.pause(after:.call("AccessibilityPort.copy AXPosition window \(a) \(f.app.alias)"))
            if case .paused = reading {} else { s.expect("old width call is outstanding",false) }
            f.mac.scheduler.resume()
            let writing=f.mac.pause(after:.call("MainLane.async native event"))
            if case .paused = writing {} else { s.expect("old width is returning",false) }
            let interrupted=f.frame(a).width, mark=f.mac.geometryWrites.count
            s.expect("interrupted width is between half and two thirds",interrupted>f.width(0.5) && interrupted<f.width(2.0/3))
            f.app.busy(forMilliseconds:4)
            f.tessel.pressKey("alt-r"); s.settle()
            let after=f.mac.geometryWrites.dropFirst(mark).filter { $0.window == a && $0.attribute == .size }.compactMap { $0.requested.size?.width }
            s.expect("same-direction retarget never starts behind native width", !after.isEmpty && after.allSatisfy { $0 >= interrupted-1 })
            f.near(f.frame(a).width,f.width(2.0/3),"new width lands")
        })
    }

    @Test("cross-app card preparation preserves equal nominal widths through repeated reveals")
    func crossAppCardsPreserveNominalWidths() {
        for writes in WriteOrder.allCases {
            requireCarousel(Scenario.run("cross-app nominal widths", writes: writes) { s in
                s.mac.setScreen(ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084)))
                let first = s.mac.launch(), second = s.mac.launch()
                let spec = WindowSpec(frame: CGRect(x: 100, y: 120, width: 480, height: 328), positionAcceptance: .screenEdges)
                let a = first.open(spec), c = first.open(spec), b = second.open(spec), d = second.open(spec)
                first.select(a)
                let tessel = s.startTessel(); s.settle()
                tessel.changeConfig(CarouselFixture.config + "[animation]\nduration = 400\n"); s.settle()
                @MainActor func press(_ key: String) { tessel.pressKey(key); s.settle() }
                first.select(c); s.settle(); press("alt-shift-j")
                second.select(d); s.settle(); press("alt-shift-j")
                first.select(c); s.settle(); press("alt-k")
                first.select(a); s.settle(); press("alt-h"); press("alt-l")
                for id in [a,b] {
                    s.expect("equal initial nominal widths still stretch equally after card preparation: \(id) \(String(describing: s.mac.frame(id)))", abs((s.mac.frame(id)?.width ?? 0) - 849) <= 1)
                }
            })
        }
    }

    @Test("a clipped moving window still receives its exact final write after reaching the screen edge early")
    func clippedMotionAlwaysWritesTheFinalFrame() {
        requireCarousel(Scenario.run("final write after horizontal clamping") { s in
            let f = CarouselFixture(s, presets: Array(repeating: 0.5, count: 4), duration: 400), a = f.ids[0]
            f.press("alt-l"); f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-l"); f.tessel.pressKey("alt-l"); s.settle()
            let last = f.mac.geometryWrites.last { $0.window == a && $0.attribute == .position }
            s.expect("the final display batch includes the clipped window even when intermediate frames stopped changing", last?.frame == f.mac.displaySamples.count)
            f.near(Double(last?.accepted.maxX ?? -1), 1, "the leaving window's final write preserves one point")
        })
    }

    @Test("disabling during motion stops display demand and resumes ordinary catalog notifications")
    func disablingDuringMotionRestoresObservation() {
        requireCarousel(Scenario.run("disable an active carousel") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1]
            f.press("alt-l"); f.tessel.pressKey("alt-l")
            s.after(milliseconds: 30, "disable during movement") { f.tessel.changeConfig("") }
            s.settle()
            s.expect("the experiment is disabled", !f.tessel.status.enabled)
            let count = f.mac.displaySamples.count
            f.app.groupTabs([a,b], selected: a); s.settle()
            s.expect("ordinary native-tab notifications are observed after motion is disabled", f.tessel.windows.contains { $0.id == a && $0.tabs == 2 })
            s.expect("disabled motion requests no more display frames", f.mac.displaySamples.count == count)
        })
    }

    @Test("retargeting before the first tick uses the frame staged by a prior card reveal")
    func preparedFramesReplaceOlderMotionHistory() {
        requireCarousel(Scenario.run("card preparation replaces old geometry") { s in
            let fraction = 490.0 / 1718
            let f = CarouselFixture(s, presets: Array(repeating: fraction, count: 4)), ids = f.ids
            f.select(ids[1]); f.press("alt-shift-j")
            f.select(ids[3]); f.press("alt-shift-j"); f.press("alt-k")
            f.press("alt-h")
            f.pair(ids[0], ids[2], focused: ids[0])
            f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-h"); f.tessel.pressKey("alt-l"); s.settle()
            f.pair(ids[0], ids[2], focused: ids[2])
            s.expect("a canceled expansion does not replay geometry from an older rail", f.mac.geometryWrites.isEmpty)
        })
    }

    @Test("instant growth moves left before resizing and does not learn the screen edge as an app maximum")
    func instantGrowthAtTheRightEdge() {
        requireCarousel(Scenario.run("instant width at the right edge") { s in
            let f = CarouselFixture(s, duration: 0), b = f.ids[1]
            f.press("alt-l"); f.press("alt-r")
            f.near(f.frame(b).width, f.width(2.0/3), "right-hand half grows to two thirds")
            f.press("alt-r")
            f.near(f.frame(b).minX, f.area.minX, "full width moves to the left edge")
            f.near(f.frame(b).width, f.area.width, "screen position never becomes an intrinsic maximum")
        })
    }

    @Test("native fullscreen during motion cancels the landing and never enters the closet")
    func nativeFullscreenInterruptsMotion() {
        requireCarousel(Scenario.run("fullscreen interrupts an animated tile") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l"); f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-l")
            var fullscreenWrites = 0
            s.after(milliseconds: 30, "the selected app enters native fullscreen") {
                f.app.enterFullscreen(b)
                fullscreenWrites = f.mac.geometryWrites.count
            }
            s.settle()
            s.expect("fullscreen cancels later geometry writes", !f.mac.geometryWrites.dropFirst(fullscreenWrites).contains { $0.window == b })
            s.expect("the fullscreen window leaves workspace management", f.tessel.windows.first { $0.id == b }?.workspace == nil)
            s.expect("fullscreen never enters the closet", !f.mac.isInCloset(b))
            let delivered = f.mac.displaySamples.count
            f.mac.scheduler.main.after(milliseconds: 1_000) {}; s.settle()
            s.expect("fullscreen interrupts display demand", f.mac.displaySamples.count == delivered)
        })
    }

    @Test("a busy app drops intermediate frames while a healthy neighbor lands and receives focus")
    func busyAppDoesNotQueueHealthyMotion() {
        requireCarousel(Scenario.run("independent animated AX lanes") { s in
            let f = CarouselFixture(s), b = f.ids[1], c = f.ids[2]
            f.press("alt-l")
            let other = f.mac.launch()
            _ = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 849, height: 1064), positionAcceptance: .screenEdges))
            s.settle(); f.select(b)
            other.busy(forMilliseconds: 300)
            f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-l"); f.tessel.pressKey("alt-l")
            s.after(milliseconds: 120, "healthy lane has landed while its neighbor is busy") {
                f.focus(c)
                s.expect("healthy windows move on intermediate display frames", f.mac.geometryWrites.contains { $0.window == b && $0.frame > 0 })
            }
            s.settle()
            f.focus(c)
        })
    }

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
            @MainActor func expectRaiseBudget(since mark: Int) {
                let raises = f.mac.scheduler.trace.dropFirst(mark).filter { $0.contains("AccessibilityPort.perform AXRaise window") }
                for id in bottomIDs {
                    s.expect("moving card window \(id) is raised at most once", raises.filter { $0.contains("window \(id) ") }.count <= 1)
                }
            }
            var raiseMark = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory(); f.press("alt-j")
            expectRaiseBudget(since: raiseMark)
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
            raiseMark = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory(); f.press("alt-k"); f.unchanged(top)
            expectRaiseBudget(since: raiseMark)
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
            let finalFrame = Int(ceil((f.mac.displaySamples.last?.time ?? 0) * 1_000))
            s.expect("no AX batch queues behind the final display frame; its writes fit E16's eight-millisecond frame budget", f.mac.geometryWrites.allSatisfy { $0.at <= finalFrame + 7 })
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
                s.expect("reversing starts from the current displayed position (first \(x), interrupted \(interruptedX), target \(target))", x >= interruptedX - 1 && x < target - 1)
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
            var framesAtPress = 0
            s.after(milliseconds:30,"drag the moving window") {
                let current = f.frame(b)
                dragged = CGPoint(x:current.minX+23,y:current.minY+17)
                framesAtPress = f.mac.displaySamples.count
                f.app.drag(b,to:dragged)
            }
            s.settle()
            s.expect("the pointer press cancels even the already pending display callback", f.mac.displaySamples.count == framesAtPress)
            s.expect("the drag interrupts a real animation", f.mac.displaySamples.count >= 2)
            s.expect("mouse geometry wins over the abandoned animation target", f.frame(b).origin == dragged)
            let count = f.mac.displaySamples.count
            f.mac.scheduler.main.after(milliseconds:1_000) {}; s.settle()
            s.expect("the abandoned animation requests no more frames", f.mac.displaySamples.count == count)
        })
        requireCarousel(Scenario.run("mouse width interrupts an in-flight size animation") { s in
            let f = CarouselFixture(s), a = f.ids[0]
            f.tessel.pressKey("alt-r")
            s.after(milliseconds: 30, "resize the moving tile with the mouse") {
                f.app.drag(a, to: f.frame(a).origin)
                f.app.resize(a, to: CGSize(width: f.area.width * 0.4, height: f.area.height))
            }
            s.settle()
            f.near(f.frame(a).width, f.area.width * 0.4, "the interrupted mouse width wins")
            f.press("alt-l")
            f.near(f.frame(a).width, f.area.width * 0.4, "the next command preserves the adopted mouse width")
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
            f.mac.clearMotionHistory(); f.press("alt-r")
            s.expect("instant width changes request no screen frames", f.mac.displayFrameRequests == 0)
            for id in f.ids {
                for attribute in [Ports.AXAttribute.position, .size] {
                    s.expect("instant width changes write each attribute at most once", f.mac.geometryWrites.filter { $0.window == id && $0.attribute == attribute }.count <= 1)
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

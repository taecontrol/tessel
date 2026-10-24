import CoreGraphics
import Foundation
import Simulator
import Ports
import Testing
@testable import Policy

/// Animated carousel changes run on the stage: captures move in tessel's
/// overlay while each real window is placed once underneath.
@Suite @MainActor struct CarouselMotion {
    @Test("a native tab selection during motion publishes its successor")
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

    @Test("a capture that fails leaves the stage and places the windows at once")
    func failedCaptureFallsBackToInstant() {
        requireCarousel(Scenario.run("failed capture") { s in
            let f = CarouselFixture(s), b = f.ids[1], c = f.ids[2]
            f.press("alt-l"); f.mac.clearMotionHistory()
            f.mac.failCapture(of: c)
            f.press("alt-l")
            f.pair(b, c, focused: c)
            s.expect("nothing was shown", !f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            s.expect("the stage cleared", f.mac.stageEvents.last?.kind == .clear)
        })
        requireCarousel(Scenario.run("failed capture while focus is pending") { s in
            let f = CarouselFixture(s), b = f.ids[1], c = f.ids[2]
            f.press("alt-l"); f.mac.clearMotionHistory()
            f.mac.failCapture(of: c)
            // The app answers the focus request only after the stage gives up.
            f.app.busy(forMilliseconds: 150)
            f.press("alt-l")
            f.pair(b, c, focused: c)
        })
    }

    @Test("a slow app cannot keep frozen captures on screen past the linger limit")
    func slowPlacementLingersBoundedly() {
        requireCarousel(Scenario.run("slow placement") { s in
            let f = CarouselFixture(s), b = f.ids[1], c = f.ids[2]
            f.press("alt-l"); f.mac.clearMotionHistory()
            f.app.busy(forMilliseconds: 400)
            f.tessel.pressKey("alt-l")
            s.settle()
            let settled = f.mac.stageEvents.first { $0.kind == .settled }?.at ?? -1
            let cleared = f.mac.stageEvents.first { $0.kind == .clear }?.at ?? Int.max
            s.expect("the stage clears within the linger limit after settling (\(settled) → \(cleared))", settled >= 0 && cleared <= settled + 300)
            f.pair(b, c, focused: c)
        })
    }

    @Test("a retarget while a slow app holds the stage cancels the earlier settle and linger")
    func retargetCancelsTheEarlierLinger() {
        requireCarousel(Scenario.run("retarget during linger") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1]
            f.press("alt-l"); f.press("alt-l"); f.mac.clearMotionHistory()
            f.app.busy(forMilliseconds: 900)
            f.tessel.pressKey("alt-h"); f.tessel.pressKey("alt-h")
            s.after(milliseconds: 420, "go back while the stage lingers") { f.tessel.pressKey("alt-l"); f.tessel.pressKey("alt-l") }
            s.settle()
            let events = f.mac.stageEvents
            guard let last = events.lastIndex(where: { if case .move = $0.kind { true } else { false } }) else { s.expect("the stage moves", false); return }
            let after = events[(last + 1)...]
            let settled = after.firstIndex { $0.kind == .settled }, cleared = after.firstIndex { $0.kind == .clear }
            s.expect("the stage does not clear before the last move settles", settled != nil && cleared != nil && settled! < cleared!)
            s.expect("only the last motion clears the stage", events[..<last].allSatisfy { $0.kind != .clear })
            f.pair(b, f.ids[2], focused: f.ids[2])
            s.expect("the first window rests in the closet", !f.mac.isVisible(a))
        })
    }

    @Test("a command while a wall bounce captures its windows moves the real windows")
    func commandDuringBouncePreparation() {
        requireCarousel(Scenario.run("command during bounce preparation") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1]
            f.press("alt-l"); f.press("alt-l"); f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 10, "leave the wall before the bounce shows") { f.tessel.pressKey("alt-h"); f.tessel.pressKey("alt-h") }
            s.settle()
            f.pair(a, b, focused: a)
            s.expect("the stage showed once", f.mac.stageEvents.filter { if case .show = $0.kind { true } else { false } }.count == 1)
            s.expect("the stage cleared", f.mac.stageEvents.last?.kind == .clear)
        })
    }

    @Test("a tile parked a rounding error inside the screen edge rests in the closet, not as a sliver", arguments: [0, 250])
    func roundingErrorParksInTheCloset(duration: Int) {
        requireCarousel(Scenario.run("rounding sliver duration=\(duration)") { s in
            let f = CarouselFixture(s, presets: [0.5, 2.0 / 3, 1.0 / 3], duration: duration)
            let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            // Thirds put the left tile's target at maxX ≈ 2e-13 after the
            // third press, and the right one's at minX ≈ 1727.9999999999998.
            for key in ["alt-r", "alt-l", "alt-r", "alt-l", "alt-r", "alt-l", "alt-h", "alt-r", "alt-h", "alt-h", "alt-r", "alt-l", "alt-l"] {
                f.press(key)
                for id in f.ids {
                    let frame = f.frame(id), shown = frame.intersection(screen).width
                    s.expect("after \(key), window \(id) shows at least a point or rests in the closet (\(frame))", shown >= 1 || f.mac.isInCloset(id))
                }
            }
        })
    }

    @Test("a command while the stage fades into the real windows moves them only once it covers them again")
    func commandDuringRevealWaitsForCover() {
        requireCarousel(Scenario.run("command during reveal") { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1]
            f.press("alt-l"); f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-l")
            // Go back while the stage fades: its last call is the reveal.
            var reversedAt = Int.max
            let deadline = f.mac.scheduler.now + 2_000
            @MainActor func reverseDuringFade() {
                if f.mac.scheduler.trace.last(where: { $0.contains("MotionStagePort.") })?.contains("MotionStagePort.reveal") == true {
                    reversedAt = f.mac.scheduler.now
                    f.tessel.pressKey("alt-h"); f.tessel.pressKey("alt-h")
                } else if f.mac.scheduler.now < deadline {
                    f.mac.scheduler.main.after(milliseconds: 1) { reverseDuringFade() }
                }
            }
            reverseDuringFade()
            s.settle()
            let covered = f.mac.stageEvents.first { $0.kind == .covered && $0.at >= reversedAt }?.at ?? .max
            s.expect("the reverse came during the fade", reversedAt != .max)
            s.expect("the stage covers the windows again", covered != .max)
            s.expect("no real window moves before it does", !f.mac.geometryWrites.contains { $0.at >= reversedAt && $0.at < covered })
            s.expect("the reverse moves real windows", f.mac.geometryWrites.contains { $0.at >= covered })
            f.pair(a, b, focused: a)
        })
    }

    @Test("a window opened during the carousel starts its stand-in where it opened")
    func openedWindowStartsWhereItOpened() {
        requireCarousel(Scenario.run("opened window stand-in") { s in
            let f = CarouselFixture(s)
            f.press("alt-l"); f.mac.clearMotionHistory()
            let id = f.open()
            let shown = f.mac.stageEvents.compactMap { if case .show(let rects) = $0.kind { rects } else { nil } }.first
            s.expect("the stand-in starts at the opened frame, \(String(describing: shown?[id]))", shown?[id] == CGRect(x: 40, y: 60, width: 451, height: 400))
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

    @Test("native fullscreen during motion clears the stage and never enters the closet")
    func nativeFullscreenInterruptsMotion() {
        requireCarousel(Scenario.run("fullscreen interrupts an animated tile") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l"); f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 60, "the selected app enters native fullscreen") { f.app.enterFullscreen(b) }
            s.settle()
            s.expect("the fullscreen window leaves workspace management", f.tessel.windows.first { $0.id == b }?.workspace == nil)
            s.expect("fullscreen never enters the closet", !f.mac.isInCloset(b))
            s.expect("the stage cleared", f.mac.stageEvents.last?.kind == .clear)
        })
    }

    @Test("a hung app's placement retries stop while its neighbors land and take focus")
    func hungAppPlacementIsBounded() {
        requireCarousel(Scenario.run("hung placement retries stop") { s in
            let f = CarouselFixture(s), b = f.ids[1], c = f.ids[2]
            f.press("alt-l")
            let other = f.mac.launch()
            let d = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 849, height: 1064), positionAcceptance: .screenEdges))
            s.settle(); f.select(b)
            other.hang()
            let traceMark = f.mac.scheduler.trace.count
            f.tessel.pressKey("alt-l"); f.tessel.pressKey("alt-l")
            s.settle(); f.focus(c)
            let writes = f.mac.scheduler.trace.dropFirst(traceMark).filter {
                $0.contains("AccessibilityPort.set AXPosition=") && $0.contains("window \(d) \(other.alias)")
            }
            s.expect("one placement and four bounded retries, actual \(writes.count)", writes.count <= 5)
            let stopped = f.mac.scheduler.trace.count
            f.mac.scheduler.main.after(milliseconds: 5_000) {}; s.settle()
            s.expect("a permanently hung tile gets no later geometry attempts", !f.mac.scheduler.trace.dropFirst(stopped).contains {
                $0.contains("AccessibilityPort.set AXPosition=") && $0.contains("window \(d) \(other.alias)")
            })
            s.expect("the stage cleared within its linger limit", f.mac.stageEvents.last?.kind == .clear)
        })
    }

    @Test("#26 E16: an unfinished layout placement animates after its app resumes", arguments: WriteOrder.allCases)
    func resumedLayoutPlacementUsesTheStage(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("a focus retry stages an unfinished layout / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 250, appCount: 3)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[2]
            let original = f.frame(c), target = f.frame(b)
            f.focus(a); f.mac.clearMotionHistory()
            app.hang(); f.apps[1].close(b); s.settle()
            s.expect("C still owes the closed tile's layout slot", f.frame(c) == original && original != target)
            s.expect("the stage clears after the hung app's retries expire", f.mac.stageEvents.last?.kind == .clear)
            f.mac.clearMotionHistory()

            app.resume(); f.press("focus right")
            let events = f.mac.stageEvents
            let shown = events.compactMap { if case .show(let rects) = $0.kind { rects[c] } else { nil } }.first
            s.expect("the recovery stand-in starts at C's actual frame", shown == original)
            s.expect("the unfinished layout move animates to its target", events.contains {
                if case .move(let rects, let duration) = $0.kind { return rects[c] == target && duration == 250 }
                return false
            })
            let shownAt = events.first { if case .show = $0.kind { true } else { false } }?.at ?? .max
            let clearedAt = events.last { $0.kind == .clear }?.at ?? -1
            let positions = f.mac.geometryWrites.filter { $0.window == c && $0.attribute == .position }
            s.expect("C's position is written while the stage covers it", !positions.isEmpty && positions.allSatisfy { $0.at >= shownAt && $0.at <= clearedAt })
            s.expect("the stage clears after recovery", events.last?.kind == .clear)
            s.expect("C lands in the closed tile's slot", f.frame(c) == target)
            f.focus(c)
        })
    }

    @Test("#26 E16: an app-move correction stages an unfinished layout placement after its app resumes", arguments: WriteOrder.allCases)
    func appMoveStagesResumedLayoutPlacement(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("an app-move correction stages an unfinished layout / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 250, appCount: 3)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[2]
            let original = f.frame(c), target = f.frame(b), expectedA = f.frame(a)
            f.focus(a); f.mac.clearMotionHistory()
            app.hang(); f.apps[1].close(b); s.settle()
            s.expect("C still owes the closed tile's layout slot", f.frame(c) == original && original != target)
            s.expect("the stage clears after the hung app's retries expire", f.mac.stageEvents.last?.kind == .clear)
            f.mac.clearMotionHistory()

            app.resume(); f.app.moveFromApplication(a, to: CGPoint(x: 40, y: expectedA.minY)); s.settle()
            let events = f.mac.stageEvents
            let shown = events.compactMap { if case .show(let rects) = $0.kind { rects[c] } else { nil } }.first
            s.expect("the app-move recovery stand-in starts at C's actual frame", shown == original)
            s.expect("the mixed pending layout move animates to its target", events.contains {
                if case .move(let rects, let duration) = $0.kind { return rects[c] == target && duration == 250 }
                return false
            })
            let shownAt = events.first { if case .show = $0.kind { true } else { false } }?.at ?? .max
            let clearedAt = events.last { $0.kind == .clear }?.at ?? -1
            let positions = f.mac.geometryWrites.filter { $0.window == c && $0.attribute == .position }
            s.expect("C's position is written while the stage covers it", !positions.isEmpty && positions.allSatisfy { $0.at >= shownAt && $0.at <= clearedAt })
            s.expect("the stage clears after app-move recovery", events.last?.kind == .clear)
            s.expect("C lands in the closed tile's slot", f.frame(c) == target)
            s.expect("A returns to its expected frame", f.frame(a) == expectedA)
            f.focus(a)
        })
    }

    @Test("a cross-app rail change keeps its focus when the completing activation keys the app's previous window")
    func activationKeysPreviousWindow() {
        requireCarousel(Scenario.run("activation keys the previous window") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5]), y = f.ids[1]
            let other = f.mac.launch()
            let spec = WindowSpec(frame: CGRect(x: 40, y: 60, width: 849, height: 1064), positionAcceptance: .screenEdges)
            let b = other.open(spec), d = other.open(spec)
            s.settle()
            f.select(y); f.press("alt-shift-j")
            other.select(d); s.settle(); f.press("alt-shift-j")
            f.press("alt-k"); other.select(b); s.settle(); f.focus(b)
            f.press("alt-j"); f.focus(d)
            f.press("alt-h"); f.focus(y)
            s.expect("the other app's last key window is in the bottom rail", other.focusedWindow == d)
            other.restoreKeyOverClosetOnNextActivation()
            f.press("alt-k")
            f.focus(b)
            s.expect("the top rail stays current", f.tessel.status.rail == 1 && !f.mac.isVisible(d))
        })
    }

    @Test("#26 E14: a rail change slides both rails as one sheet, swaps the real rails once underneath, and each rail remembers its state")
    func railsSlideAsOneSheet() {
        requireCarousel(Scenario.run("vertical sheet") { s in
            let f = CarouselFixture(s, presets: [0.5,0.5,0.5,0.5,0.5]), ids = f.ids
            let topIDs = Array(ids.prefix(3)), bottomIDs = Array(ids.suffix(2))
            f.select(ids[3]); f.press("alt-shift-j")
            f.select(ids[4]); f.press("alt-shift-j")
            let bottom = f.snapshot(bottomIDs.filter { f.mac.isVisible($0) }), bottomFocus = f.mac.focusedWindow
            f.press("alt-k"); f.select(ids[0]); f.press("alt-l"); f.press("alt-l")
            f.pair(ids[1],ids[2],focused:ids[2])
            let top = f.snapshot(topIDs.filter { f.mac.isVisible($0) }), topFocus = f.mac.focusedWindow
            let shift = f.area.height + 10
            f.mac.clearMotionHistory(); f.press("alt-j")
            f.unchanged(bottom); f.pair(ids[3], ids[4], focused: ids[4])
            s.expect("bottom focus is remembered", f.mac.focusedWindow == bottomFocus)
            let shows = f.mac.stageEvents.compactMap { if case .show(let rects) = $0.kind { rects } else { nil } }
            let moves = f.mac.stageEvents.compactMap { if case .move(let rects, _) = $0.kind { rects } else { nil } }
            s.expect("one show and one move", shows.count == 1 && moves.count == 1)
            if let show = shows.first, let move = moves.first {
                for id in top.keys { s.expect("leaving window \(id) starts in place and leaves upward by one rail", show[id] == top[id] && move[id]?.minY == top[id]!.minY - shift) }
                if let start = show[ids[4]], let end = move[ids[4]] {
                    f.near(start.minY, end.minY + shift, "the entering rail starts one rail below")
                    f.near(end.minX, bottom[ids[4]]!.minX, "the entering rail lands at its remembered stop")
                }
            }
            let shownAt = f.mac.stageEvents.first { if case .show = $0.kind { true } else { false } }?.at ?? Int.max
            let clearedAt = f.mac.stageEvents.last { $0.kind == .clear }?.at ?? -1
            s.expect("no real window moves before the stage shows", f.mac.geometryWrites.allSatisfy { $0.at >= shownAt })
            s.expect("the real rails swap under the stage", f.mac.visibilityChanges.filter { !$0.windows.isEmpty }.allSatisfy { $0.at >= shownAt && $0.at <= clearedAt })
            s.expect("each real window is positioned at most once", Set(f.mac.geometryWrites.filter { $0.attribute == .position }.map(\.window)).count
                     == f.mac.geometryWrites.filter { $0.attribute == .position }.count)
            s.expect("source rail is hidden", topIDs.allSatisfy { !f.mac.isVisible($0) })
            f.mac.clearMotionHistory(); f.press("alt-k"); f.unchanged(top)
            s.expect("top middle stop and focus return", f.mac.focusedWindow == topFocus)
            let up = f.mac.stageEvents.compactMap { if case .move(let rects, _) = $0.kind { rects } else { nil } }.first
            if let leaving = up?[ids[4]] { f.near(leaving.minY, f.area.minY + shift, "going up, the leaving rail goes down") }
            for key in ["alt-k", "alt-j", "alt-j"] {
                let rail = f.tessel.status.rail, before = f.snapshot(), focused = f.mac.focusedWindow
                f.mac.clearMotionHistory(); f.press(key)
                if key == "alt-k" || rail == 2 {
                    f.unchanged(before)
                    s.expect("vertical wall retains focus and rail", f.tessel.status.rail == rail && f.mac.focusedWindow == focused)
                    let nudges = f.mac.stageEvents.compactMap { if case .move(let rects, _) = $0.kind { rects } else { nil } }
                    s.expect("vertical wall bounces on the stage", nudges.count == 2 && nudges[0].values.contains { $0.minY != f.area.minY })
                }
            }
        })
    }

    @Test("#26 E16: horizontal motion shows captures where the windows are, moves them to the layout, and places each real window once underneath", arguments: [80, 250])
    func horizontalMotionRunsOnTheStage(duration: Int) {
        requireCarousel(Scenario.run("stage motion duration=\(duration)") { s in
            let f = CarouselFixture(s, duration: duration), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.press("alt-l")
            let before = f.snapshot(), start = f.mac.scheduler.now
            f.mac.clearMotionHistory(); f.press("alt-l")
            let events = f.mac.stageEvents
            let captures = Set(events.compactMap { if case .capture(let id) = $0.kind { id } else { nil } })
            s.expect("every window seen during the motion is captured, and the background", captures == [a, b, c] && events.contains { $0.kind == .background })
            guard let show = events.firstIndex(where: { if case .show = $0.kind { true } else { false } }),
                  case .show(let shown) = events[show].kind else { s.expect("the stage shows", false); return }
            s.expect("stand-ins start exactly where the windows are", shown[a] == before[a] && shown[b] == before[b])
            let moves = events.compactMap { if case .move(let rects, let ms) = $0.kind { (rects, ms) } else { nil } }
            s.expect("one move over the configured duration", moves.count == 1 && moves.first?.1 == duration)
            if let move = moves.first?.0 {
                f.near(Double(move[b]?.minX ?? -1), f.area.minX, "the stand-in lands at the layout")
                s.expect("the leaving window's stand-in moves off screen unclamped", (move[a]?.maxX ?? 1) <= 0)
            }
            let shownAt = events[show].at
            s.expect("no real window changes before the stage covers it", f.mac.geometryWrites.allSatisfy { $0.at >= shownAt }
                     && f.mac.visibilityChanges.filter { !$0.windows.isEmpty }.allSatisfy { $0.at >= shownAt })
            for id in [a, b, c] {
                for attribute in [Ports.AXAttribute.position, .size] {
                    s.expect("window \(id) gets at most one \(attribute) write", f.mac.geometryWrites.filter { $0.window == id && $0.attribute == attribute }.count <= 1)
                }
            }
            s.expect("unchanged widths get no size writes", !f.mac.geometryWrites.contains { $0.attribute == .size })
            let cleared = events.last { $0.kind == .clear }?.at ?? Int.max
            let lastWrite = f.mac.geometryWrites.map(\.at).max() ?? 0
            s.expect("the stage clears after settling and after the last placement", cleared >= lastWrite && events.contains { $0.kind == .settled && $0.at <= cleared })
            s.expect("the stage clears once WindowServer shows the placements", events.contains { $0.kind == .revealed && $0.at <= cleared })
            s.expect("the stage clears within one duration of the press, plus captures (\(cleared - start) ms)", cleared - start <= duration + 120)
            f.pair(b,c,focused:c)
            let count = f.mac.stageEvents.count, writes = f.mac.geometryWrites.count
            f.mac.scheduler.main.after(milliseconds: 1_000) {}; s.settle()
            s.expect("nothing happens at rest", f.mac.stageEvents.count == count && f.mac.geometryWrites.count == writes)
        })
    }

    @Test("#26 E16: a width change resizes only the changing tile once and crossfades its capture once the app accepts it")
    func widthMotionRefreshesTheResizedCapture() {
        requireCarousel(Scenario.run("width under the stage") { s in
            let f = CarouselFixture(s), a = f.ids[0]
            let dialog = f.app.open(WindowSpec(subrole: "AXDialog")); s.settle(); f.select(a)
            f.mac.clearMotionHistory(); f.press("alt-r")
            let sizes = f.mac.geometryWrites.filter { $0.attribute == .size }
            s.expect("only the focused tile is resized, once", sizes.count == 1 && sizes.first?.window == a && sizes.first?.hidden == false)
            let refreshed = f.mac.stageEvents.first { $0.kind == .refresh(a) }?.at ?? -1
            s.expect("its capture is refreshed after the size write", refreshed >= (sizes.first?.at ?? Int.max))
            s.expect("unmoved floats receive no writes", !f.mac.geometryWrites.contains { $0.window == dialog })
            f.near(f.frame(a).width, f.width(2.0/3), "width lands at the nominal cycle target")
        })
    }

    @Test("#26 E16: swaps, rail transfers, arrivals, closes and gap reloads run on the stage", arguments: ["swap","transfer","open","close","gaps"])
    func everyLayoutChangingActionUsesTheStage(action: String) {
        requireCarousel(Scenario.run("staged action \(action)") { s in
            let f = CarouselFixture(s)
            f.press("alt-l"); f.mac.clearMotionHistory()
            switch action {
            case "swap": f.press("alt-shift-l")
            case "transfer": f.press("alt-shift-j")
            case "open": _ = f.open()
            case "close": f.app.close(f.ids[1]); s.settle()
            default: f.tessel.changeConfig(CarouselFixture.config + "[gaps]\nouter = 12\n"); s.settle()
            }
            let shownAt = f.mac.stageEvents.first { if case .show = $0.kind { true } else { false } }?.at
            s.expect("the change is shown and moved on the stage", shownAt != nil && f.mac.stageEvents.contains { if case .move = $0.kind { true } else { false } })
            s.expect("real geometry changes only under the stage", f.mac.geometryWrites.allSatisfy { $0.at >= (shownAt ?? Int.max) })
            s.expect("the stage clears", f.mac.stageEvents.last?.kind == .clear)
        })
    }

    @Test("#26 E17: repeated commands retarget the stand-ins from where they are and land within one duration of the last press")
    func repeatsRetargetTheStage() {
        requireCarousel(Scenario.run("thirty millisecond keyboard repeats") { s in
            let f = CarouselFixture(s, presets: Array(repeating: 0.5, count: 6)), ids = f.ids
            f.press("alt-l"); f.mac.clearMotionHistory()
            let start = f.mac.scheduler.now
            for offset in [0,30,60,90] { s.after(milliseconds: offset, "repeat at \(offset) ms") { f.tessel.pressKey("alt-l") } }
            s.settle(); f.pair(ids[4],ids[5],focused:ids[5])
            let shows = f.mac.stageEvents.filter { if case .show = $0.kind { true } else { false } }
            let moves = f.mac.stageEvents.compactMap { if case .move(let rects, _) = $0.kind { rects } else { nil } }
            s.expect("one stage shows the whole run", shows.count == 1)
            if let last = moves.last { f.near(Double(last[ids[5]]?.maxX ?? -1), f.area.maxX, "the last move targets the final stop") }
            let cleared = f.mac.stageEvents.last { $0.kind == .clear }?.at ?? Int.max
            s.expect("the run lands within one duration of the last press (\(cleared - start - 90) ms)", cleared <= start + 90 + 250)
        })
        requireCarousel(Scenario.run("reverse on the stage") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l"); let target = f.frame(b)
            f.mac.clearMotionHistory()
            f.tessel.pressKey("alt-l")
            // After the captures, once the stand-ins are moving.
            s.after(milliseconds: 150, "reverse during the motion") { f.tessel.pressKey("alt-h"); f.tessel.pressKey("alt-h") }
            s.settle()
            let moves = f.mac.stageEvents.compactMap { if case .move(let rects, _) = $0.kind { rects } else { nil } }
            s.expect("the reverse retargets the moving stand-ins", moves.count >= 2 && moves.last?[b] == target)
            s.expect("the stage showed once", f.mac.stageEvents.filter { if case .show = $0.kind { true } else { false } }.count == 1)
            f.near(f.frame(b).minX, target.minX, "the reverse lands")
        })
    }

    @Test("#26 E17: a mouse press clears the stage at once, and the user's geometry survives")
    func mouseInterruptClearsTheStage() {
        requireCarousel(Scenario.run("mouse interruption") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l"); f.mac.clearMotionHistory(); f.tessel.pressKey("alt-l")
            var dragged = CGPoint.zero, pressedAt = 0
            s.after(milliseconds: 90, "drag the moving window") {
                let current = f.frame(b)
                dragged = CGPoint(x: current.minX + 23, y: current.minY + 17)
                pressedAt = f.mac.scheduler.now
                f.app.drag(b, to: dragged)
            }
            s.settle()
            s.expect("the press clears the stage at once", f.mac.stageEvents.contains { $0.kind == .clear && $0.at == pressedAt })
            s.expect("mouse geometry wins over the abandoned target", f.frame(b).origin == dragged)
        })
        requireCarousel(Scenario.run("mouse width interrupts a width change") { s in
            let f = CarouselFixture(s), a = f.ids[0]
            f.tessel.pressKey("alt-r")
            s.after(milliseconds: 90, "resize the tile with the mouse") {
                f.app.drag(a, to: f.frame(a).origin)
                f.app.resize(a, to: CGSize(width: f.area.width * 0.4, height: f.area.height))
            }
            s.settle()
            f.near(f.frame(a).width, f.area.width * 0.4, "the mouse width wins")
            f.press("alt-l")
            f.near(f.frame(a).width, f.area.width * 0.4, "the next command preserves the adopted mouse width")
        })
        requireCarousel(Scenario.run("a stand-in starts where the user moved its window") { s in
            let f = CarouselFixture(s), b = f.ids[1]
            f.press("alt-l")
            var dragged = f.frame(b)
            dragged.origin.x += 100
            f.app.drag(b, to: dragged.origin); s.settle()
            f.mac.clearMotionHistory(); f.press("alt-r")
            let shown = f.mac.stageEvents.compactMap { if case .show(let rects) = $0.kind { rects } else { nil } }.first
            s.expect("the stand-in starts at the observed window, not the layout", shown?[b] == dragged)
        })
    }

    @Test("#26 E18: zero duration, Reduce Motion and a missing Screen Recording grant place the final layout once without the stage", arguments: ["zero", "startup", "notification", "permission"])
    func disabledMotionWritesOnlyFinalFrames(mode: String) {
        requireCarousel(Scenario.run("instant motion \(mode)") { s in
            if mode == "permission" { s.mac.setScreenRecording(false) }
            let f = CarouselFixture(s, duration: mode == "zero" ? 0 : 250, reduced: mode == "startup")
            f.press("alt-l")
            if mode == "notification" {
                // Out to the end and back, so the next command moves the rail.
                f.press("alt-l")
                s.expect("motion is live before Reduce Motion changes", f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
                f.press("alt-h"); f.press("alt-h"); f.press("alt-l")
                f.mac.setReduceMotion(true); s.settle()
            }
            let reason = ["zero": "off: duration 0", "startup": "off: Reduce Motion", "notification": "off: Reduce Motion",
                          "permission": "off: Screen Recording permission needed"][mode]!
            s.expect("status explains why motion is off: \(f.tessel.status.motion)", f.tessel.status.motion == reason && f.tessel.status.animationDuration == 0)
            if mode == "permission" {
                s.expect("Screen Recording is requested once", f.mac.stageEvents.filter { $0.kind == .accessRequest }.count == 1)
            }
            f.mac.clearMotionHistory(); f.press("alt-l")
            f.pair(f.ids[1],f.ids[2],focused:f.ids[2])
            s.expect("instant commands never use the stage", f.mac.stageEvents.isEmpty)
            let writes = f.mac.geometryWrites
            s.expect("the final layout is actually written", writes.contains { $0.attribute == .position })
            for id in f.ids {
                for attribute in [Ports.AXAttribute.position, .size] {
                    s.expect("instant command writes each final attribute at most once", writes.filter { $0.window == id && $0.attribute == attribute }.count <= 1)
                }
            }
            f.mac.clearMotionHistory(); f.press("alt-r")
            s.expect("instant width changes never use the stage", f.mac.stageEvents.isEmpty)
        })
    }

    @Test("#26 E19: entering and leaving windows cross the closet only under the stage, and nothing is sized in the closet")
    func closetTimingIsHiddenByTheStage() {
        requireCarousel(Scenario.run("closet timing under the stage") { s in
            let f = CarouselFixture(s), a = f.ids[0], c = f.ids[2]
            f.press("alt-l"); f.mac.clearMotionHistory(); f.press("alt-l")
            let shownAt = f.mac.stageEvents.first { if case .show = $0.kind { true } else { false } }?.at ?? Int.max
            let clearedAt = f.mac.stageEvents.last { $0.kind == .clear }?.at ?? -1
            s.expect("the entering tile was captured from the closet", f.mac.stageEvents.contains { $0.kind == .capture(c) })
            s.expect("entering tile leaves the closet under the stage", f.mac.visibilityChanges.contains { $0.showing && $0.windows.contains(c) && $0.at >= shownAt && $0.at <= clearedAt })
            s.expect("leaving tile enters the closet under the stage", f.mac.visibilityChanges.contains { !$0.showing && $0.windows.contains(a) && $0.at >= shownAt && $0.at <= clearedAt })
            s.expect("leaving tile rests occluded in the closet", !f.mac.isVisible(a) && f.mac.isInCloset(a))
            f.press("alt-l"); f.press("alt-h"); f.press("alt-r")
            s.expect("no size is ever written in the closet", !f.mac.geometryWrites.contains { $0.hidden && $0.attribute == .size })
        })
    }

    @Test("#26 E20: a wall bounce recoils the stand-ins away from the wall and back without moving a real window or changing focus", arguments: [80, 250])
    func bounceRunsOnTheStage(duration: Int) {
        requireCarousel(Scenario.run("wall bounce duration=\(duration)") { s in
            let f = CarouselFixture(s, duration: duration), a = f.ids[0]
            let before = f.snapshot(), focus = f.mac.focusedWindow
            f.mac.clearMotionHistory(); f.press("alt-h")
            let moves = f.mac.stageEvents.compactMap { if case .move(let rects, let ms) = $0.kind { (rects, ms) } else { nil } }
            s.expect("the bounce recoils away from the wall and back", moves.count == 2 && (moves.first?.0[a]?.minX ?? 0) > before[a]!.minX && moves.last?.0[a] == before[a])
            s.expect("each leg is short whatever the duration", moves.allSatisfy { $0.1 == 70 })
            s.expect("no real window moves", f.mac.geometryWrites.isEmpty)
            s.expect("the stage clears", f.mac.stageEvents.last?.kind == .clear)
            f.unchanged(before)
            s.expect("bounce leaves focus and rail unchanged", f.mac.focusedWindow == focus && f.tessel.status.rail == 1)
        })
    }
}

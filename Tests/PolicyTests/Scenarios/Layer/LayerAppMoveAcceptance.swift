import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerAppMoveAcceptance {
    private static let target = CGRect(x: 869, y: 43, width: 849, height: 1064)
    private static let moved = CGPoint(x: 1100, y: 43)
    private static let dropped = CGPoint(x: 820, y: 43)

    @Test("#39 E4: a read move whose placement goes unanswered retries when the app answers", arguments: WriteOrder.allCases)
    func unansweredMoveRetriesAfterTheAppAnswers(_ writes: WriteOrder) {
        requireLayer(Scenario.run("a read move recovers after unanswered placement / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1]
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
            s.settle(); f.select(f.ids[0]); f.press("toggle layer")
            app.moveFromApplication(b, to: Self.moved)
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXEnhancedUserInterface \(app.alias) pid=\(app.pid)")), "the correction is held before its write", s)
            app.hang(); app.moveFromApplication(b, to: Self.moved); s.settle()
            // The failed exit remains pending on the read, displaced frame.
            // It must not be mistaken for a placement still waiting to start.
            f.press("toggle layer")
            s.expect("the unanswered tile remains displaced: \(f.frame(b))", f.frame(b).origin == Self.moved)
            app.resume(); app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("the recovery snapshot retries the pending tile", f.frame(b) == Self.target)
            s.expect("the prepared tile releases the float", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        })
    }

    @Test("#39 E8: clicking an unchanged tile does not reset another tile's two corrections", arguments: WriteOrder.allCases)
    func unrelatedClickKeepsCorrectionCount(_ writes: WriteOrder) {
        requireLayer(Scenario.run("an unrelated click keeps B's allowance / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1]
            for x in [1100.0, 1120] {
                app.moveFromApplication(b, to: CGPoint(x: x, y: 43)); s.settle()
                s.expect("B uses its correction", f.frame(b) == Self.target)
            }
            f.mac.pointerDown(); f.mac.pointerUp(); s.settle()
            let start = f.mac.scheduler.trace.count, third = CGPoint(x: 1140, y: 43)
            app.moveFromApplication(b, to: third); s.settle()
            s.expect("an unrelated click leaves B's third move conceded", f.frame(b).origin == third && positionWrites(f, b, since: start) == 0)
        })
    }

    @Test("#39 E8: a layout superseding a correction resets the allowance", arguments: WriteOrder.allCases)
    func layoutSupersedesCorrection(_ writes: WriteOrder) {
        requireLayer(Scenario.run("a layout supersedes B's second correction / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1]
            app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("B used its first correction", f.frame(b) == Self.target)
            app.moveFromApplication(b, to: CGPoint(x: 1120, y: 43))
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXPosition=869.0,43.0 window \(b) \(app.alias)")), "B's second correction write is held", s)
            f.tessel.press("workspace 2"); _ = f.mac.scheduler.run()
            f.tessel.press("workspace 1"); _ = f.mac.scheduler.run()
            s.settle()
            s.expect("the superseding layout places B", f.frame(b) == Self.target)
            for x in [1100.0, 1120] {
                app.moveFromApplication(b, to: CGPoint(x: x, y: 43)); s.settle()
                s.expect("the layout reset grants each of two corrections", f.frame(b) == Self.target)
            }
            let third = CGPoint(x: 1140, y: 43)
            app.moveFromApplication(b, to: third); s.settle()
            s.expect("the third move after the layout is conceded", f.frame(b).origin == third)
        })
    }

    @Test("#39 E1 / #39 E9: a correction preserves coalesced native focus without stage or screenshots", arguments: WriteOrder.allCases, [1, 2])
    func appMovePreservesCoalescedNativeFocus(_ writes: WriteOrder, _ appCount: Int) {
        requireLayer(Scenario.run("native focus shares an app-move snapshot / apps \(appCount) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 250, appCount: appCount)
            let a = f.ids[0], b = f.ids[1], app = f.apps[1 % appCount], width = f.frame(a).width
            let start = f.mac.scheduler.trace.count
            let events = f.mac.stageEvents.count, screenshots = f.mac.stageCaptureRequests.count
            app.select(b); app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("the move is corrected once without taking native focus", f.frame(b) == Self.target && f.mac.focusedWindow == b && positionWrites(f, b, since: start) == 1)
            s.expect("coalesced focus neither shows nor clears a stage", f.mac.stageEvents.count == events)
            s.expect("coalesced focus leaves stageScreenshots unchanged", f.mac.stageCaptureRequests.count == screenshots)
            f.press("cycle width")
            f.near(f.frame(b).width, f.width(2.0 / 3), "the next command acts on the native selection")
            s.expect("the prior policy selection is unchanged", f.frame(a).width == width)
        })
    }

    @Test("#39 E11: correcting one tile preserves a keyboard focus request waiting in another app", arguments: WriteOrder.allCases)
    func correctionPreservesPendingKeyboardFocus(_ writes: WriteOrder) {
        requireLayer(Scenario.run("a correction carries pending keyboard focus / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], app = f.apps[1], original = f.frame(a)
            f.tessel.press("focus right")
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(app.alias) pid=\(app.pid)")), "B's focus request is held before activation", s)
            f.app.moveFromApplication(a, to: CGPoint(x: original.minX + 30, y: original.minY))
            expectPaused(f.mac.scheduler.run(), "A is corrected while B's old focus request stays held", s)
            s.expect("A's correction does not wait for the other app", f.frame(a) == original)
            s.settle()
            s.expect("the correction preserves the requested keyboard focus", f.mac.focusedWindow == b)
        })
    }

    @Test("#39 E1: a correction keeps a native focus decision scheduled by an earlier snapshot", arguments: WriteOrder.allCases)
    func correctionPreservesEarlierNativeFocus(_ writes: WriteOrder) {
        requireLayer(Scenario.run("a correction keeps an earlier native focus decision / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 0)
            let a = f.ids[0], b = f.ids[1], width = f.frame(a).width
            f.app.select(b)
            expectPaused(f.mac.deliver(f.app), "the native selection's snapshot is delivered", s)
            f.app.moveFromApplication(a, to: CGPoint(x: 40, y: 43)); s.settle()
            s.expect("A is corrected without changing native focus", f.frame(a).minX == 10 && f.mac.focusedWindow == b)
            f.press("cycle width")
            f.near(f.frame(b).width, f.width(2.0 / 3), "the earlier native focus decision still selects B")
            s.expect("the old policy selection keeps its width", f.frame(a).width == width)
        })
    }

    @Test("#39 E6 / #39 E11 / #39 E14: a queued layout placement keeps its target across focus and native replacement", arguments: WriteOrder.allCases, [false, true])
    func queuedLayoutKeepsItsTarget(_ writes: WriteOrder, _ replace: Bool) {
        requireLayer(Scenario.run("a queued own placement keeps its layout reason / replace \(replace) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 0, appCount: 3)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[2], target = f.frame(b).origin
            var replacement: UInt32?
            if replace {
                let tab = f.app.open(WindowSpec(frame: f.frame(a), positionAcceptance: .screenEdges), background: true)
                f.app.groupTabs([a, tab], selected: a); s.settle()
                replacement = tab
            }
            f.app.drag(a, to: CGPoint(x: 610, y: 43)); s.settle()
            f.apps[1].close(b)
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXPosition=\(target.x),\(target.y) window \(c) \(app.alias)")), "C's layout write is held ahead of A", s)
            f.app.moveFromApplication(a, to: CGPoint(x: 630, y: 43))
            expectPaused(f.mac.scheduler.run(), "A's move is read while its own placement waits for C", s)
            if let replacement {
                f.app.selectTabInBackground(replacement)
                expectPaused(f.mac.scheduler.run(), "the queued layout moves to the native replacement", s)
                s.expect("the replacement owns A's rail slot", f.tessel.windows.contains { $0.id == replacement } && !f.tessel.windows.contains { $0.id == a })
            }
            f.tessel.press("focus right")
            expectPaused(f.mac.scheduler.run(), "the focus render supersedes the queued layout", s)
            s.settle()
            s.expect("the pending own placement finishes at layout, not the old pointer drop", f.frame(replacement ?? a).minX == 10)
        })
    }

    @Test("#39 E8 / #39 E11: a queued layout supersedes an owed correction through another render", arguments: WriteOrder.allCases)
    func queuedLayoutSupersedesOwedCorrection(_ writes: WriteOrder) {
        requireLayer(Scenario.run("an owed correction becomes a queued layout / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 0, appCount: 3)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.app, target = f.frame(b).origin
            app.drag(a, to: CGPoint(x: 610, y: 43)); s.settle()
            app.moveFromApplication(a, to: CGPoint(x: 630, y: 43))
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXEnhancedUserInterface \(app.alias) pid=\(app.pid)")), "A's correction is held before its write", s)
            app.hang(); s.settle()
            s.expect("the unanswered correction still owes the pointer drop", f.frame(a).minX == 630)

            f.apps[1].close(b)
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXPosition=\(target.x),\(target.y) window \(c) \(f.apps[2].alias)")), "C's layout write holds A's layout in the sweep", s)
            app.resume()
            f.tessel.press("focus right")
            expectPaused(f.mac.scheduler.run(), "another render supersedes the queued layout before A dispatches", s)
            s.settle()
            s.expect("the layout target wins over the already-owed pointer correction", f.frame(a).minX == 10)
            for x in [40.0, 60] {
                app.moveFromApplication(a, to: CGPoint(x: x, y: 43)); s.settle()
                s.expect("the successful layout readback reset the two-correction allowance", f.frame(a).minX == 10)
            }
            app.moveFromApplication(a, to: CGPoint(x: 80, y: 43)); s.settle()
            s.expect("the third app move after the layout is conceded", f.frame(a).minX == 80)
        })
    }

    @Test("#39 E11: finishing a layout placement after unanswered readback keeps its layout target", arguments: WriteOrder.allCases)
    func pendingLayoutKeepsItsTarget(_ writes: WriteOrder) {
        requireLayer(Scenario.run("an unfinished layout placement stays own / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 0, appCount: 3)
            let b = f.ids[1], c = f.ids[2], app = f.apps[2], original = f.frame(c), target = f.frame(b).origin
            app.moveFromApplication(c, to: CGPoint(x: original.minX + 30, y: original.minY)); s.settle()
            s.expect("C starts with one correction", f.frame(c) == original)
            f.apps[1].close(b)
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXPosition=\(target.x),\(target.y) window \(c) \(app.alias)")), "the layout's position write is held", s)
            f.mac.scheduler.resume()
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXPosition window \(c) \(app.alias)")), "the layout's readback is held after its write", s)
            app.hang(); s.settle()
            s.expect("the layout write took effect before the unanswered readback", f.frame(c).origin == target)
            app.resume(); app.moveFromApplication(c, to: target); s.settle()
            s.expect("finishing the pending layout keeps its new target", f.frame(c).origin == target)
            for x in [target.x + 30, target.x + 50] {
                app.moveFromApplication(c, to: CGPoint(x: x, y: target.y)); s.settle()
                s.expect("the completed own placement reset C's allowance", f.frame(c).origin == target)
            }
            let third = CGPoint(x: target.x + 70, y: target.y)
            app.moveFromApplication(c, to: third); s.settle()
            s.expect("the third subsequent app move is conceded", f.frame(c).origin == third)
        })
    }

    @Test("#39 E6: a pointer move waits through snapshots and focus until the next layout change", arguments: WriteOrder.allCases)
    func pointerMoveWaitsForLayout(_ writes: WriteOrder) {
        requireLayer(Scenario.run("a pointer drop waits for layout / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1]
            app.drag(b, to: Self.dropped); s.settle()
            // Another notification supplies the next snapshot after release.
            app.moveFromApplication(b, to: Self.dropped); s.settle()
            s.expect("the next snapshot preserves the pointer's drop", f.frame(b).origin == Self.dropped)
            f.press("focus right"); f.press("focus left")
            s.expect("focus without a layout change preserves the pointer's drop", f.frame(b).origin == Self.dropped)
            f.press("workspace 2"); f.press("workspace 1")
            s.expect("a layout change places the tile at its layout target", f.frame(b) == Self.target)
        })
    }

    @Test("#39 E7: an app move after a pointer drag returns to the drop point", arguments: WriteOrder.allCases)
    func appMoveReturnsToPointerDrop(_ writes: WriteOrder) {
        let result = Scenario.run("an app move after a pointer drop / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1]
            app.drag(b, to: Self.dropped); s.settle()
            s.expect("the pointer drop differs from the layout target", f.frame(b).origin == Self.dropped && Self.dropped != Self.target.origin)
            app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("the app move returns to the pointer's drop, not the layout", f.frame(b).origin == Self.dropped)
        }
        requireLayer(result)
    }

    @Test("#39 E8: two corrections concede the third move, including a cancelled correction retry", arguments: WriteOrder.allCases, [false, true])
    func twoCorrectionsThenConcede(_ writes: WriteOrder, _ cancel: Bool) {
        let result = Scenario.run("two corrections then concede / cancel \(cancel) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1], start = f.mac.scheduler.trace.count
            app.moveFromApplication(b, to: Self.moved)
            if cancel {
                // Cancel before AXPosition. The retry is dispatched by the
                // focus render before the old worker can report superseded.
                let held = f.mac.pause(after: .call("AccessibilityPort.copy AXEnhancedUserInterface \(app.alias) pid=\(app.pid)"))
                expectPaused(held, "the correction is held before its write", s)
                f.tessel.press("focus right")
                expectPaused(f.mac.scheduler.run(), "the retry waits behind the cancelled request", s)
            }
            s.settle()
            s.expect("the first move is corrected", f.frame(b) == Self.target)
            app.moveFromApplication(b, to: CGPoint(x: 1120, y: 43)); s.settle()
            s.expect("the second move is corrected", f.frame(b) == Self.target)
            let third = CGPoint(x: 1140, y: 43)
            app.moveFromApplication(b, to: third); s.settle()
            s.expect("the third move is conceded", f.frame(b).origin == third)
            let corrections = positionWrites(f, b, since: start)
            s.expect("exactly two AXPosition corrections, including the retry: \(corrections)", corrections == 2)
            f.press("workspace 2"); f.press("workspace 1")
            s.expect("layout places a conceded tile again", f.frame(b) == Self.target)
            let reset = f.mac.scheduler.trace.count
            app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("layout resets the correction allowance", f.frame(b) == Self.target && positionWrites(f, b, since: reset) == 1)
        }
        requireLayer(result)
    }

    @Test("#39 E9: an at-rest correction is one position write without stage or screenshots", arguments: WriteOrder.allCases)
    func atRestCorrectionIsInstant(_ writes: WriteOrder) {
        let result = Scenario.run("an instant correction with motion available / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 250, appCount: 2)
            let b = f.ids[1], start = f.mac.scheduler.trace.count
            let events = f.mac.stageEvents.count, screenshots = f.mac.stageCaptureRequests.count
            f.apps[1].moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("the app move is corrected", f.frame(b) == Self.target)
            s.expect("the correction neither shows nor clears a stage", f.mac.stageEvents.count == events)
            s.expect("stageScreenshots stays unchanged", f.mac.stageCaptureRequests.count == screenshots)
            let count = positionWrites(f, b, since: start)
            s.expect("the correction writes AXPosition once: \(count)", count == 1)
        }
        requireLayer(result)
    }

    @Test("#39 E10: a move during scroll retargets the stage without clearing it early", arguments: WriteOrder.allCases)
    func correctionRetargetsRunningStage(_ writes: WriteOrder) {
        let result = Scenario.run("an app move while scrolling / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 250, appCount: 2)
            let b = f.ids[1]
            f.press("focus right"); f.mac.clearMotionHistory()
            f.tessel.press("focus right")
            s.after(milliseconds: 150, "the app moves the already placed tile during motion") {
                s.expect("the stage is moving before the app move", f.mac.stageEvents.contains { if case .move = $0.kind { true } else { false } }
                         && !f.mac.stageEvents.contains { $0.kind == .clear })
                f.apps[1].moveFromApplication(b, to: CGPoint(x: 400, y: 43))
            }
            s.settle()
            let events = f.mac.stageEvents
            s.expect("the existing stage is retargeted", events.filter { if case .move = $0.kind { true } else { false } }.count >= 2)
            s.expect("one stage covers the whole change", events.filter { if case .show = $0.kind { true } else { false } }.count == 1)
            let settled = events.lastIndex { $0.kind == .settled }, cleared = events.firstIndex { $0.kind == .clear }
            s.expect("the stage clears only after its retarget settles", settled != nil && cleared != nil && settled! < cleared!)
            s.expect("the moved tile ends at the scrolled target", f.frame(b) == CGRect(x: 10, y: 43, width: 849, height: 1064))
        }
        requireLayer(result)
    }

    @Test("#39 E11: the latest in-flight placement owns its readback, even after a late cancelled completion", arguments: WriteOrder.allCases, [false, true])
    func inFlightPlacementOwnsReadback(_ writes: WriteOrder, _ cancel: Bool) {
        let result = Scenario.run("an app move during tessel's write / cancel \(cancel) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1], start = f.mac.scheduler.trace.count
            f.tessel.changeConfig("[animation]\nduration = 0\n[gaps]\nouter = 20\n")
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXPosition=874.0,53.0 window \(b) \(app.alias)")), "the layout position write is held", s)
            app.moveFromApplication(b, to: Self.moved)
            if cancel {
                f.tessel.press("focus right")
                expectPaused(f.mac.scheduler.run(), "the retry is dispatched while the old write is held", s)
                f.mac.scheduler.resume()
                expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXPosition=874.0,53.0 window \(b) \(app.alias)")), "the replacement write is held", s)
            }
            f.mac.scheduler.resume()
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXPosition window \(b) \(app.alias)")), "the latest placement's readback is held", s)
            // An app move between the write and readback is accepted as the
            // expected point, as the spec's explicit readback boundary says.
            app.moveFromApplication(b, to: Self.moved)
            s.settle()
            let count = positionWrites(f, b, since: start), budget = cancel ? 2 : 1
            s.expect("no correction is added to in-flight writes: \(count)", count == budget)
            s.expect("the accepted readback keeps the app's intervening move", f.frame(b).origin == Self.moved)
            let after = f.mac.scheduler.trace.count
            let next = CGPoint(x: 1150, y: 43)
            app.moveFromApplication(b, to: next); s.settle()
            s.expect("a later move returns to that accepted readback", f.frame(b).origin == Self.moved && positionWrites(f, b, since: after) == 1)
        }
        requireLayer(result)
    }

    @Test("#39 E12: own placements, snapback, fractional widths and menu clamping add no position writes", arguments: WriteOrder.allCases)
    func ownPlacementsKeepBaselineWriteBudget(_ writes: WriteOrder) {
        requireLayer(Scenario.run("own placements keep the 0c531ee budget / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, maximumFractions: [1: 848.5 / 1708], appCount: 2)
            let b = f.ids[1]
            f.apps[1].resizeFromApplication(b, to: Self.target.size); s.settle()
            s.expect("the fractional accepted width is within one point", f.frame(b).width == 848.5)
            let start = f.mac.scheduler.trace.count
            for command in ["focus right", "focus right", "focus left", "focus left", "workspace 2", "workspace 1"] { f.press(command) }
            let count = positionWrites(f, b, since: start)
            s.expect("B keeps the 0c531ee AXPosition budget (actual \(count))", count == 3)
        })
    }

    @Test("#39 E12: accepted native menu and parked-strip adjustments do not correct their own readbacks", arguments: WriteOrder.allCases, [false, true])
    func nativeAdjustmentsKeepBaselineWriteBudget(_ writes: WriteOrder, _ parked: Bool) {
        requireLayer(Scenario.run("native readback keeps the 0c531ee budget / parked \(parked) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1], start = f.mac.scheduler.trace.count
            f.tessel.changeConfig("[animation]\nduration = 0\n[gaps]\nouter = 20\n")
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXPosition=874.0,53.0 window \(b) \(app.alias)")), "the native-adjusted placement is held", s)
            // The display changes after the presenter chose its frame. Native
            // AX accepts the new menu edge and, in the parked arm, its strip.
            let width = parked ? 800.0 : 1728.0
            f.mac.setScreen(ScreenGeometry(frame: CGRect(x: 0, y: 0, width: width, height: 1117),
                                           visibleFrame: CGRect(x: 0, y: 0, width: width, height: 1054)))
            s.settle()
            s.expect("the placement readback includes menu-bar clamping", f.frame(b).minY == 63)
            if parked { s.expect("the parked readback includes the native 40-point strip", f.frame(b).minX == 760) }
            let count = positionWrites(f, b, since: start)
            s.expect("B keeps the native-adjustment 0c531ee AXPosition budget (actual \(count))", count == 1)
        })
    }

    @Test("#39 E13: a parked tile showing its strip waits for a redraw after an app move", arguments: WriteOrder.allCases)
    func parkedTileWaitsForRedraw(_ writes: WriteOrder) {
        requireLayer(Scenario.run("a parked strip's app move waits / \(writes)", writes: writes) { s in
            // A narrower B leaves C's strip on screen instead of closeting C.
            let f = CarouselFixture(s, presets: [0.5, 0.4, 0.5], duration: 0, appCount: 2)
            let c = f.ids[2], before = f.frame(c), start = f.mac.scheduler.trace.count
            s.expect("C shows a parked strip with an off-screen target", f.mac.isVisible(c) && !f.mac.isInCloset(c) && before.minX < 1728 && before.maxX > 1728)
            let point = CGPoint(x: before.minX - 40, y: before.minY)
            f.app.moveFromApplication(c, to: point); s.settle()
            s.expect("a parked app move waits without a position write", f.frame(c).origin == point && positionWrites(f, c, since: start) == 0)
            f.press("focus right"); f.press("focus right")
            s.expect("the next redraw places C completely on screen", f.mac.isFullyOnScreen(c) && f.frame(c).origin != point)
        })
    }

    @Test("#39 E14: native replacement inherits a correction's point, count and unfinished intent", arguments: WriteOrder.allCases, [false, true])
    func nativeTabInheritsCorrection(_ writes: WriteOrder, _ inFlight: Bool) {
        let result = Scenario.run("native replacement during correction / in-flight \(inFlight) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1]
            let tab = app.open(WindowSpec(frame: f.frame(b), positionAcceptance: .screenEdges), background: true)
            app.groupTabs([b, tab], selected: b); s.settle()
            f.select(f.ids[0])
            app.drag(b, to: Self.dropped); s.settle()
            app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("B has one correction back to the pointer's point", f.frame(b).origin == Self.dropped)
            if inFlight {
                app.moveFromApplication(b, to: CGPoint(x: 1120, y: 43))
                expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXEnhancedUserInterface \(app.alias) pid=\(app.pid)")), "the old tab's correction is held", s)
            }
            app.selectTabInBackground(tab); s.settle()
            s.expect("the replacement keeps the pointer's expected point", f.frame(tab).origin == Self.dropped)
            s.expect("the native group replaces B in policy", f.tessel.windows.contains { $0.id == tab } && !f.tessel.windows.contains { $0.id == b })
            if !inFlight {
                app.moveFromApplication(tab, to: CGPoint(x: 1120, y: 43)); s.settle()
                s.expect("the replacement uses the second correction", f.frame(tab).origin == Self.dropped)
            }
            let conceded = CGPoint(x: 1140, y: 43)
            app.moveFromApplication(tab, to: conceded); s.settle()
            s.expect("replacement preserves the count and concedes the third move", f.frame(tab).origin == conceded)
        }
        requireLayer(result)
    }

    @Test("#39 E14: native replacement drops an old correction dispatched behind its captured snapshot", arguments: WriteOrder.allCases)
    func nativeReplacementDropsOldCorrection(_ writes: WriteOrder) {
        requireLayer(Scenario.run("native replacement overtakes an old correction / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], app = f.apps[1]
            let tab = app.open(WindowSpec(frame: f.frame(b), positionAcceptance: .screenEdges), background: true)
            app.groupTabs([b, tab], selected: b); s.settle(); f.select(a)
            app.drag(b, to: Self.dropped); s.settle()
            app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("B uses its first correction", f.frame(b).origin == Self.dropped)
            // A's resize keeps the sweep ahead of B busy. B moves left of its
            // expected point, so A precedes its rightward correction.
            f.app.delayAXReplies(milliseconds: 50)
            f.app.resizeFromApplication(a, to: CGSize(width: 900, height: f.area.height))
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.set AXSize=849.0x1064.0 window \(a) \(f.app.alias)")), "A's resize write is held", s)
            app.moveFromApplication(b, to: CGPoint(x: 700, y: 43))
            expectPaused(f.mac.deliver(app), "B's second move is delivered while A finishes", s)
            app.selectTabInBackground(tab)
            expectPaused(f.mac.pause(after: .read(app)), "the replacement snapshot is captured", s)
            // Keep B's lane held while A completes and the presenter dispatches
            // the old ID's correction behind that captured replacement.
            expectPaused(f.mac.scheduler.run(), "A finishes while the replacement snapshot stays held", s)
            s.expect("the replacement is still away before its snapshot reaches policy", f.frame(tab).minX == 700)
            s.settle()
            s.expect("the replacement completes the owed correction at the pointer point", f.frame(tab).origin == Self.dropped)
            let third = CGPoint(x: 1140, y: 43)
            app.moveFromApplication(tab, to: third); s.settle()
            s.expect("the old correction's late completion did not reset the count", f.frame(tab).origin == third)
        })
    }

    @Test("#39 E15: pointer-held and release reconciliation snapshots never trigger a correction", arguments: WriteOrder.allCases)
    func pointerSnapshotsNeverCorrect(_ writes: WriteOrder) {
        requireLayer(Scenario.run("pointer snapshots own geometry / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1], start = f.mac.scheduler.trace.count
            f.mac.pointerDown()
            app.moveFromApplication(b, to: Self.moved); s.settle()
            s.expect("a held-pointer snapshot leaves the tile alone", f.frame(b).origin == Self.moved && positionWrites(f, b, since: start) == 0)
            f.mac.pointerUp()
            expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(app.alias) pid=\(app.pid)")), "the release read is held", s)
            let released = CGPoint(x: 1130, y: 53)
            app.moveFromApplication(b, to: released)
            s.settle()
            s.expect("release reconciliation keeps the final point without a correction", f.frame(b).origin == released && positionWrites(f, b, since: start) == 0)
            // A failed release retains this tile's pointerFrames guard after
            // the global pointer reconciliation has completed.
            f.mac.pointerDown(); app.hang(); f.mac.pointerUp(); s.settle()
            app.resume(); app.moveFromApplication(b, to: Self.dropped); s.settle()
            s.expect("an unresolved tile's release snapshot is also left alone", f.frame(b).origin == Self.dropped && positionWrites(f, b, since: start) == 0)
            f.press("focus right"); f.press("focus left")
            s.expect("gesture snapshots leave no correction pending for a later focus render", f.frame(b).origin == Self.dropped && positionWrites(f, b, since: start) == 0)
        })
    }

    private func positionWrites(_ f: CarouselFixture, _ id: UInt32, since start: Int) -> Int {
        f.mac.scheduler.trace.dropFirst(start).filter { $0.contains("AccessibilityPort.set AXPosition=") && $0.contains(" window \(id) ") }.count
    }

    private func expectPaused(_ outcome: RunOutcome, _ message: String, _ s: Scenario) {
        if case .paused = outcome {} else { s.expect("\(message): \(outcome)", false) }
    }
}

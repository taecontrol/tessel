import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerAppMoveAcceptance {
    private static let target = CGRect(x: 869, y: 43, width: 849, height: 1064)
    private static let moved = CGPoint(x: 1100, y: 43)
    private static let dropped = CGPoint(x: 820, y: 43)

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
        withKnownIssue("#39 E7: app moves need expected-position correction") { requireLayer(result) }
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
                expectPaused(f.mac.deliver(app), "the move snapshot dispatches the correction", s)
                let held = f.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(app.alias) pid=\(app.pid)"))
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
        withKnownIssue("#39 E8: app moves need expected-position correction") { requireLayer(result) }
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
        withKnownIssue("#39 E9: app moves need expected-position correction") { requireLayer(result) }
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
        withKnownIssue("#39 E10: app moves need expected-position correction") { requireLayer(result) }
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
        withKnownIssue("#39 E11: app moves need expected-position correction") { requireLayer(result) }
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
                expectPaused(f.mac.deliver(app), "the second move dispatches the old tab's correction", s)
                expectPaused(f.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(app.alias) pid=\(app.pid)")), "the old tab's correction is held", s)
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
        withKnownIssue("#39 E14: app moves need expected-position correction") { requireLayer(result) }
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
        })
    }

    private func positionWrites(_ f: CarouselFixture, _ id: UInt32, since start: Int) -> Int {
        f.mac.scheduler.trace.dropFirst(start).filter { $0.contains("AccessibilityPort.set AXPosition=") && $0.contains(" window \(id) ") }.count
    }

    private func expectPaused(_ outcome: RunOutcome, _ message: String, _ s: Scenario) {
        if case .paused = outcome {} else { s.expect("\(message): \(outcome)", false) }
    }
}

import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerReadinessRegression {
    @Test("#19 E7: a float hides after a hung tile's failed placement leaves it exactly in place", arguments: WriteOrder.allCases)
    func floatHidesAfterHungTilesFailedPlacementLeavesItExactlyInPlace(_ writes: WriteOrder) {
        let result = Scenario.run("layer exit after an exactly placed tile exhausts its retries / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            let target = CGRect(x: 869, y: 43, width: 849, height: 1064)
            let floatFrame = CGRect(x: 1000, y: 100, width: 200, height: 200)
            let float = f.app.open(WindowSpec(frame: floatFrame, subrole: "AXDialog"))
            s.settle()
            f.select(a)
            f.press("toggle layer")
            s.expect("the shown float overlaps an exactly placed tile", f.frame(b) == target && target.intersects(floatFrame)
                     && f.tessel.status.layer?.state == "shown" && f.mac.focusedWindow == float && f.mac.isVisible(float))
            s.expect("the closing tile is parked", f.mac.isInCloset(c) && !f.mac.isVisible(c))
            f.apps[1].hang()
            // Removing the parked tile changes the layout dictionary, so B
            // receives a position request despite already being at its target.
            f.app.close(c, selecting: float)
            s.settle()
            let placementStart = f.mac.scheduler.trace.count
            f.press("toggle layer")
            let attempts = f.mac.scheduler.trace.dropFirst(placementStart).filter {
                $0.contains("AccessibilityPort.copy AXHidden reply \(f.apps[1].alias) pid=\(f.apps[1].pid) cannotComplete")
            }
            s.expect("the hung tile exhausts its initial placement and four retries", attempts.count == 5)
            s.expect("the failed placement leaves the tile exactly at its target", f.frame(b) == target)
            s.expect("layer exit returns focus to the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            let publicationStart = f.tessel.windowPublications.count
            f.apps[1].resume()
            f.apps[1].resizeFromApplication(b, to: target.size)
            s.settle()
            s.expect("native geometry recovery publishes a fresh tile snapshot", f.tessel.windowPublications.dropFirst(publicationStart).contains {
                $0.pid == f.apps[1].pid && $0.windows?.contains { $0.id == b } == true
            })
            s.expect("the recovered tile remains exactly at its target", f.frame(b) == target)
            s.expect("the hidden layer's float leaves the desktop after the redundant placement fails", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7; #39 E5; #40 E4: a layer exit places back a tile its app moved away, then hides the float over it", arguments: WriteOrder.allCases, [8, 20])
    func layerExitPlacesBackATileItsAppMoved(_ writes: WriteOrder, _ commit: Int) {
        let result = Scenario.run("layer exit over a tile whose app move was read / \(writes), commit \(commit)ms", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1]
            let target = CGRect(x: 869, y: 43, width: 849, height: 1064), point = CGPoint(x: 1000, y: 100)
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
            s.settle()
            f.select(a)
            f.press("toggle layer")
            s.expect("the shown float overlaps tile B at its target", f.frame(b) == target && f.tessel.status.layer?.state == "shown" && f.mac.isVisible(float))
            f.apps[1].moveFromApplication(b, to: CGPoint(x: 1100, y: 43))
            s.settle()
            s.expect("the app's move is read and the tile returns at rest", f.frame(b) == target)
            // #19 E7 and #40 E4 need the tile away from its target when the
            // layer exits: the app insists until tessel concedes (#39 E8).
            for _ in 0..<2 { f.apps[1].moveFromApplication(b, to: CGPoint(x: 1100, y: 43)); s.settle() }
            s.expect("after two corrections the tile stays where its app put it", f.frame(b).minX == 1100 && !f.frame(b).contains(point))
            f.apps[1].delayCommits(milliseconds: commit)
            f.mac.beginPresentationTrace()
            f.press("toggle layer")
            let exposed = f.mac.presentationStates.filter { state in !state.frames.values.contains { $0.contains(point) } }
            s.expect("no presentation state exposes desktop at the float: \(exposed.map(\.operation))", exposed.isEmpty)
            s.expect("leaving the layer returns focus to the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the exit places the tile back at its target", f.frame(b) == target)
            s.expect("the float leaves the desktop once the tile covers it", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7: a tile withdrawn during its layer exit placement does not count as in place", arguments: WriteOrder.allCases, ["minimize", "close", "hide"])
    func withdrawnDuringPlacementKeepsFloatUntilSuccessor(_ writes: WriteOrder, _ withdrawal: String) {
        let result = Scenario.run("a tile is withdrawn before its placement reads it / \(withdrawal) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5, 0.5, 0.5, 0.5], duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[1]
            // Hiding B's app also hides D, so the next tile from A's app follows.
            let next = withdrawal == "hide" ? f.ids[4] : f.ids[3]
            let target = CGRect(x: 869, y: 43, width: 849, height: 1064), point = CGPoint(x: 1000, y: 100)
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
            s.settle()
            f.select(a)
            f.press("toggle layer")
            s.expect("the shown float overlaps tile B at its target", f.frame(b) == target && f.tessel.status.layer?.state == "shown" && f.mac.isVisible(float))
            // A same-size resize starts a snapshot read of B's app, held after
            // it read B as tiled at its target.
            app.resizeFromApplication(b, to: target.size)
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(b) \(app.alias)"))
            if case .paused = held {} else { s.expect("B's snapshot read is held: \(held)", false) }
            // Removing the parked tile changes the layout dictionary, so B
            // receives a position request that waits behind the held read and
            // stays pending into the exit.
            f.app.close(c, selecting: float)
            let closed = f.mac.scheduler.run()
            if case .paused = closed {} else { s.expect("B's lane stays held through the relayout: \(closed)", false) }
            s.step("toggle layer") { f.tessel.press("toggle layer") }
            let exit = f.mac.scheduler.run()
            if case .paused = exit {} else { s.expect("B's lane stays held through the exit: \(exit)", false) }
            s.expect("the float covers B's target while B's placement waits", f.mac.isVisible(float) && f.frame(float).contains(point))
            // B is withdrawn before its placement asks whether it can be
            // presented. That placement knows it, unlike a hung app's; a hide
            // cancels it before it starts.
            f.mac.beginPresentationTrace()
            switch withdrawal {
            case "minimize": app.minimize(b)
            case "close": app.close(b)
            default: app.hide()
            }
            s.settle()
            let exposed = f.mac.presentationStates.filter { state in !state.frames.values.contains { $0.contains(point) } }
            s.expect("no presentation state exposes desktop at the float: \(exposed.map(\.operation))", exposed.isEmpty)
            s.expect("leaving the layer returns focus to the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the withdrawal renders the next layout, whose tile covers the point", f.mac.isVisible(next) && f.frame(next).contains(point))
            s.expect("the float leaves the desktop once the next tile covers it", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7: a hide that cancels a layer exit placement during its readback does not count as in place", arguments: WriteOrder.allCases)
    func hideDuringPlacementReadbackKeepsFloatUntilSuccessor(_ writes: WriteOrder) {
        let result = Scenario.run("an app hide cancels a tile's placement during its readback / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5, 0.5, 0.5, 0.5], duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], next = f.ids[4], app = f.apps[1]
            let target = CGRect(x: 869, y: 43, width: 849, height: 1064), point = CGPoint(x: 1000, y: 100)
            let float = f.app.open(WindowSpec(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), subrole: "AXDialog"))
            s.settle()
            f.select(a)
            f.press("toggle layer")
            s.expect("the shown float overlaps tile B at its target", f.frame(b) == target && f.tessel.status.layer?.state == "shown" && f.mac.isVisible(float))
            // B's snapshot read is held so that its position request stays
            // pending into the exit, as in the withdrawal regression above.
            app.resizeFromApplication(b, to: target.size)
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(b) \(app.alias)"))
            if case .paused = held {} else { s.expect("B's snapshot read is held: \(held)", false) }
            f.app.close(c, selecting: float)
            let closed = f.mac.scheduler.run()
            if case .paused = closed {} else { s.expect("B's lane stays held through the relayout: \(closed)", false) }
            s.step("toggle layer") { f.tessel.press("toggle layer") }
            let exit = f.mac.scheduler.run()
            if case .paused = exit {} else { s.expect("B's lane stays held through the exit: \(exit)", false) }
            s.expect("the float covers B's target while B's placement waits", f.mac.isVisible(float) && f.frame(float).contains(point))
            // B's placement wrote its target and is reading it back when the
            // hide arrives. Tessel processes the hide, which cancels the
            // placement, before the readback answers.
            f.mac.scheduler.resume()
            let readback = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(b) \(app.alias)"))
            if case .paused = readback {} else { s.expect("B's placement readback is held: \(readback)", false) }
            f.mac.beginPresentationTrace()
            app.hide()
            let hidden = f.mac.scheduler.run()
            if case .paused = hidden {} else { s.expect("the hide is delivered while the readback is held: \(hidden)", false) }
            s.settle()
            let exposed = f.mac.presentationStates.filter { state in !state.frames.values.contains { $0.contains(point) } }
            s.expect("no presentation state exposes desktop at the float: \(exposed.map(\.operation))", exposed.isEmpty)
            s.expect("leaving the layer returns focus to the remembered tile", f.tessel.status.layer?.state == "hidden" && f.mac.focusedWindow == a)
            s.expect("the hide renders the next layout, whose tile covers the point", f.mac.isVisible(next) && f.frame(next).contains(point))
            s.expect("the float leaves the desktop once the next tile covers it", f.mac.isInCloset(float) && !f.mac.isVisible(float))
        }
        requireLayer(result)
    }

    @Test("#19 E7: a placement cancelled during its readback reports superseded, without a frame", arguments: WriteOrder.allCases)
    func placementCancelledDuringReadbackIsSuperseded(_ writes: WriteOrder) {
        requireLayer(Scenario.run("an app hide cancels a placement during its readback / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1], answer = PlacementAnswer()
            f.tessel.catalog.presentRail(pid: app.pid, id: b, frame: f.frame(b), position: true, resize: false, focus: false,
                                         screenRight: f.mac.screens.primaryScreen!.frame.maxX) { answer.result = $0 }
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(b) \(app.alias)"))
            if case .paused = held {} else { s.expect("the placement readback is held: \(held)", false) }
            app.hide()
            let hidden = f.mac.scheduler.run()
            if case .paused = hidden {} else { s.expect("the hide is delivered while the readback is held: \(hidden)", false) }
            s.settle()
            s.expect("the cancelled placement reports superseded: \(String(describing: answer.result?.outcome))", answer.result?.outcome == .superseded)
            s.expect("the cancelled placement carries no frame: \(String(describing: answer.result?.frame))", answer.result != nil && answer.result?.frame == nil)
        })
    }

    @Test("#19 E7: a placement cancelled during its last unanswered attempt reports superseded, not unanswered", arguments: WriteOrder.allCases)
    func placementCancelledDuringLastAttemptIsSuperseded(_ writes: WriteOrder) {
        requireLayer(Scenario.run("an app hide cancels a hung app's last placement attempt / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let b = f.ids[1], app = f.apps[1], answer = PlacementAnswer()
            app.hang()
            f.tessel.catalog.presentRail(pid: app.pid, id: b, frame: f.frame(b), position: true, resize: false, focus: false,
                                         screenRight: f.mac.screens.primaryScreen!.frame.maxX) { answer.result = $0 }
            // The initial attempt and four retries each time out on their
            // first presentability read. The hide arrives during the last.
            for attempt in 0..<5 {
                if attempt > 0 { f.mac.scheduler.resume() }
                let held = f.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(app.alias) pid=\(app.pid)"))
                if case .paused = held {} else { s.expect("attempt \(attempt) is held: \(held)", false) }
            }
            app.hide()
            let hidden = f.mac.scheduler.run()
            if case .paused = hidden {} else { s.expect("the hide is delivered during the last attempt: \(hidden)", false) }
            s.settle()
            s.expect("the cancelled attempt reports superseded: \(String(describing: answer.result?.outcome))", answer.result?.outcome == .superseded)
        })
    }

    @Test("#19 E7: a focus request that reads its window minimized reports withdrawn",
          arguments: WriteOrder.allCases, ["presentability check", "activation"])
    func focusRequestThatReadsMinimizedIsWithdrawn(_ writes: WriteOrder, _ check: String) {
        requireLayer(Scenario.run("a window is minimized before a focus request's \(check) reads it / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0)
            let b = f.ids[1], answer = PlacementAnswer()
            f.tessel.catalog.presentRail(pid: f.app.pid, id: b, frame: nil, position: false, resize: false, focus: true,
                                         screenRight: f.mac.screens.primaryScreen!.frame.maxX) { answer.result = $0 }
            // The first presentability check reads B as presentable. Either the
            // second check, before the focus request, or the activation's own
            // check, after it made B main, then reads it minimized. Nothing
            // cancels the request.
            let point = check == "activation" ? "AccessibilityPort.set AXMain=true window \(b) \(f.app.alias)"
                : "AccessibilityPort.copy AXFullScreen window \(b) \(f.app.alias)"
            let held = f.mac.pause(after: .call(point))
            if case .paused = held {} else { s.expect("the request is held before its \(check) reads B: \(held)", false) }
            f.app.minimize(b)
            s.settle()
            s.expect("the request reports withdrawn: \(String(describing: answer.result?.outcome))", answer.result?.outcome == .withdrawn)
        })
    }

    @Test("#19 E7: an accepted tile frame within one point does not block hiding the layer", arguments: WriteOrder.allCases)
    func acceptedSubpointTileFrameDoesNotBlockLayerExit(_ writes: WriteOrder) {
        requireLayer(Scenario.run("layer exit over an already accepted subpoint tile frame / \(writes)", writes: writes) { s in
            let mac = s.mac, app = mac.launch(), area = WorkspaceScenarios.area(mac)
            let width = (area.width + 10) / 2 - 10
            // The existing size-constraint contract supplies an accepted frame
            // half a point wider than the preset. No pixel-rounding behavior
            // is added to the simulator to reproduce the readiness mismatch.
            let acceptedWidth = width + 0.5
            let tile = app.open(WindowSpec(frame: CGRect(origin: area.origin, size: CGSize(width: acceptedWidth, height: area.height)),
                                           minimumSize: CGSize(width: acceptedWidth, height: 1)))
            let float = app.open(WindowSpec(frame: CGRect(x: 30, y: 80, width: 200, height: 200), subrole: "AXDialog"), background: true)
            app.select(tile)
            let tessel = s.startTessel(text: "[animation]\nduration = 0\n")
            s.settle()
            s.expect("the tile has its accepted size within the existing tolerance", mac.frame(tile)?.width == acceptedWidth && acceptedWidth - width <= 1)
            s.expect("the initial float is hidden", mac.isInCloset(float) && !mac.isVisible(float))
            tessel.press("toggle layer"); s.settle()
            s.expect("entry shows and focuses the float", tessel.status.layer?.state == "shown" && mac.focusedWindow == float && mac.isVisible(float))
            tessel.press("toggle layer"); s.settle()
            s.expect("exit returns to the remembered tile", tessel.status.layer?.state == "hidden" && mac.focusedWindow == tile)
            s.expect("the layer hides over an unchanged, accepted tile frame", mac.isInCloset(float) && !mac.isVisible(float))
        })
    }
}

@MainActor private final class PlacementAnswer { var result: RailPresentationResult? }

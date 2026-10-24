import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FailedHandoff {
    @Test("#41 E1: an exhausted workspace replacement keeps its old cover", arguments: WriteOrder.allCases)
    func workspaceReplacement(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 workspace replacement / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            prepareWorkspace(f)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.apps[1].hang()
            let start = f.mac.scheduler.trace.count
            f.press("workspace 2")
            s.expect("the replacement exhausts its initial attempt and four retries", hiddenTimeouts(f, app: f.apps[1], since: start) == 5)
            s.expect("the responsive destination is visible", f.mac.isVisible(c))
            s.expect("the failed destination stays in the closet", f.mac.isInCloset(b))
            s.expect("the outgoing tile still covers the failed destination's half", f.mac.isVisible(a) && !f.frame(a).intersects(f.frame(c)))
            enabledWithoutDesktopActivation(f, since: start)
        })
    }

    @Test("#41 E2: a dependent placement never vacates coverage after its predecessor fails", arguments: WriteOrder.allCases)
    func dependentPlacement(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 dependent placement / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            prepareDependency(f)
            let before = f.snapshot(), b = f.ids[1], c = f.ids[2]
            f.apps[0].hang(); f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            f.press("focus right")
            s.expect("the predecessor exhausts its initial attempt and four retries", hiddenTimeouts(f, app: f.apps[0], since: start) == 5)
            s.expect("the dependent tile receives no geometry write", f.mac.geometryWrites.allSatisfy { $0.window != b })
            f.unchanged(before)
            s.expect("the old pair remains visible and keeps native focus", f.mac.isVisible(f.ids[0]) && f.mac.isVisible(b) && f.mac.isInCloset(c) && f.mac.focusedWindow == b)
        })
    }

    @Test("#41 E3: an exhausted focus request keeps both rails and native focus", arguments: WriteOrder.allCases)
    func exhaustedFocus(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 exhausted focus / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0)
            prepareRail(f)
            exhaustFocus(f)
            s.expect("the model is on rail 2 while both rails stay visible", f.tessel.status.rail == 2 && f.ids.allSatisfy(f.mac.isVisible))
            s.expect("native focus stays on the outgoing rail", f.mac.focusedWindow == f.ids[0])
        })
    }

    @Test("#41 E3a: a click completes the failed focus handoff without replaying presentation", arguments: WriteOrder.allCases, [false, true])
    func clickCompletesFocus(_ writes: WriteOrder, _ independentFailure: Bool) {
        requireCarousel(Scenario.run("#41 click after exhausted focus / independent failure \(independentFailure) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: independentFailure ? 2 : 1)
            if independentFailure {
                let launcher = f.mac.launch()
                let panel = launcher.open(WindowSpec(subrole: "AXSystemDialog", cgLayer: 8), background: true)
                s.settle()
                let activation = "ApplicationEvent.activated \(launcher.alias) pid=\(launcher.pid)"
                let controlStart = f.mac.scheduler.trace.count
                launcher.select(panel); s.settle()
                let control = f.mac.scheduler.trace.dropFirst(controlStart).filter { $0.contains(activation) }.count
                s.expect("the control delivers native activation", control > 0)
                f.select(f.ids[0]); prepareWorkspace(f)
                f.apps[1].hang()
                exhaustFocus(f, command: "workspace 2")
                f.app.select(f.ids[2]); s.settle()
                s.expect("the click completes focus while keeping the unsafe cover", f.mac.focusedWindow == f.ids[2] && f.mac.isVisible(f.ids[0]) && f.mac.isInCloset(f.ids[1]))
                let start = f.mac.scheduler.trace.count
                launcher.select(panel); s.settle()
                let delivered = f.mac.scheduler.trace.dropFirst(start).filter { $0.contains(activation) }.count
                s.expect("completed focus retires its observer even while geometry remains failed", delivered == control)
                return
            }
            prepareRail(f); exhaustFocus(f)
            let c = f.ids[2], start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.app.select(c); s.settle()
            s.expect("the click focuses the destination and retires the outgoing rail", f.mac.focusedWindow == c && f.mac.visibleOrder == [c])
            s.expect("the old rails enter the closet", f.ids.prefix(2).allSatisfy(f.mac.isInCloset))
            s.expect("the late focus observation needs no new geometry, focus write or stage", LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start))).isEmpty && f.mac.stageEvents.isEmpty)
        })
    }

    @Test("#41 E3b: an unmanaged activation completes the failed focus handoff", arguments: WriteOrder.allCases)
    func externalActivationCompletesFocus(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 activation after exhausted focus / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0)
            let launcher = f.mac.launch()
            let panel = launcher.open(WindowSpec(subrole: "AXSystemDialog", cgLayer: 8), background: true)
            s.settle()
            prepareRail(f); exhaustFocus(f)
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            launcher.select(panel); s.settle()
            s.expect("the unmanaged app keeps keyboard focus", f.mac.focusedWindow == panel && f.mac.frontmostApp == launcher.pid)
            s.expect("the outgoing rail hides while the destination stays visible", f.ids.prefix(2).allSatisfy(f.mac.isInCloset) && f.mac.isVisible(f.ids[2]))
            s.expect("the activation needs no new geometry, focus write or stage", LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start))).isEmpty && f.mac.stageEvents.isEmpty)
        })
    }

    @Test("#41 E4: failed dependency and focus handoffs let the animated stage expire", arguments: WriteOrder.allCases, ["dependency", "focus"])
    func failedUnderStage(_ writes: WriteOrder, _ failure: String) {
        requireCarousel(Scenario.run("#41 animated \(failure) failure / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 250, appCount: failure == "dependency" ? 2 : 1)
            if failure == "dependency" { prepareDependency(f) } else { prepareRail(f) }
            let before = f.snapshot(), b = f.ids[1]
            f.mac.clearMotionHistory()
            if failure == "dependency" {
                f.apps[0].hang(); f.press("focus right")
                s.expect("the dependent tile is never written under the stage", f.mac.geometryWrites.allSatisfy { $0.window != b })
                s.expect("the incoming tile stays in the closet", f.mac.isInCloset(f.ids[2]))
            } else {
                // The early animated focus attempt times out before activation;
                // placement supersedes it and carries focus under the stage.
                f.app.busy(forMilliseconds: 100)
                exhaustFocus(f)
                s.expect("both real rails remain visible after the failed focus", f.ids.allSatisfy(f.mac.isVisible))
            }
            for id in f.ids.prefix(2) { s.expect("the real outgoing tile keeps its old frame", f.mac.frame(id) == before[id]) }
            let settled = f.mac.stageEvents.first { $0.kind == .settled }?.at
            let cleared = f.mac.stageEvents.last { $0.kind == .clear }?.at
            s.expect("the stage ran and cleared at its 300 ms linger", settled != nil && cleared == settled.map { $0 + 300 })
            s.expect("a failed handoff never reveals success through the stage", !f.mac.stageEvents.contains { $0.kind == .revealed })
            s.expect("management stays enabled after the stage expires", f.tessel.status.enabled)
        })
    }

    @Test("#41 E5: exhausted float focus releases restacking for the next frontmost app", arguments: WriteOrder.allCases)
    func failedFocusReleasesRestacking(_ writes: WriteOrder) {
        requireLayer(Scenario.run("#41 restack after exhausted float focus / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            let launcher = f.mac.launch()
            let panel = launcher.open(WindowSpec(subrole: "AXSystemDialog", cgLayer: 8), background: true)
            s.settle()
            f.press("toggle layer")
            f.tessel.press("focus right")
            let app = f.apps[1]
            // Fail the focus-only read before issuing activation. A timed-out
            // activation write has a separate catalog hold on passive raises.
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXFrontmost \(app.alias) pid=\(app.pid)"))
            if case .paused = held {} else { s.expect("the destination's frontmost read is held: \(held)", false) }
            app.hang(); s.settle()
            app.resume(); s.settle()
            let start = f.mac.scheduler.trace.count
            launcher.select(panel); s.settle()
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("idle restacking raises all visible floats in MRU order: \(raised)", raised == [f.floats[2], f.floats[0], f.floats[1]])
            s.expect("background raises preserve unmanaged keyboard focus", f.mac.focusedWindow == panel)
        })
    }

    @Test("#41 E6: the next key retries the failed workspace replacement", arguments: WriteOrder.allCases)
    func nextKeyRetries(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 next key after failed replacement / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            prepareWorkspace(f)
            f.apps[1].hang(); f.press("workspace 2")
            f.apps[1].resume(); s.settle()
            s.expect("resuming without an event leaves the cover and failed destination alone", f.mac.isVisible(f.ids[0]) && f.mac.isInCloset(f.ids[1]))
            f.mac.clearMotionHistory()
            f.press("focus left")
            f.pair(f.ids[1], f.ids[2], focused: f.ids[1])
            s.expect("the next render retries the failed destination", f.mac.geometryWrites.contains { $0.window == f.ids[1] })
            s.expect("the old cover retires once its replacement is ready", f.mac.isInCloset(f.ids[0]))
        })
    }

    @Test("#41 E7: a held pointer pauses the handoff until release", arguments: WriteOrder.allCases)
    func pointerPausesHandoff(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 pointer pauses handoff / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.select(b)
            let before = f.frame(b)
            f.mac.clearMotionHistory(); f.mac.pointerDown()
            f.app.close(a, selecting: b); s.settle()
            s.expect("the surviving tile keeps its coverage while the replacement is paused", f.mac.isVisible(b) && f.frame(b) == before && f.mac.isInCloset(c))
            s.expect("paused placement issues no geometry or visibility changes", f.mac.geometryWrites.isEmpty && f.mac.visibilityChanges.isEmpty)
            f.mac.pointerUp(); s.settle()
            f.pair(b, c, focused: b)
        })
    }

    @Test("#41 E7: a failed placement waits for independent active and startable placements before releasing restacking",
          arguments: WriteOrder.allCases, ["active", "pending"])
    func placementWorkKeepsRestackingHeld(_ writes: WriteOrder, _ remaining: String) {
        requireLayer(Scenario.run("#41 wait for \(remaining) placement / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("toggle layer")
            let background = f.floats[2]
            f.apps[0].hang()
            if remaining == "active" { f.apps[1].delayAXReplies(milliseconds: 500) }
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.tessel.changeConfig(LayerFixture.config + "[animation]\nduration = 0\n[gaps]\nouter = 20\n")
            s.after(milliseconds: remaining == "active" ? 4_000 : 2_000, "a placement still owns the handoff") {
                let attempts = hiddenTimeouts(in: f.mac, app: f.apps[0], since: start)
                s.expect("one independent placement has exhausted before observing restacking", attempts >= 5)
                if remaining == "pending" {
                    s.expect("the second same-app placement has started but has not exhausted", attempts < 10)
                } else {
                    s.expect("both same-app placements have exhausted while the other app is delayed", attempts == 10)
                }
                s.expect("background floats wait for all placement requests to finish", !f.raises(since: start).contains(background))
                if remaining == "active" { f.apps[1].delayAXReplies(milliseconds: 0) }
            }
            s.settle()
            s.expect("both failed placements exhaust their own retries", hiddenTimeouts(in: f.mac, app: f.apps[0], since: start) == 10)
            s.expect("the responsive background float restacks after the remaining work finishes", f.raises(since: start).contains(background))
            s.expect("restacking preserves the selected float", f.mac.focusedWindow == f.floats[0])
        })
    }

    @Test("#41 E7: confirmed native selection still waits for an outstanding focus retry", arguments: WriteOrder.allCases)
    func outstandingFocusKeepsRestackingHeld(_ writes: WriteOrder) {
        requireLayer(Scenario.run("#41 wait for outstanding focus / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            // Leave only one independent placement owned by the app that hangs.
            f.press("focus right"); f.press("send 2"); f.press("workspace 1")
            f.press("toggle layer")
            let app = f.apps[1], target = f.floats[1], background = f.floats[2]
            f.apps[0].hang()
            let start = f.mac.scheduler.trace.count
            f.tessel.changeConfig(LayerFixture.config + "[animation]\nduration = 0\n[gaps]\nouter = 20\n")
            s.after(milliseconds: 40, "request the other float while geometry is pending") { f.tessel.press("focus right") }
            var held = f.mac.pause(after: .call("AccessibilityPort.set AXMain=true window \(target) \(app.alias)"))
            if case .paused = held {} else { s.expect("the focus write is held: \(held)", false) }
            // Delay only this accepted write. Its native selection changes now;
            // a timeout in the following check leaves the focus request retrying.
            app.delayAXReplies(milliseconds: 1_500)
            f.mac.scheduler.resume()
            held = f.mac.pause(after: .call("AccessibilityPort.copy AXMinimized window \(target) \(app.alias)"))
            if case .paused = held {} else { s.expect("the focus readback is held: \(held)", false) }
            s.expect("native selection changed before the readback timeout", f.mac.focusedWindow == target)
            app.delayAXReplies(milliseconds: 0); app.busy(forMilliseconds: 1)
            held = f.mac.deliver(app)
            if case .paused = held {} else { s.expect("a notification confirms focus during retry backoff: \(held)", false) }
            s.expect("the focus request encountered a transient timeout after selecting its target", f.mac.scheduler.trace.dropFirst(start).contains {
                $0.contains("AccessibilityPort.copy AXMinimized reply window \(target) \(app.alias) cannotComplete")
            })
            app.delayAXReplies(milliseconds: 100)
            s.after(milliseconds: 500, "independent geometry exhausts while focus is still outstanding") {
                s.expect("the independent placement has exhausted", hiddenTimeouts(in: f.mac, app: f.apps[0], since: start) >= 5)
                s.expect("native selection remains confirmed", f.mac.focusedWindow == target)
                s.expect("background raises wait for the focus request to finish", !f.raises(since: start).contains(background))
                app.delayAXReplies(milliseconds: 0)
            }
            s.settle()
            s.expect("restacking resumes after focus finishes", f.raises(since: start).contains(background))
            s.expect("the responsive float retains keyboard focus", f.mac.focusedWindow == target)
        })
    }

    @Test("#41 E2: a failed returning tile releases restacking through transitive blocked placements", arguments: WriteOrder.allCases)
    func transitiveFailureReleasesRestacking(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 transitive placement failure / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 0, appCount: 4)
            let background = showLayerWithBackgroundFloat(f)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], d = f.ids[3]
            s.expect("setup: three tiles are visible and the returning tile is parked", [a, b, c].allSatisfy(f.mac.isVisible) && f.mac.isInCloset(d))
            let before = f.snapshot([b, c])
            f.apps[3].hang(); f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            f.app.close(a); s.settle()
            s.expect("the returning tile exhausts its retries", hiddenTimeouts(f, app: f.apps[3], since: start) == 5)
            s.expect("neither transitive dependent receives a geometry write", f.mac.geometryWrites.allSatisfy { ![b, c].contains($0.window) })
            f.unchanged(before)
            s.expect("the failed returning tile remains parked", f.mac.isInCloset(d))
            s.expect("the terminal geometry failure releases background restacking", raises(of: background, in: f.mac, since: start) > 0)
            enabledWithoutDesktopActivation(f, since: start)
        })
    }

    @Test("#41 E8: a successful placement after motion settles reveals the stage before linger", arguments: WriteOrder.allCases)
    func successAfterMotionRevealsStage(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 successful placement after motion / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 250)
            f.select(f.ids[1])
            f.mac.clearMotionHistory()
            // Successful AX replies put the final placement after the 250 ms
            // motion, with ample time left before its 300 ms linger expires.
            f.app.delayAXReplies(milliseconds: 2)
            let start = f.mac.scheduler.trace.count
            f.press("focus right")
            s.expect("all requests succeeded", !f.mac.scheduler.trace.dropFirst(start).contains { $0.contains("cannotComplete") })
            guard let settled = f.mac.stageEvents.first(where: { $0.kind == .settled })?.at,
                  let lastWrite = f.mac.geometryWrites.map(\.at).max() else {
                s.expect("the stage settles and real placement runs", false); return
            }
            let revealed = f.mac.stageEvents.first { $0.kind == .revealed }?.at
            s.expect("final geometry lands after motion settles and before linger", lastWrite > settled && lastWrite < settled + 300)
            s.expect("success reveals the real layout promptly after placement", revealed.map { $0 >= lastWrite && $0 < settled + 300 } == true)
            f.pair(f.ids[1], f.ids[2], focused: f.ids[2])
        })
    }

    @Test("#41 E6: the next key retries failed dependency and focus handoffs", arguments: WriteOrder.allCases, ["dependency", "focus"])
    func nextKeyRetriesDependencyAndFocus(_ writes: WriteOrder, _ failure: String) {
        requireCarousel(Scenario.run("#41 next key after \(failure) failure / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: failure == "dependency" ? 2 : 1)
            if failure == "dependency" {
                prepareDependency(f)
                f.app.hang(); f.press("focus right"); f.app.resume(); s.settle()
            } else {
                prepareRail(f); exhaustFocus(f)
            }
            s.expect("recovery without an event keeps the outgoing pair visible", f.ids.prefix(2).allSatisfy(f.mac.isVisible) && f.mac.focusedWindow == f.ids[failure == "dependency" ? 1 : 0])
            f.mac.clearMotionHistory()
            f.press("focus left")
            if failure == "dependency" {
                f.pair(f.ids[1], f.ids[2], focused: f.ids[1])
                s.expect("the next key retries the parked destination", f.mac.geometryWrites.contains { $0.window == f.ids[2] })
            } else {
                f.focus(f.ids[2])
                s.expect("the next key retries focus", f.mac.focusRequests.contains { $0.window == f.ids[2] })
                s.expect("the completed focus handoff retires both outgoing tiles", f.ids.prefix(2).allSatisfy(f.mac.isInCloset))
            }
            s.expect("the next render retires the old cover", f.mac.isInCloset(f.ids[0]))
        })
    }

    @Test("#41 E7: accepted deferred activation without a failure keeps waiting", arguments: WriteOrder.allCases)
    func deferredActivationKeepsWaiting(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#41 accepted activation keeps waiting / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], app = f.apps[1]
            f.select(b); f.press("move down"); f.press("focus up"); f.select(a)
            for _ in 0..<2 { app.deferNextActivation(completion: .nextRequest) }
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            f.press("focus down")
            s.expect("AX accepted activation but macOS has not completed it", app.activationPending && f.mac.frontmostApp == f.apps[0].pid)
            s.expect("the destination is prepared but outgoing focus and coverage remain", f.ids.allSatisfy(f.mac.isVisible) && f.mac.focusedWindow == a)
            s.expect("no AX request failed", !f.mac.scheduler.trace.dropFirst(start).contains { $0.contains("cannotComplete") })
            let writesBefore = f.mac.geometryWrites.count
            s.after(milliseconds: 5_000, "activation remains deferred") {
                s.expect("elapsed time cannot retire an unconfirmed outgoing rail", f.mac.isVisible(a) && f.mac.isVisible(c) && f.mac.focusedWindow == a)
            }
            s.settle()
            app.select(b); s.settle()
            s.expect("native activation completes the waiting handoff", f.mac.focusedWindow == b && f.mac.visibleOrder == [b])
            s.expect("confirmation does not replay geometry", f.mac.geometryWrites.count == writesBefore)
        })
    }

    @Test("#41 E8: a failed ending keeps covers, management and idle behavior", arguments: WriteOrder.allCases, ["replacement", "dependency", "focus", "independent"])
    func failureNeverPretendsSuccess(_ writes: WriteOrder, _ failure: String) {
        requireCarousel(Scenario.run("#41 failed ending invariants / \(failure) / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, appCount: failure == "focus" ? 1 : 2)
            if failure == "independent" {
                prepareWorkspace(f)
                f.press("workspace 2"); f.select(f.ids[1]); f.press("workspace 1")
                f.apps[1].limitSize(f.ids[1], maximum: CGSize(width: 749, height: 100_000))
                f.apps[0].hang()
                f.tessel.changeConfig("[animation]\nduration = 0\n[gaps]\nouter = 0\n"); s.settle()
                f.apps[1].delayAXReplies(milliseconds: 250)
                f.mac.clearMotionHistory()
                let start = f.mac.scheduler.trace.count
                f.press("workspace 2")
                s.expect("an independent failed placement is not retried by accepted-size learning", hiddenTimeouts(f, app: f.apps[0], since: start) == 5)
                for attribute in [AXAttribute.size, .position] {
                    s.expect("the prepared tile receives only one geometry burst", f.mac.geometryWrites.filter { $0.window == f.ids[1] && $0.attribute == attribute }.count == 1)
                }
                enabledWithoutDesktopActivation(f, since: start)
                return
            }
            if failure == "replacement" { prepareWorkspace(f) }
            else if failure == "dependency" { prepareDependency(f) }
            else { prepareRail(f) }
            f.mac.clearMotionHistory(); f.mac.beginPresentationTrace()
            let start = f.mac.scheduler.trace.count
            if failure == "focus" { exhaustFocus(f) }
            else {
                f.apps[failure == "replacement" ? 1 : 0].hang()
                f.press(failure == "replacement" ? "workspace 2" : "focus right")
            }
            s.expect("a failure never hides an outgoing cover", f.mac.visibilityChanges.allSatisfy(\.showing))
            enabledWithoutDesktopActivation(f, since: start)
            let visible = f.mac.visibleOrder, before = f.snapshot(), idleStart = f.mac.scheduler.trace.count
            f.apps.forEach { $0.resume() }
            s.after(milliseconds: 5_000, "remain idle after the failure") {}
            s.settle()
            s.expect("resuming without an event issues no AX retry", !f.mac.scheduler.trace.dropFirst(idleStart).contains { $0.contains("AccessibilityPort.") })
            s.expect("idle failure issues no stage work", f.mac.stageEvents.isEmpty)
            s.expect("old covers keep their visibility", f.mac.visibleOrder == visible)
            f.unchanged(before)
            enabledWithoutDesktopActivation(f, since: start)
        })
    }

    private func prepareWorkspace(_ f: CarouselFixture) {
        let a = f.ids[0], b = f.ids[1], c = f.ids[2]
        f.select(b); f.press("send 2"); f.press("workspace 1")
        f.select(c); f.press("send 2"); f.press("workspace 1"); f.select(a)
        f.s.expect("setup: only the outgoing workspace tile is visible", f.mac.isVisible(a) && f.mac.isInCloset(b) && f.mac.isInCloset(c))
    }

    private func prepareDependency(_ f: CarouselFixture) {
        f.select(f.ids[0]); f.select(f.ids[1])
        f.s.expect("setup: the first pair is visible and the third tile is in the closet", f.mac.isVisible(f.ids[0]) && f.mac.isVisible(f.ids[1]) && f.mac.isInCloset(f.ids[2]))
    }

    private func prepareRail(_ f: CarouselFixture) {
        f.select(f.ids[2]); f.press("move down"); f.press("focus up"); f.select(f.ids[0])
        f.s.expect("setup: the first rail owns focus and the destination is in the closet", f.mac.focusedWindow == f.ids[0] && f.mac.isInCloset(f.ids[2]))
    }

    private func exhaustFocus(_ f: CarouselFixture, command: String = "focus down") {
        f.tessel.press(command)
        let held = f.mac.pause(after: .call("AccessibilityPort.set AXFrontmost=true \(f.app.alias) pid=\(f.app.pid)"))
        if case .paused = held {} else { f.s.expect("the focus-only activation is held: \(held)", false) }
        f.s.expect("the destination is already visible before focus starts", f.mac.isVisible(f.ids[2]))
        f.app.hang(); f.s.settle()
        f.app.resume(); f.s.settle()
    }

    private func hiddenTimeouts(_ f: CarouselFixture, app: SimulatedApp, since start: Int) -> Int {
        hiddenTimeouts(in: f.mac, app: app, since: start)
    }

    private func hiddenTimeouts(in mac: SimulatedMac, app: SimulatedApp, since start: Int) -> Int {
        mac.scheduler.trace.dropFirst(start).filter {
            $0.contains("AccessibilityPort.copy AXHidden reply \(app.alias) pid=\(app.pid) cannotComplete")
        }.count
    }

    private func showLayerWithBackgroundFloat(_ f: CarouselFixture) -> UInt32 {
        let foreground = f.mac.launch(), background = f.mac.launch()
        let selected = foreground.open(WindowSpec(subrole: "AXDialog"), background: true)
        let observed = background.open(WindowSpec(subrole: "AXDialog"), background: true)
        f.s.settle()
        f.tessel.changeConfig(LayerFixture.config + "[animation]\nduration = 0\n"); f.s.settle()
        foreground.select(selected); f.s.settle()
        f.s.expect("setup: the shown layer includes a responsive background float", f.mac.isVisible(selected) && f.mac.isVisible(observed) && f.mac.focusedWindow == selected)
        return observed
    }

    private func raises(of id: UInt32, in mac: SimulatedMac, since start: Int) -> Int {
        mac.scheduler.trace.dropFirst(start).filter {
            $0.contains("AccessibilityPort.perform AXRaise window \(id) ")
        }.count
    }

    private func enabledWithoutDesktopActivation(_ f: CarouselFixture, since start: Int) {
        f.s.expect("failed coverage does not disable management", f.tessel.status.enabled)
        f.s.expect("a failed handoff never activates the desktop", !f.mac.scheduler.trace.dropFirst(start).contains { $0.contains("ApplicationPort.activate app-desktop") })
    }
}

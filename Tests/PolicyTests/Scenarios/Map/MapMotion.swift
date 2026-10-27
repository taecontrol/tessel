import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct MapMotion {
    @Test("#18 E17: map transitions follow animation and Reduce Motion independently of Screen Recording", arguments: ["on", "zero", "reduced", "no-recording"])
    func mapMotionHasNoCaptureDependency(_ mode: String) {
        requireCarousel(Scenario.run("map motion \(mode)") { s in
            let f = MapFixture(s, animation: mode == "zero" ? 0 : 250, reduced: mode == "reduced", recording: mode != "no-recording")
            let t0 = f.mac.scheduler.now, motion = mode != "zero" && mode != "reduced"
            f.tessel.pressKey("alt-l"); s.settle()
            f.expectShown(at: t0)
            s.expect("the map transition follows its own motion preference", f.shows.contains { $0.at == t0 && $0.transition == (motion ? 0.25 : 0) })
            f.expectHide(at: t0 + 1000, fade: motion ? 0.12 : 0)
            if mode == "no-recording" {
                s.expect("the map animates while the stage cannot show", !f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            }
        })
    }

    @Test("#18 E17: a nondefault animation duration sets the map transition in seconds")
    func nondefaultAnimationControlsTransition() {
        requireScenario(Scenario.run("map 100 ms animation") { s in
            let f = MapFixture(s)
            f.tessel.changeConfig("[experiments]\nmap = true\n[animation]\nduration = 100\n"); s.settle()
            s.expect("the nondefault duration loads", f.tessel.configuration.error == nil
                && f.tessel.configuration.effective.animation.duration == 100)
            let t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l"); s.settle()
            f.expectShown(at: t0)
            s.expect("100 ms becomes a 0.1 second transition", f.shows.contains { $0.at == t0 && $0.transition == 0.1 })
            f.expectHide(at: t0 + 1000)
        })
    }

    @Test("#18 E18: enabling Reduce Motion during a hold makes the next refresh and departure instant")
    func reduceMotionChangesAVisibleMap() {
        requireCarousel(Scenario.run("map Reduce Motion during hold") { s in
            let f = MapFixture(s), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 400, "enable Reduce Motion") { f.mac.setReduceMotion(true) }
            s.after(milliseconds: 600, "a close refreshes without restarting the hold") { f.app.close(f.rails[0][0]) }
            s.settle()
            f.expectShown(at: t0)
            s.expect("the next external redraw is instant", f.shows.contains { $0.at >= t0 + 600 && $0.at < t0 + 1000 && $0.transition == 0 })
            f.expectHide(at: t0 + 1000, fade: 0)
        })
    }

    @Test("#18 E18: enabling Reduce Motion during the fade hides the map immediately")
    func reduceMotionDuringFadeHidesImmediately() {
        requireScenario(Scenario.run("map Reduce Motion during fade") { s in
            let f = MapFixture(s), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 1050, "enable Reduce Motion inside the 120 ms fade") { f.mac.setReduceMotion(true) }
            s.settle()
            s.expect("Reduce Motion interrupts the fade at once", f.hides == [
                SimulatedMac.MapEvent(at: t0 + 1000, kind: .hide(fade: 0.12)),
                SimulatedMac.MapEvent(at: t0 + 1050, kind: .hide(fade: 0))])
            s.expect("the fading map never reappears", f.shows.count == 1)
            s.expect("no departure timer remains", f.mac.scheduler.pendingMainDelays.isEmpty)
        })
    }
}

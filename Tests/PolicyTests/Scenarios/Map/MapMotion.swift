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
}

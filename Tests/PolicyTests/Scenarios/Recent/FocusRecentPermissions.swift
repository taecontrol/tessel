import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FocusRecentPermissions {
    @Test("#57 E3: switching workspace with focus recent never requests Screen Recording")
    func instantSwitchWithoutRecording() {
        requireCarousel(Scenario.run("recent workspace switch without Screen Recording") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 250)
            f.press("send 2")
            f.press("workspace 1")
            f.mac.setScreenRecording(false)
            f.mac.clearMotionHistory()
            Recent.press(f)
            Recent.lands(f, f.ids[0])
            s.expect("an instant workspace switch does not request Screen Recording",
                     !f.mac.stageEvents.contains { $0.kind == .accessRequest })
        })
    }
}

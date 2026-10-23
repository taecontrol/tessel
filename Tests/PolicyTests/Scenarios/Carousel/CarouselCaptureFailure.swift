import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselCaptureFailure {
    @Test("a drawn window first captured by a retarget ends the move immediately when its capture fails")
    func failedRetargetCaptureEndsTheMove() {
        requireCarousel(Scenario.run("retarget capture failure") { s in
            let f = CarouselFixture(s, presets: [1, 1, 1], duration: 1_000)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.mac.failCapture(of: c)
            f.mac.clearStageHistory()
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 110, "retarget the shown stage to a new window") {
                let shows = f.mac.stageEvents.compactMap { if case .show(let rects) = $0.kind { rects } else { nil } }
                s.expect("the first move is shown without the later window", shows.count == 1 && shows[0][c] == nil)
                f.tessel.pressKey("alt-l")
            }
            s.settle()
            let events = f.mac.stageEvents
            let failure = events.firstIndex { $0.kind == .capture(c) }
            s.expect("the new window's failed capture is attempted", failure != nil)
            if let failure {
                s.expect("failure clears the stage before any motion settles", events.dropFirst(failure + 1).first?.kind == .clear
                         && !events.contains { $0.kind == .settled })
            }
            f.expanded(c)
            s.expect("the previous tiles are in the closet", !f.mac.isVisible(a) && !f.mac.isVisible(b)
                     && f.mac.isInCloset(a) && f.mac.isInCloset(b))
            s.expect("capture failure does not disable motion", f.tessel.status.motion == "on")
        })
    }
}

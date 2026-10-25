import CoreGraphics
import Simulator
import Testing

@Suite @MainActor struct CarouselArrivalCompletion {
    @Test("arrival maximum fallback ends after either a resize or a position-only placement", arguments: [false, true])
    func completedArrivalUsesOrdinaryFallback(_ alreadyFull: Bool) {
        requireCarousel(Scenario.run("completed arrival / born at full size: \(alreadyFull)") { s in
            let f = CarouselFixture(s, presets: [], duration: 0)
            let size = alreadyFull ? f.area.size : CGSize(width: 451, height: 400)
            f.mac.clearMotionHistory()
            let id = f.app.open(WindowSpec(frame: CGRect(origin: CGPoint(x: 40, y: 60), size: size), positionAcceptance: .screenEdges))
            s.settle(); f.expanded(id)
            s.expect("only a smaller birth size needs an arrival resize", f.mac.geometryWrites.contains {
                $0.window == id && $0.attribute == .size
            } == !alreadyFull)
            // A later rejection belongs to ordinary preset advance-and-wrap,
            // even if the initial full-size window only needed positioning.
            f.app.limitSize(id, maximum: CGSize(width: 1000, height: 100_000))
            f.app.resizeFromApplication(id, to: CGSize(width: 600, height: 400)); s.settle()
            f.near(f.frame(id).width, f.width(1.0 / 3), "a later rejection wraps to a fitting preset instead of adopting the maximum")
            f.focus(id)
        })
    }

    @Test("a limited arrival retains exact width intent when the app lowers its maximum again")
    func limitedArrivalKeepsExactWidthIntent() {
        requireCarousel(Scenario.run("exact arrival width after a second maximum rejection") { s in
            let f = CarouselFixture(s, presets: [], duration: 0), id = f.open(maximum: 1000)
            f.near(f.frame(id).width, 1000, "the arrival adopts its first maximum")
            f.app.limitSize(id, maximum: CGSize(width: 740, height: 100_000))
            f.app.resizeFromApplication(id, to: CGSize(width: 600, height: 400)); s.settle()
            f.near(f.frame(id).width, 740, "the exact width is clamped to the new maximum without selecting a preset")
            f.focus(id)
        })
    }
}

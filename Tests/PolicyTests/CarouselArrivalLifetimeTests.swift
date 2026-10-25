import CoreGraphics
import Testing
@testable import Policy

struct CarouselArrivalLifetimeTests {
    @Test("a clipped placement, suspension or width command ends the arrival exception", arguments: ["clipped", "suspended", "cycled"])
    func widthIntentEndsArrival(_ path: String) {
        var carousel = Carousel(width: 1708)
        let tile = Carousel.Tile(id: 1, size: CGSize(width: 451, height: 1064), preset: 1, firstPlacementPending: true)
        carousel.insert(tile, workspace: 1)
        switch path {
        case "clipped":
            carousel.accept(1, requested: CGSize(width: 1708, height: 1064), accepted: CGSize(width: 1000, height: 1064), learnBounds: false)
        case "suspended":
            carousel.remove(1, suspending: true)
            carousel.insert(tile, workspace: 1, restoring: true)
        default:
            carousel.cycleWidth(1)
            carousel.cycleWidth(1)
        }
        let request = carousel.size(1)!
        carousel.accept(1, requested: request, accepted: CGSize(width: 740, height: 1064))
        #expect(carousel.size(1)?.width == CGFloat(carousel.presetWidth(1.0 / 3)))
    }

    @Test("native-tab replacement retains an unfinished arrival's maximum fallback")
    func replacementRetainsArrival() {
        var carousel = Carousel(width: 1708)
        carousel.insert(Carousel.Tile(id: 1, size: CGSize(width: 451, height: 1064), preset: 1, firstPlacementPending: true), workspace: 1)
        carousel.replace(1, with: 2)
        carousel.accept(2, requested: CGSize(width: 1708, height: 1064), accepted: CGSize(width: 1000, height: 1064))
        #expect(carousel.frames(1, area: CGRect(x: 0, y: 0, width: 1708, height: 1064))[2]?.width == 1000)
    }
}

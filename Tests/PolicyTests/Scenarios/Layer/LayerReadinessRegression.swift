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

    @Test("#19 E7: an accepted tile frame within one point does not block hiding the layer", arguments: WriteOrder.allCases)
    func acceptedSubpointTileFrameDoesNotBlockLayerExit(_ writes: WriteOrder) {
        withKnownIssue("The instant presenter requires exact readiness for an already accepted frame") {
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
}

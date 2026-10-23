import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerReadinessRegression {
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

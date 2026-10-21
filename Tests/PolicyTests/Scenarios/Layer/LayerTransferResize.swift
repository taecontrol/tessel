import CoreGraphics
import Simulator
import Testing

@Suite @MainActor struct LayerTransferResize {
    @Test("#19 E21: returning a resized float chooses the nearest preset across pending resize reads", arguments: WriteOrder.allCases, ["published", "before size read", "captured", "pending"])
    func nearestPresetAfterExternalResize(_ writes: WriteOrder, _ read: String) {
        requireLayer(Scenario.run("float transfer after resize / \(read) / \(writes)", writes: writes) { s in
            let f = LayerFixture(s), target = f.tiles[1]
            f.select(target); f.press("toggle float")
            f.app.resize(target, to: CGSize(width: f.area.width * 0.62, height: f.area.height * 2 / 3))
            switch read {
            case "published": s.settle()
            case "before size read", "captured":
                let point: PausePoint = read == "captured" ? .read(f.app)
                    : .call("AccessibilityPort.copy AXSize window \(target) \(f.app.alias)")
                let outcome = f.mac.pause(after: point)
                guard case .paused = outcome else {
                    s.expect("the resize read reaches \(read): \(outcome)", false); return
                }
            default: break
            }
            f.near(f.frame(target).width, f.area.width * 0.62, "external resize is accepted before alt-f")
            f.mac.clearMotionHistory()
            s.step("alt-f while resize publication is \(read)") { f.tessel.pressKey("alt-f") }
            s.settle()
            f.focus(target); f.classification(target, "tiled", "moved to a rail")
            f.state("hidden", focused: false)
            f.order([f.tiles[0], target, f.tiles[2]])
            f.near(f.frame(target).width, (f.area.width + 10) * 2 / 3 - 10, "transfer snaps the current float width to two thirds")
            f.near(f.frame(target).height, f.area.height, "the transferred tile fills the rail height")
        })
    }
}

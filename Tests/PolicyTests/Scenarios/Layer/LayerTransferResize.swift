import CoreGraphics
import Simulator
import Testing
@testable import Policy

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

    @Test("#19 E21: equal-distance live widths choose the wider rail preset", arguments: WriteOrder.allCases, [0, 1, 2])
    func presetTiesChooseWider(_ writes: WriteOrder, _ pair: Int) {
        requireLayer(Scenario.run("float preset midpoint \(pair) / \(writes)", writes: writes) { s in
            let f = LayerFixture(s), target = f.tiles[1]
            let presets = [1.0 / 3, 0.5, 2.0 / 3, 1.0]
            let lower = presets[pair] * (f.area.width + 10) - 10
            let upper = presets[pair + 1] * (f.area.width + 10) - 10
            f.select(target); f.press("toggle float")
            f.app.drag(target, to: CGPoint(x: f.area.minX, y: f.frame(target).minY))
            f.app.resize(target, to: CGSize(width: (lower + upper) / 2, height: f.frame(target).height))
            f.near(f.frame(target).width, (lower + upper) / 2, "the native float accepts the preset midpoint")
            s.step("alt-f before the midpoint resize is published") { f.tessel.pressKey("alt-f") }
            s.settle()
            f.focus(target); f.classification(target, "tiled", "moved to a rail")
            f.near(f.frame(target).width, upper, "a tie chooses the wider preset")
        })
    }

    @Test("#19 E21: an unanswered current-width read leaves the float in the layer", arguments: WriteOrder.allCases)
    func failedFrameReadDoesNotUseCachedWidth(_ writes: WriteOrder) {
        requireLayer(Scenario.run("float transfer with unanswered geometry / \(writes)", writes: writes) { s in
            let f = LayerFixture(s), target = f.tiles[1]
            f.select(target); f.press("toggle float")
            let before = f.frames(f.tiles + f.floats)
            f.app.hang(); f.mac.clearMotionHistory()
            f.press("toggle float")
            f.classification(target, "floats", "moved to the layer")
            f.state("shown", focused: true); f.unchanged(before)
            s.expect("an unanswered read performs no geometry writes", f.mac.geometryWrites.isEmpty)
            f.app.resume(); s.settle()
            f.classification(target, "floats", "moved to the layer")
            f.press("toggle float"); f.focus(target)
            f.classification(target, "tiled", "moved to a rail")
        })
    }

    @Test("#19 E21: repeated alt-f presses preserve toggle parity while the current-width read is pending", arguments: WriteOrder.allCases, [2, 3])
    func repeatedToggleDuringFrameRead(_ writes: WriteOrder, _ presses: Int) {
        requireLayer(Scenario.run("\(presses) pending float toggles / \(writes)", writes: writes) { s in
            let f = LayerFixture(s), target = f.tiles[1]
            f.select(target); f.press("toggle float")
            f.app.resize(target, to: CGSize(width: f.area.width * 0.62, height: f.frame(target).height))
            s.settle()
            f.tessel.pressKey("alt-f")
            let outcome = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(target) \(f.app.alias)"))
            guard case .paused = outcome else {
                s.expect("the return's current frame read is held: \(outcome)", false); return
            }
            for _ in 1..<presses { f.tessel.pressKey("alt-f") }
            s.settle()
            f.focus(target)
            f.classification(target, presses == 2 ? "floats" : "tiled", presses == 2 ? "moved to the layer" : "moved to a rail")
            f.state(presses == 2 ? "shown" : "hidden", focused: presses == 2)
            f.near(f.frame(target).width, presses == 2 ? f.area.width * 0.62 : (f.area.width + 10) * 2 / 3 - 10,
                   "the last toggle uses the observed float width")
        })
    }

    @Test("#19 E21: a float with an attached sheet transfers its root while keeping the sheet visible", arguments: WriteOrder.allCases)
    func attachedSheetKeepsRootSelection(_ writes: WriteOrder) {
        requireLayer(Scenario.run("float transfer with attached sheet / \(writes)", writes: writes) { s in
            let f = LayerFixture(s), target = f.tiles[1]
            f.select(target); f.press("toggle float")
            let sheet = f.open(WindowSpec(subrole: "AXDialog", parent: target))
            s.expect("the sheet owns native keyboard focus", f.mac.focusedWindow == sheet)
            f.press("toggle float")
            f.classification(target, "tiled", "moved to a rail")
            f.order([f.tiles[0], target, f.tiles[2]])
            s.expect("the sheet stays focused with its transferred parent", f.mac.focusedWindow == sheet && f.mac.isVisible(sheet) && !f.mac.isInCloset(sheet))
            f.near(f.frame(target).width, (f.area.width + 10) / 2 - 10, "the root gets its nearest half preset")
        })
    }

    @Test("#19 E21: a newer layer-exit decision cancels a captured width read before its publication", arguments: WriteOrder.allCases)
    func layerExitSupersedesCapturedFrame(_ writes: WriteOrder) {
        requireLayer(Scenario.run("layer exit after transfer width capture / \(writes)", writes: writes) { s in
            let f = LayerFixture(s), target = f.tiles[1]
            f.select(target); f.press("toggle float")
            f.tessel.press("toggle float")
            let outcome = f.mac.pause(after: .read(f.app))
            guard case .paused = outcome else {
                s.expect("the transfer's frame is captured before publication: \(outcome)", false); return
            }
            f.tessel.press("toggle layer"); s.settle()
            f.classification(target, "floats", "moved to the layer")
            f.state("hidden", focused: false); f.focus(f.tiles[0])
            s.expect("the older transfer does not insert a tile", f.row(target)?.rail == nil)
        })
    }

    @Test("#19 E21: a pending frame read cannot transfer a float after a newer decision or native lifecycle change", arguments: WriteOrder.allCases, ["workspace", "close", "minimize", "fullscreen", "selection"])
    func obsoleteFrameReadDoesNotTransfer(_ writes: WriteOrder, _ change: String) {
        requireLayer(Scenario.run("float transfer interrupted by \(change) / \(writes)", writes: writes) { s in
            let f = LayerFixture(s), target = f.tiles[1]
            f.select(target); f.press("toggle float")
            f.mac.clearMotionHistory()
            f.tessel.press("toggle float")
            let outcome = f.mac.pause(after: .call("AccessibilityPort.copy AXSize window \(target) \(f.app.alias)"))
            guard case .paused = outcome else {
                s.expect("the current frame read is held: \(outcome)", false); return
            }
            s.step("interrupt the pending transfer with \(change)") {
                switch change {
                case "workspace": f.tessel.press("workspace 2")
                case "close": f.app.close(target)
                case "minimize": f.app.minimize(target)
                case "fullscreen": f.app.enterFullscreen(target)
                default: f.app.select(f.tiles[0])
                }
            }
            s.settle()
            s.expect("the obsolete read creates no tile", f.row(target)?.rail == nil)
            s.expect("the obsolete read does not change manual classification", f.row(target)?.reason != "moved to a rail")
            if change != "disable" {
                s.expect("the obsolete transfer performs no geometry writes", !f.mac.geometryWrites.contains { $0.window == target })
            }
            if change == "workspace" { s.expect("the new workspace stays active", f.tessel.status.active == 2) }
            if change == "selection" { f.focus(f.tiles[0]) }
            if change == "minimize" {
                f.app.restore(target); s.settle()
                f.classification(target, "floats", "moved to the layer")
            }
            if change == "fullscreen" {
                f.app.leaveFullscreen(target); s.settle()
                f.classification(target, "floats", "moved to the layer")
            }
        })
    }
}

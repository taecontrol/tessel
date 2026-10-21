import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerDecisions {
    @Test("#19 E21: equally near rail widths choose the wider preset", arguments: [0, 1, 2])
    func nearestWidthTie(_ index: Int) {
        requireLayer(Scenario.run("float width tie between presets \(index) and \(index + 1)") { s in
            let width = s.mac.screens.primaryScreen!.visibleFrame.width - 20
            let presets = [1.0 / 3, 0.5, 2.0 / 3, 1.0]
            let narrower = presets[index] * (width + 10) - 10
            let wider = presets[index + 1] * (width + 10) - 10
            let spec = WindowSpec(frame: CGRect(x: 40, y: 60, width: (narrower + wider) / 2, height: 260), subrole: "AXDialog")
            let f = LayerFixture(s, floatSpecs: [spec]), id = f.floats[0]
            f.press("toggle layer"); f.press("toggle float")
            f.focus(id); f.classification(id, "tiled", "moved to a rail")
            f.near(f.frame(id).width, wider, "a tie selects the wider rail preset")
        })
    }

    @Test("#19 E24: disabling only the layer preserves explicit carousel workspace visibility")
    func explicitCarouselKeepsInactiveFloatsHidden() {
        requireLayer(Scenario.run("layer disabled while carousel stays explicitly enabled") { s in
            let f = LayerFixture(s), remote = f.floats[0], local = f.floats[1]
            f.press("toggle layer"); f.press("send 3"); f.press("workspace 1"); f.press("toggle layer")
            f.tessel.changeConfig("[experiments]\ncarousel = true\nlayer = false\n[animation]\nduration = 0\n"); s.settle()
            s.expect("explicit carousel remains enabled", f.tessel.status.enabled && f.tessel.status.layout == "carousel")
            f.visible([local], true); f.visible([remote], false)
            f.key("alt-z"); f.visible([local], true)
            f.press("workspace 3"); f.focus(remote)
            f.visible([remote], true); f.visible([local], false)
            // Re-enabling over an all-floating workspace transfers focus to
            // the desktop before hiding its last native key window.
            f.mac.clearMotionHistory()
            f.tessel.changeConfig(LayerFixture.config); s.settle()
            f.state("hidden", focused: false); f.visible([remote, local], false)
            s.expect("re-enabling transfers native focus before the closet move", f.mac.visibilityChanges.allSatisfy { change in
                change.showing || (change.focusedWindow.map { !change.windows.contains($0) } ?? true)
            })
        })
    }

    @Test("#19 E26: a delayed cross-app focus confirmation completes the layer exit safely", arguments: DeferredActivationCompletion.allCases)
    func exitAfterDelayedActivation(_ completion: DeferredActivationCompletion) {
        requireLayer(Scenario.run("layer exit after deferred activation \(completion.rawValue)") { s in
            let f = LayerFixture(s), other = s.mac.launch()
            let dialog = other.open(WindowSpec(subrole: "AXDialog"), background: true)
            s.settle(); f.state("single", focused: true); f.focus(dialog)
            f.app.deferNextActivation(completion: completion)
            f.mac.clearMotionHistory()
            f.press("toggle layer")
            f.state("hidden", focused: false); f.focus(f.tiles[0]); f.visible(f.floats + [dialog], false)
            s.expect("a deferred activation never closets keyboard focus", f.mac.visibilityChanges.allSatisfy { change in
                change.showing || (change.focusedWindow.map { !change.windows.contains($0) } ?? true)
            })
        })
    }

    @Test("#19 E12; #19 E14: terminating a float's app obeys single and entered-layer close selection", arguments: [LayerMode.single, .shown, .pinnedLayer])
    func floatingAppTermination(_ mode: LayerMode) {
        requireLayer(Scenario.run("floating app termination in \(mode.rawValue)") { s in
            let f = LayerFixture(s), other = s.mac.launch()
            if mode != .single { f.enter(mode) }
            let dialog = other.open(WindowSpec(subrole: "AXDialog"), background: true)
            s.settle(); f.focus(dialog)
            other.terminate(activating: f.tiles[0], crash: true)
            s.settle()
            f.focus(mode == .single ? f.tiles[0] : f.floats[0])
            f.state(mode == .single ? "hidden" : mode == .shown ? "shown" : "pinned", focused: mode != .single)
            f.visible(f.floats, mode != .single)
        })
    }
}

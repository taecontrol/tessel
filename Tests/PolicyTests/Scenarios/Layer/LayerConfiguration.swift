import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerConfiguration {
    @Test("#19 E5: the layer flag implies carousel and its default keys can be rebound or disabled")
    func layerKeyBindings() {
        requireLayer(Scenario.run("layer flag and default keyboard commands") { s in
            let f = LayerFixture(s)
            for (key, command) in [("alt-z", "toggle layer"), ("alt-f", "toggle float")] {
                s.expect("\(key) registers \(command)", f.tessel.status.keys[key] == command)
            }
            f.key("alt-z"); f.state("shown", focused: true); f.focus(f.floats[0])
            f.key("alt-z"); f.state("hidden", focused: false)
            let overrides = "[keys]\nalt-z = ''\nalt-f = ''\nalt-a = 'toggle layer'\nalt-c = 'toggle float'\n"
            f.tessel.changeConfig(LayerFixture.config + overrides); s.settle()
            s.expect("both commands are valid key overrides", f.tessel.configuration.error == nil)
            for (key, command) in [("alt-a", "toggle layer"), ("alt-c", "toggle float")] {
                s.expect("override \(key) registers \(command)", f.tessel.status.keys[key] == command)
            }
            f.key("alt-z"); f.state("hidden", focused: false)
            f.key("alt-a"); f.state("shown", focused: true)
            f.key("alt-c"); f.classification(f.floats[0], "tiled", "moved to a rail")
        })
    }

    @Test("#19 E6: startup and enabling hide existing floats unless startup focus is already in the layer", arguments: ["startup-tile", "startup-float"])
    func initialVisibilityAndFocus(_ mode: String) {
        requireLayer(Scenario.run("layer initial state \(mode)") { s in
            let inLayer = mode == "startup-float"
            let f = LayerFixture(s, startup: mode != "enable", focusedFloat: inLayer)
            f.state(inLayer ? "shown" : "hidden", focused: inLayer)
            f.visible(f.floats, inLayer)
            f.focus(inLayer ? f.floats[0] : f.tiles[0])
            f.order(f.tiles)
            s.expect("initial float visibility never changes floating geometry", f.mac.geometryWrites.allSatisfy { !f.floats.contains($0.window) })
        })
    }

    @Test("#19 E24: quitting returns every float", arguments: ["quit"])
    func cleanupReturnsEveryFloat(_ action: String) {
        requireLayer(Scenario.run("layer cleanup via \(action)") { s in
            let f = LayerFixture(s)
            // Retain hidden members in another workspace as well as the active one.
            f.press("toggle layer"); f.press("send 3"); f.press("workspace 1"); f.press("toggle layer")
            let all = f.floats
            f.visible(all, false)
            f.tessel.quit()
            s.settle()
            s.expect("cleanup never loses a float", all.allSatisfy { id in f.tessel.windows.contains { $0.id == id } })
            s.expect("cleanup returns every float to the native desktop", all.allSatisfy { f.mac.isVisible($0) && !f.mac.isInCloset($0) })

        })
    }
}

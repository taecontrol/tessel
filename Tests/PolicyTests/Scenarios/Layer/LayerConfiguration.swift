import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerConfiguration {
    @Test("#19 E5: the layer flag implies carousel and its default keys can be rebound or disabled")
    func flagAndKeyBindings() {
        requireLayer(Scenario.run("layer flag and default keyboard commands") { s in
            let f = LayerFixture(s)
            for (key, command) in [("alt-z", "toggle layer"), ("alt-shift-z", "pin layer"), ("alt-f", "toggle float")] {
                s.expect("\(key) registers \(command)", f.tessel.status.keys[key] == command)
            }
            f.key("alt-z"); f.state("shown", focused: true); f.focus(f.floats[0])
            f.key("alt-z"); f.state("hidden", focused: false)
            let overrides = "[keys]\nalt-z = ''\nalt-shift-z = ''\nalt-f = ''\nalt-a = 'toggle layer'\nalt-shift-a = 'pin layer'\nalt-c = 'toggle float'\n"
            f.tessel.changeConfig(LayerFixture.config + overrides); s.settle()
            s.expect("all three commands are valid key overrides", f.tessel.configuration.error == nil)
            for (key, command) in [("alt-a", "toggle layer"), ("alt-shift-a", "pin layer"), ("alt-c", "toggle float")] {
                s.expect("override \(key) registers \(command)", f.tessel.status.keys[key] == command)
            }
            f.key("alt-z"); f.state("hidden", focused: false)
            f.key("alt-a"); f.state("shown", focused: true)
            f.key("alt-shift-a"); f.state("pinned", focused: true)
            f.key("alt-c"); f.classification(f.floats[0], "tiled", "moved to a rail")
        })
        for layout in [Layout.off, .carousel] {
            requireLayer(Scenario.run("layer keys without its flag, layout=\(layout.rawValue)") { s in
                let app = s.mac.launch(windows: 2)
                let panel = app.open(WindowSpec(subrole: "AXFloatingWindow"), background: true)
                app.select(1)
                let t = s.startTessel(layout); s.settle()
                let before = t.windows.map { ($0.id, s.mac.frame($0.id)) }, focus = s.mac.focusedWindow
                s.mac.clearMotionHistory()
                let start = s.mac.scheduler.trace.count
                for key in ["alt-z", "alt-shift-z", "alt-f"] { t.pressKey(key); s.settle() }
                s.expect("unflagged keys leave focus unchanged", s.mac.focusedWindow == focus)
                s.expect("unflagged keys do no AX work", LayerFixture.axWrites(in: Array(s.mac.scheduler.trace.dropFirst(start))).isEmpty)
                s.expect("the unflagged panel remains visible at its native frame", s.mac.isVisible(panel) && before.allSatisfy { s.mac.frame($0.0) == $0.1 })
                s.expect("the unflagged panel remains a float", t.windows.first { $0.id == panel }?.state == .floats)
                let base = layout == .off ? "" : CarouselFixture.config
                t.changeConfig(base + "[keys]\nalt-a = 'toggle layer'\nalt-shift-a = 'pin layer'\nalt-c = 'toggle float'\n"); s.settle()
                s.expect("layer commands validate even while the experiment is off", t.configuration.error == nil)
                for key in ["alt-a", "alt-shift-a", "alt-c"] { t.pressKey(key); s.settle() }
                s.expect("explicit layer bindings are inert without the flag", s.mac.focusedWindow == focus && s.mac.isVisible(panel))
            })
        }
    }

    @Test("#19 E6: startup and enabling hide existing floats unless startup focus is already in the layer", arguments: ["enable", "startup-tile", "startup-float"])
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

    @Test("#19 E24: disabling, removing config and quitting return every float and re-enabling starts hidden", arguments: ["false", "remove", "quit"])
    func cleanupReturnsEveryFloat(_ action: String) {
        requireLayer(Scenario.run("layer cleanup via \(action)") { s in
            let f = LayerFixture(s)
            // Retain hidden members in another workspace as well as the active one.
            f.press("toggle layer"); f.press("send 3"); f.press("workspace 1"); f.press("toggle layer")
            let all = f.floats
            f.visible(all, false)
            switch action {
            case "false": f.tessel.changeConfig("[experiments]\nlayer = false\n")
            case "remove": f.tessel.changeConfig(nil)
            default: f.tessel.quit()
            }
            s.settle()
            s.expect("cleanup never loses a float", all.allSatisfy { id in f.tessel.windows.contains { $0.id == id } })
            s.expect("cleanup returns every float to the native desktop", all.allSatisfy { f.mac.isVisible($0) && !f.mac.isInCloset($0) })
            if action == "quit" { return }
            f.app.select(f.tiles[0]); s.settle()
            f.tessel.changeConfig(LayerFixture.config); s.settle()
            f.state("hidden", focused: false); f.visible(all, false); f.focus(f.tiles[0])
        })
    }
}

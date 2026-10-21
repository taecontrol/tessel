import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerNavigation {
    @Test("#19 E7: toggling shows the most recent float and returns to the remembered rail without moving tiles")
    func enterAndLeaveRememberFocus() {
        requireLayer(Scenario.run("toggle layer round trip and MRU entry") { s in
            let f = LayerFixture(s), a = f.floats[0], b = f.floats[1]
            f.select(f.tiles[1])
            let before = f.frames(f.tiles), rail = f.tessel.status.rail
            f.mac.clearMotionHistory()
            f.press("toggle layer"); f.state("shown", focused: true); f.focus(a); f.visible(f.floats, true)
            f.unchanged(before)
            f.press("focus right"); f.focus(b)
            f.press("toggle layer"); f.state("hidden", focused: false); f.focus(f.tiles[1]); f.visible(f.floats, false)
            f.unchanged(before)
            s.expect("the rail and its scroll position survive the layer", f.tessel.status.rail == rail)
            f.press("toggle layer"); f.focus(b); f.visible(f.floats, true)
            s.expect("instant layer toggles never capture", f.captures.isEmpty)
            s.expect("instant layer toggles never write tiles", !f.mac.geometryWrites.contains { f.tiles.contains($0.window) })
        })
    }

    @Test("#19 E8: layer navigation wraps in arrival order and a moved tile becomes the newest arrival", arguments: [LayerMode.shown, .pinnedLayer])
    func stableCycleWithWrap(_ mode: LayerMode) {
        requireLayer(Scenario.run("layer arrival-order cycle \(mode.rawValue)") { s in
            let f = LayerFixture(s), a = f.floats[0], b = f.floats[1]
            f.enter(mode)
            let before = f.frames(f.floats)
            f.mac.clearMotionHistory()
            for (command, expected) in [("focus right", b), ("focus down", a), ("focus left", b), ("focus up", a)] {
                f.press(command); f.focus(expected); f.unchanged(before)
            }
            s.expect("cycling floats writes no geometry", f.mac.geometryWrites.isEmpty)
            f.press("toggle layer"); f.select(f.tiles[1]); f.press("toggle float"); f.focus(f.tiles[1])
            f.press("focus right"); f.focus(a)
            f.press("focus left"); f.focus(f.tiles[1])
            f.press("focus left"); f.focus(b)
            f.unchanged(before)
        })
    }

    @Test("#19 E9: pinning preserves rail navigation and layer focus, while unpinning obeys focus")
    func pinningAndUnpinning() {
        requireLayer(Scenario.run("pin in rails, enter, leave and unpin") { s in
            let f = LayerFixture(s)
            f.select(f.tiles[2]); f.press("move down"); f.press("focus up"); f.press("focus left")
            f.state("hidden", focused: false)
            f.press("focus right"); f.focus(f.tiles[1])
            f.press("focus down"); f.focus(f.tiles[2])
            f.press("focus up"); f.focus(f.tiles[1])
            f.press("focus left"); f.focus(f.tiles[0])
            f.press("pin layer"); f.state("pinned", focused: false); f.visible(f.floats, true); f.focus(f.tiles[0])
            f.press("focus right"); f.focus(f.tiles[1])
            f.press("focus left"); f.focus(f.tiles[0])
            f.press("focus down"); f.focus(f.tiles[2])
            f.press("focus up"); f.focus(f.tiles[0])
            f.press("toggle layer"); f.state("pinned", focused: true); f.focus(f.floats[0])
            f.press("toggle layer"); f.state("pinned", focused: false); f.focus(f.tiles[0]); f.visible(f.floats, true)
            f.press("pin layer"); f.state("hidden", focused: false); f.visible(f.floats, false)
            f.press("toggle layer"); f.press("pin layer"); f.state("pinned", focused: true)
            f.press("pin layer"); f.state("shown", focused: true); f.visible(f.floats, true); f.focus(f.floats[0])
            f.press("toggle layer"); f.state("hidden", focused: false)
        })
    }

    @Test("#19 E14: closing within an entered layer selects its surviving MRU and the last close returns to rails", arguments: [LayerMode.shown, .pinnedLayer])
    func closingUsesSurvivingMRU(_ mode: LayerMode) {
        requireLayer(Scenario.run("close floats in \(mode.rawValue)") { s in
            let f = LayerFixture(s), a = f.floats[0], b = f.floats[1]
            f.enter(mode)
            let c = f.open()
            f.press("focus left"); f.focus(b)
            f.press("focus left"); f.focus(a)
            f.close(a); f.focus(b)
            f.state(mode == .shown ? "shown" : "pinned", focused: true)
            f.close(b); f.focus(c)
            f.close(c); f.state("hidden", focused: false); f.focus(f.tiles[0])
            s.expect("the final float removes no tile", Set(f.tessel.windows.map(\.id)) == Set(f.tiles))
        })
    }

    @Test("#19 E15: toggling an empty layer does no focus work, AX writes, closet moves or bounce")
    func emptyLayerIsInert() {
        requireLayer(Scenario.run("toggle an empty layer") { s in
            let f = LayerFixture(s, floatSpecs: [], duration: 250)
            let before = f.frames(f.tiles), focus = f.mac.focusedWindow
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            f.press("toggle layer")
            f.state("hidden", focused: false); f.unchanged(before)
            s.expect("empty entry keeps native focus", f.mac.focusedWindow == focus)
            s.expect("empty entry makes no AX writes", LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start))).isEmpty)
            s.expect("empty entry never touches the closet", f.mac.visibilityChanges.flatMap(\.windows).isEmpty)
            s.expect("empty entry has no bounce or capture", f.mac.stageEvents.allSatisfy { $0.kind == .clear })
        })
    }

    @Test("#19 E19: rail resizing and reordering commands are inert inside every focused layer state", arguments: [LayerMode.single, .shown, .pinnedLayer])
    func railCommandsAreInertInLayer(_ mode: LayerMode) {
        requireLayer(Scenario.run("rail-only commands in \(mode.rawValue)") { s in
            let f = LayerFixture(s)
            let focused = f.enter(mode), before = f.frames(f.tiles + f.app.windows.filter { !f.tiles.contains($0) })
            let slots = f.tessel.windows.map { "\($0.id):\($0.rail ?? 0):\($0.slot ?? 0)" }
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            for command in ["cycle width", "move left", "move down", "move up", "move right"] {
                f.press(command); f.unchanged(before)
                s.expect("\(command) keeps focus", f.mac.focusedWindow == focused)
                s.expect("\(command) keeps rail membership", f.tessel.windows.map { "\($0.id):\($0.rail ?? 0):\($0.slot ?? 0)" } == slots)
            }
            s.expect("rail commands do no AX writes in the layer", LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start))).isEmpty)
            s.expect("rail commands make no stage motion in the layer", f.mac.stageEvents.allSatisfy { $0.kind == .clear })
        })
    }
}

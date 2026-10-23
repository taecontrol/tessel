import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerNavigation {
    @Test("#19 E7; #38 E4: toggling shows the most recent float and returns to the remembered rail without moving tiles")
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

    @Test("#19 E8: layer navigation wraps in arrival order and a moved tile becomes the newest arrival", arguments: [LayerMode.shown])
    func stableCycleWithWrap(_ mode: LayerMode) {
        requireLayer(Scenario.run("layer arrival-order cycle \(mode.rawValue)") { s in
            let f = LayerFixture(s, floatSpecs: (0..<3).map { _ in WindowSpec(subrole: "AXFloatingWindow") })
            let a = f.floats[0], b = f.floats[1], c = f.floats[2]
            f.enter(mode)
            let before = f.frames(f.floats)
            f.mac.clearMotionHistory()
            for command in ["focus right", "focus down", "focus left", "focus up"] {
                let cycle = command == "focus right" || command == "focus down" ? [b, c, a] : [c, b, a]
                for expected in cycle {
                    f.press(command); f.focus(expected); f.unchanged(before)
                }
            }
            s.expect("cycling floats writes no geometry", f.mac.geometryWrites.isEmpty)
            f.press("toggle layer"); f.select(f.tiles[1]); f.press("toggle float"); f.focus(f.tiles[1])
            f.press("focus right"); f.focus(a)
            f.press("focus left"); f.focus(f.tiles[1])
            f.press("focus left"); f.focus(c)
            f.unchanged(before)
        })
    }

    @Test("#19 E14: closing within an entered layer selects its surviving MRU and the last close returns to rails", arguments: [LayerMode.shown])
    func closingUsesSurvivingMRU(_ mode: LayerMode) {
        requireLayer(Scenario.run("close floats in \(mode.rawValue)") { s in
            let f = LayerFixture(s, floatSpecs: (0..<4).map { _ in WindowSpec(subrole: "AXFloatingWindow") })
            let a = f.floats[0], b = f.floats[1], c = f.floats[2], d = f.floats[3]
            f.enter(mode)
            f.select(c); f.select(a)
            f.close(a); f.focus(c)
            s.expect("both non-MRU alternatives survive", Set(f.app.windows) == Set(f.tiles + [b, c, d]))
            f.visible([b, c, d], true)
            f.state("shown", focused: true)
            f.close(b); f.focus(c)
            f.close(d); f.focus(c)
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

    @Test("#19 E19: rail resizing and reordering commands are inert inside every focused layer state", arguments: [LayerMode.single, .shown])
    func railCommandsAreInertInLayer(_ mode: LayerMode) {
        requireLayer(Scenario.run("rail-only commands in \(mode.rawValue)") { s in
            let f = LayerFixture(s, duration: 250)
            let focused = f.enter(mode), before = f.frames(f.tiles + f.app.windows.filter { !f.tiles.contains($0) })
            let slots = f.tessel.windows.map { "\($0.id):\($0.rail ?? 0):\($0.slot ?? 0)" }
            let layer = f.tessel.status.layer
            let visibility = Dictionary(uniqueKeysWithValues: f.app.windows.map { ($0, f.mac.isVisible($0)) })
            s.expect("the inert-command check has animation enabled", f.tessel.status.animationDuration == 250)
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            for command in ["cycle width", "move left", "move down", "move up", "move right"] {
                f.press(command); f.unchanged(before)
                s.expect("\(command) keeps focus", f.mac.focusedWindow == focused)
                s.expect("\(command) keeps rail membership", f.tessel.windows.map { "\($0.id):\($0.rail ?? 0):\($0.slot ?? 0)" } == slots)
                s.expect("\(command) keeps layer state and entry", f.tessel.status.layer == layer)
                for id in visibility.keys.sorted() { f.visible([id], visibility[id]!) }
                s.expect("\(command) makes no closet operations", f.mac.visibilityChanges.isEmpty)
            }
            s.expect("rail commands do no AX writes in the layer", LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start))).isEmpty)
            s.expect("rail commands make no stage motion in the layer", f.mac.stageEvents.allSatisfy { $0.kind == .clear })
        })
    }
}

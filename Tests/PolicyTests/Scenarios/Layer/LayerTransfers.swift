import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerTransfers {
    @Test("#19 E20: moving a tile centers it in the full layer, closes its slot and remembers its left neighbor", arguments: [false, true])
    func tileMovesToLayer(pinned: Bool) {
        requireLayer(Scenario.run("tile to layer, pinned=\(pinned)") { s in
            let f = LayerFixture(s), a = f.tiles[0], b = f.tiles[1], c = f.tiles[2]
            if pinned { f.press("pin layer") }
            f.select(b); f.press("toggle float")
            f.classification(b, "floats", "moved to the layer")
            f.state(pinned ? "pinned" : "shown", focused: true); f.focus(b); f.visible(f.floats + [b], true)
            s.expect("a moved tile leaves its rail and slot", f.row(b)?.rail == nil && f.row(b)?.slot == nil && f.row(b)?.workspace == 1)
            f.order([a, c])
            let frame = f.frame(b)
            f.near(frame.midX, f.area.midX, "float is centered horizontally")
            f.near(frame.midY, f.area.midY, "float is centered vertically")
            f.near(frame.width, f.area.width / 2, "float is half the area width")
            f.near(frame.height, f.area.height * 2 / 3, "float is two thirds the area height")
            f.press("toggle layer"); f.focus(a)
            f.near(f.frame(c).minX - f.frame(a).maxX, 10, "removing the tile closes its gap")
        })
        requireLayer(Scenario.run("moving a singleton removes its empty rail") { s in
            let f = LayerFixture(s, tileCount: 1), tile = f.tiles[0]
            f.press("toggle float"); f.focus(tile)
            s.expect("the empty rail disappears", f.tessel.status.railCount == 0 && f.row(tile)?.rail == nil)
            f.classification(tile, "floats", "moved to the layer")
        })
    }

    @Test("#19 E21: a resizable float inserts right of rail memory at its nearest width even when it cannot fill", arguments: [LayerMode.single, .shown, .pinnedLayer], [0, 1, 2, 3])
    func floatMovesToRail(_ mode: LayerMode, width: Int) {
        requireLayer(Scenario.run("float to rail \(mode.rawValue), width choice \(width)") { s in
            let areaWidth = s.mac.screens.primaryScreen!.visibleFrame.width - 20
            let fractions = [0.36, 0.54, 0.70, 0.96], presets = [1.0 / 3, 0.5, 2.0 / 3, 1.0]
            let spec = WindowSpec(frame: CGRect(x: 40, y: 70, width: areaWidth * fractions[width], height: 260), subrole: "AXDialog",
                                  maximumSize: CGSize(width: 100_000, height: 300))
            let f = LayerFixture(s, floatSpecs: mode == .single ? [] : [spec])
            f.select(f.tiles[1])
            let target: UInt32
            if mode == .single { target = f.open(spec); f.state("single", focused: true) }
            else { target = f.floats[0]; f.enter(mode) }
            f.press("toggle float"); f.focus(target)
            f.classification(target, "tiled", "moved to a rail")
            f.order([f.tiles[0], f.tiles[1], target, f.tiles[2]])
            f.state(mode == .pinnedLayer ? "pinned" : "hidden", focused: false)
            f.near(f.frame(target).width, presets[width] * (f.area.width + 10) - 10, "nearest nominal rail width")
            s.expect("the forced tile may stay shorter than the area", f.frame(target).height <= 300 && f.frame(target).height < f.area.height)
        })
        if mode != .shown || width != 0 { return }
        requireLayer(Scenario.run("a float creates a rail when none remain") { s in
            let f = LayerFixture(s, tileCount: 0, floatSpecs: [WindowSpec(subrole: "AXDialog")], startup: true, focusedFloat: true)
            let target = f.floats[0]
            s.expect("the all-floating workspace initially has no rail", f.tessel.status.railCount == 0)
            f.press("toggle float"); f.classification(target, "tiled", "moved to a rail"); f.focus(target)
            f.order([target]); s.expect("one rail is created", f.tessel.status.railCount == 1)
        })
    }

    @Test("#19 E22: a fixed-size float bounces without moving or leaving its layer state", arguments: [LayerMode.single, .shown, .pinnedLayer])
    func fixedSizeCannotBecomeATile(_ mode: LayerMode) {
        requireLayer(Scenario.run("fixed-size float in \(mode.rawValue)") { s in
            let spec = WindowSpec(resizable: false)
            let f = LayerFixture(s, floatSpecs: mode == .single ? [] : [spec], duration: 250)
            let target: UInt32
            if mode == .single { target = f.open(spec) }
            else { target = f.floats[0]; f.enter(mode) }
            let before = f.frames(f.tiles + [target]), railCount = f.tessel.status.railCount
            f.mac.clearMotionHistory()
            f.press("toggle float"); f.focus(target); f.unchanged(before)
            f.state(mode == .pinnedLayer ? "pinned" : mode.rawValue, focused: true)
            f.classification(target, "floats", "fixed size")
            s.expect("fixed-size transfer changes no rail", f.tessel.status.railCount == railCount && f.row(target)?.rail == nil)
            s.expect("fixed-size transfer performs no real geometry writes", f.mac.geometryWrites.isEmpty)
            s.expect("fixed-size transfer visibly bounces on the stage", f.mac.stageEvents.contains { if case .move = $0.kind { true } else { false } })
        })
    }

    @Test("#19 E23: manual classification survives catalog refreshes for the window lifetime and resets on restart", arguments: ["tile", "float"])
    func overridesLastOnlyForTheWindowLifetime(_ kind: String) {
        requireLayer(Scenario.run("classification override lifetime \(kind)") { s in
            let app = s.mac.launch()
            let tile = app.open(), natural = app.open(WindowSpec(subrole: "AXDialog"), background: true)
            app.select(tile)
            var t: Tessel? = Tessel(on: s.mac, text: LayerFixture.config)
            s.settle()
            let target = kind == "tile" ? tile : natural
            if kind == "float" { t!.press("toggle layer"); s.settle() }
            t!.press("toggle float"); s.settle()
            let state = kind == "tile" ? "floats" : "tiled", reason = kind == "tile" ? "moved to the layer" : "moved to a rail"
            for index in 0..<3 {
                let frame = s.mac.frame(target)!
                app.resize(target, to: CGSize(width: frame.width + 3, height: frame.height))
                s.settle()
                let row = t!.windows.first { $0.id == target }
                s.expect("refresh \(index) keeps the manual classification", row?.state.rawValue == state && row?.reason == reason)
            }
            t!.quit(); s.settle(); t = nil; s.settle()
            t = Tessel(on: s.mac, text: LayerFixture.config); s.settle()
            let row = t!.windows.first { $0.id == target }
            s.expect("restart returns to the native classification", row?.state.rawValue == (kind == "tile" ? "tiled" : "floats")
                     && row?.reason == (kind == "tile" ? "standard window" : "AXDialog"))
            t!.quit(); s.settle()
            t = nil
        })
    }
}

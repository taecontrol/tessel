import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerArrivals {
    @Test("#19 E12: a new float is shown alone, a later arrival replaces it, and sheets stay with their tile", arguments: [false, true])
    func singleArrivalReplacementCloseAndSheet(background: Bool) {
        requireLayer(Scenario.run("new floats replace single visibility and close back to rails, background=\(background)") { s in
            let f = LayerFixture(s)
            let before = f.frames(f.tiles), rail = f.tessel.status.rail
            let a = f.open(background: background)
            f.state("single", focused: true); f.focus(a); f.visible([a], true); f.visible(f.floats, false)
            f.unchanged(before)
            let b = f.open(WindowSpec(subrole: "AXFloatingWindow"), background: background)
            f.state("single", focused: true); f.focus(b); f.visible([b], true); f.visible(f.floats + [a], false)
            f.close(b); f.state("hidden", focused: false); f.focus(f.tiles[0]); f.visible(f.floats + [a], false)
            f.unchanged(before)
            s.expect("closing a single leaves the rail unchanged", f.tessel.status.rail == rail)
        })
        if background { return }
        requireLayer(Scenario.run("an attached sheet is never a new layer member") { s in
            let f = LayerFixture(s)
            let sheet = f.open(WindowSpec(subrole: "AXDialog", parent: f.tiles[0]))
            f.state("hidden", focused: false); f.visible(f.floats, false)
            s.expect("the sheet keeps native keyboard focus on the tile", f.mac.focusedWindow == sheet)
            s.expect("the sheet stays visible with its parent", f.mac.isVisible(sheet) && f.row(sheet)?.workspace == 1)
            f.press("toggle layer"); f.focus(f.floats[0])
            f.press("toggle layer")
            s.expect("returning to the rail selects the attached sheet", f.mac.focusedWindow == sheet && !f.mac.isInCloset(sheet))
        })
        requireLayer(Scenario.run("a pending failed-fill classification arrives after layer enabling", writes: .readsFirst) { s in
            let mac = s.mac, app = mac.launch()
            let tile = app.open(), oldFloat = app.open(WindowSpec(subrole: "AXFloatingWindow"), background: true)
            app.select(tile)
            let t = s.startTessel(.stack); s.settle()
            let constrained = app.open(WindowSpec(maximumSize: CGSize(width: 500, height: 300)))
            // Stack learns a failed fill after placement. Carousel normally
            // learns height bounds and keeps tiles; do not invent a different
            // classification rule just to exercise a late catalog transition.
            let learned = mac.pause(after: .call("SchedulingPort.after +100ms"))
            if case .paused = learned {} else { s.expect("the failed fill reaches its validation checkpoint: \(learned)", false); return }
            mac.scheduler.resume()
            let publishing = mac.pause(after: .call("MainLane.async"))
            if case .paused = publishing {} else { s.expect("the failed-fill snapshot is waiting to publish: \(publishing)", false); return }
            t.changeConfig(LayerFixture.config)
            let reloaded = mac.scheduler.run()
            if case .paused = reloaded {} else { s.expect("config reload runs while publication is held: \(reloaded)", false) }
            s.expect("the layer config is accepted before the classification arrives", t.configuration.error == nil)
            s.settle()
            let row = t.windows.first { $0.id == constrained }, layer = encodedObject(t.status)["layer"] as? [String: Any]
            s.expect("the late catalog transition is an actual constrained float", row?.state == .floats && row?.reason == "cannot fill the screen")
            s.expect("the newly classified float is shown alone", layer?["state"] as? String == "single" && layer?["focused"] as? Bool == true)
            s.expect("the constrained float owns visible keyboard focus", mac.focusedWindow == constrained && mac.isVisible(constrained) && !mac.isInCloset(constrained))
            s.expect("the earlier float stays hidden", mac.isInCloset(oldFloat) && !mac.isVisible(oldFloat))
        })
    }

    @Test("#19 E13: a single float can hide, expand and navigate in every direction, or pin the whole layer", arguments: ["toggle layer", "focus left", "focus down", "focus up", "focus right", "pin layer"])
    func singleBecomesAFullEntryOrReturnsToRails(_ command: String) {
        requireLayer(Scenario.run("single float followed by \(command)") { s in
            let f = LayerFixture(s), modal = f.open(WindowSpec(subrole: "AXDialog", resizable: false))
            f.state("single", focused: true); f.focus(modal)
            f.press(command)
            switch command {
            case "toggle layer":
                f.state("hidden", focused: false); f.focus(f.tiles[0]); f.visible(f.floats + [modal], false)
                s.expect("the hidden dialog remains alive in the closet until requested again", f.app.windows.contains(modal))
            case "pin layer":
                f.state("pinned", focused: true); f.focus(modal); f.visible(f.floats + [modal], true)
            default:
                f.state("shown", focused: true); f.visible(f.floats + [modal], true)
                f.focus(command == "focus left" || command == "focus up" ? f.floats[1] : f.floats[0])
                f.press("toggle layer"); f.state("hidden", focused: false); f.focus(f.tiles[0])
            }
        })
    }

    @Test("#19 E16: external float focus enters the entire layer and external tile focus exits according to pinning", arguments: LayerMode.allCases)
    func externalFocusAndVisibleArrivals(_ mode: LayerMode) {
        requireLayer(Scenario.run("external focus and new arrival in \(mode.rawValue)") { s in
            let f = LayerFixture(s)
            let single = f.enter(mode)
            let pinned = mode == .pinnedRails || mode == .pinnedLayer
            if mode == .hidden || mode == .single || mode == .pinnedRails {
                f.select(f.floats[1]); f.focus(f.floats[1]); f.visible(f.floats, true)
                if let single { f.visible([single], true) }
                f.state(pinned ? "pinned" : "shown", focused: true)
            }
            // New floats in shown or either pinned state stay in the full layer.
            // Return to pinned rails first to exercise that row separately.
            if mode == .pinnedRails { f.select(f.tiles[0]); f.state("pinned", focused: false) }
            let new = f.open(background: true)
            f.focus(new); f.visible(f.floats + [new], true)
            f.state(pinned ? "pinned" : "shown", focused: true)
            f.select(f.tiles[1]); f.focus(f.tiles[1])
            f.state(pinned ? "pinned" : "hidden", focused: false)
            f.visible(f.floats + [new], pinned)
            if let single, mode == .single { f.visible([single], pinned) }
            // A further native tile selection stays in the rails in both rows.
            f.select(f.tiles[0]); f.focus(f.tiles[0]); f.state(pinned ? "pinned" : "hidden", focused: false)
        })
        requireLayer(Scenario.run("external tile focus exits single without entering the rest") { s in
            let f = LayerFixture(s), single = f.open()
            f.select(f.tiles[0]); f.state("hidden", focused: false); f.visible(f.floats + [single], false); f.focus(f.tiles[0])
        })
    }
}

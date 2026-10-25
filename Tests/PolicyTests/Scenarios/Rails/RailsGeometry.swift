import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailGeometry {
    @Test("manual moves wait for a rail/workspace change, arrival or departure", arguments: ["rail", "workspace", "arrival", "close"])
    func redraw(trigger: String) {
        requireScenario(Scenario.run("manual move redraw via \(trigger)") { s in
            let f = RailFixture(s, widths: trigger == "scroll" ? Array(repeating: 0.45, count: 5) : [0.25, 0.25, 0.25])
            let moved = trigger == "scroll" ? f.ids[0] : f.ids[1], original = f.frame(moved)
            let point = CGPoint(x: original.minX + 23, y: original.minY + 17)
            f.app.drag(moved, to: point); s.settle()
            f.unchanged([moved], [CGRect(origin: point, size: original.size)])
            switch trigger {
            case "scroll": f.press("focus right", focus: f.ids[1]); f.press("focus right", focus: f.ids[2])
            case "rail":
                f.press("move down", focus: f.ids[0]); f.press("focus up", focus: f.ids[1])
            case "workspace":
                f.tessel.press("workspace 2"); s.settle(); f.press("workspace 1", focus: f.ids[0])
            case "arrival":
                _ = f.app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 150, height: 400))); s.settle()
                s.expect("the full-width arrival puts the manually moved tile out of view", !f.mac.isVisible(moved))
                // The full-width arrival hides the older tile; reveal it to
                // observe the logical geometry restored by the redraw.
                f.press("focus right", focus: moved)
            default: f.app.close(f.ids[2]); s.settle()
            }
            s.expect("the moved window is visible after the redraw", f.mac.isVisible(moved))
            f.near(f.frame(moved).minY, original.minY, "the redraw restores the logical top")
            let nominal = floor(f.area.width * 0.25)
            let expectedWidth = nominal
            f.near(f.frame(moved).width, expectedWidth, "redraw preserves the nominal width")
            f.near(f.frame(moved).height, original.height, "redraw retains height")
            let expectedX = trigger == "arrival" ? f.area.maxX - nominal
                : trigger == "rail" ? f.area.minX : trigger == "close" ? f.area.minX + nominal + 10 : original.minX
            f.near(f.frame(moved).minX, expectedX, "redraw restores the logical x")
        })
    }

    @Test("unsuccessful singleton moves leave manual geometry alone")
    func singletonMove() {
        requireScenario(Scenario.run("singleton move boundaries") { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0], b = f.ids[1]
            f.press("move down", focus: a)
            for (id, rail, boundary) in [(b, 1, "move up"), (a, 2, "move down")] {
                f.press(rail == 1 ? "focus up" : "focus down", focus: id)
                let original = f.frame(id)
                f.app.drag(id, to: CGPoint(x: original.minX + 23, y: original.minY + 17)); s.settle()
                let moved = f.frames(f.ids)
                for command in ["move left", "move right", boundary] {
                    f.press(command); f.unchanged(f.ids, moved)
                    s.expect("the manually positioned window keeps focus", f.mac.focusedWindow == id && f.mac.isVisible(id))
                }
                f.order([id], rail: rail)
            }
        })
    }

}

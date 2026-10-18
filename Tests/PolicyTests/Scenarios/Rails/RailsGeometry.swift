import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailGeometry {
    @Test("#17 E20: manual moves wait for a scroll, rail/workspace change, arrival or departure", arguments: ["scroll", "rail", "workspace", "arrival", "close"])
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
                f.press("move down", focus: f.ids[0]); f.press("focus up", focus: f.ids[2])
            case "workspace":
                f.tessel.press("workspace 2"); s.settle(); f.press("workspace 1", focus: f.ids[0])
            case "arrival": _ = f.app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 150, height: 400))); s.settle()
            default: f.app.close(f.ids[2]); s.settle()
            }
            s.expect("the moved window is visible after the redraw", f.mac.isVisible(moved))
            f.near(f.frame(moved).minY, original.minY, "the redraw restores the logical top")
            f.near(f.frame(moved).width, original.width, "redraw retains width")
            f.near(f.frame(moved).height, original.height, "redraw retains height")
            let expectedX = trigger == "arrival" ? original.minX + 160
                : trigger == "scroll" ? f.area.maxX - 56 - original.width - 2 * (original.width + 10)
                : trigger == "rail" ? f.area.minX : original.minX
            f.near(f.frame(moved).minX, expectedX, "redraw restores the logical x")
        })
    }

    @Test("#17 E9; #17 E20: a successful swap redraws a manual move even when ring targets coincide")
    func sameFrameSwap() {
        requireScenario(Scenario.run("short-ring swap redraw") { s in
            let f = RailFixture(s, widths: [0.6, 0.6]), a = f.ids[0], b = f.ids[1]
            f.press("focus right", focus: b); f.press("focus right", focus: a)
            let original = f.frame(a)
            f.near(original.minX, f.area.maxX - 56 - original.width, "worked swap starts at the reveal target")
            let moved = CGPoint(x: original.minX + 23, y: original.minY + 17)
            f.app.drag(a, to: moved); s.settle()
            f.unchanged([a], [CGRect(origin: moved, size: original.size)])
            f.press("move right", focus: a); f.order([b, a]); f.unchanged([a], [original])
        })
    }

    @Test("#17 E6; #17 E10; #17 E20: unsuccessful singleton moves leave manual geometry alone")
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

    @Test("#17 E21: manual resize adopts only the changed width and repositions its right neighbors", arguments: [false, true])
    func resize(ring: Bool) {
        requireScenario(Scenario.run("manual resize ring=\(ring)") { s in
            let f = RailFixture(s, widths: ring ? [0.6, 0.6] : [0.25, 0.25, 0.25]), ids = f.ids
            if ring {
                f.press("focus right", focus: ids[1])
                let before = f.frames(ids), narrow = floor(f.area.width * 0.3)
                f.app.resize(ids[1], to: CGSize(width: narrow, height: before[1].height)); s.settle()
                f.near(f.frame(ids[0]).minX, f.area.minX, "a newly fitting rail starts at the left")
                f.near(f.frame(ids[1]).minX, f.frame(ids[0]).maxX + 10, "narrowed tile follows its left neighbor")
                f.near(f.frame(ids[0]).width, before[0].width, "neighbor keeps width")
                f.press("focus left", focus: ids[0])
                let wide = floor(f.area.width * 0.8)
                f.app.resize(ids[0], to: CGSize(width: wide, height: before[0].height)); s.settle()
                f.near(f.frame(ids[0]).width, wide, "rail adopts the widened tile")
                f.near(f.frame(ids[1]).minX, f.area.minX + wide + 10, "right neighbor follows the new width")
                f.near(f.frame(ids[1]).width, narrow, "right neighbor retains its own width")
            } else {
                let before = f.frames(ids), changed = CGSize(width: before[1].width - 40, height: before[1].height)
                let traceStart = f.mac.scheduler.trace.count
                f.app.resize(ids[1], to: changed); s.settle()
                f.near(f.frame(ids[1]).width, changed.width, "rail adopts the resized width")
                f.near(f.frame(ids[2]).minX, f.frame(ids[1]).maxX + 10, "right neighbor closes the resized gap")
                f.unchanged([ids[0]], [before[0]])
                f.near(f.frame(ids[2]).width, before[2].width, "right neighbor is not resized")
                s.expect("adopting a width never writes AXSize", !f.mac.scheduler.trace.dropFirst(traceStart).contains { $0.contains("AccessibilityPort.set AXSize=") })
                f.tessel.press("workspace 2"); s.settle(); f.press("workspace 1", focus: ids[0])
                f.near(f.frame(ids[1]).width, changed.width, "the adopted width survives another render")
            }
        })
    }
}

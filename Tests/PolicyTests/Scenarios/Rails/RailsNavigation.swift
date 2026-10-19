import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailNavigation {
    @Test("fitting interior focus preserves every frame", arguments: WriteOrder.allCases)
    func fitting(order: WriteOrder) {
        requireScenario(Scenario.run("fitting traversal", writes: order) { s in
            let f = RailFixture(s), ids = f.ids
            let before = f.frames(ids)
            for id in [ids[1], ids[2]] { f.press("focus right", focus: id); f.unchanged(ids, before) }
            f.press("focus left", focus: ids[1]); f.unchanged(ids, before)
        })
    }

    @Test("visible focus retains manually moved frames", arguments: ["default", "alias", "external"])
    func visibleFocus(command: String) {
        requireScenario(Scenario.run("visible focus via \(command)") { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0], b = f.ids[1]
            if command == "alias" {
                f.tessel.changeConfig("[experiments]\ncarousel = true\n[keys]\nalt-a = 'focus next'\n")
                s.settle()
            }
            let before = f.frame(a)
            f.app.drag(a, to: CGPoint(x: before.minX + 23, y: before.minY + 17))
            s.settle()
            let moved = f.frames(f.ids)
            if command == "external" { f.select(b) }
            else { f.press(command == "alias" ? "focus next" : "focus right", focus: b) }
            f.unchanged(f.ids, moved)
        })
    }

    @Test("interior horizontal moves retain focus and preserve widths", arguments: [false, true])
    func horizontalMove(ring: Bool) {
        requireScenario(Scenario.run("horizontal swap ring=\(ring)") { s in
            let f = RailFixture(s, widths: ring ? [0.4, 0.2, 0.4, 0.4] : [0.3, 0.3, 0.3]), ids = f.ids
            let sizes = f.frames(ids).map(\.size)
            if ring {
                f.press("focus right", focus: ids[1]); f.press("focus right", focus: ids[2])
                let before = f.frame(ids[2])
                f.press("move left", focus: ids[2]); f.order([ids[0], ids[2], ids[1], ids[3]])
                f.near(f.frame(ids[1]).minX, before.minX, "swapped neighbor takes the previous x")
                f.near(f.frame(ids[2]).minX, before.minX - before.width - 10, "focused tile swaps left")
            } else {
                f.press("move right", focus: ids[0]); f.order([ids[1], ids[0], ids[2]])
                f.press("move left", focus: ids[0]); f.order(ids)
            }
            f.invariants(ids, sizes: sizes)
        })
    }

    @Test("vertical moves insert after memory, create rails, and remove empty rails")
    func verticalMove() {
        requireScenario(Scenario.run("vertical insertion") { s in
            let f = RailFixture(s), ids = f.ids
            f.press("move down", focus: ids[0]); f.order([ids[0]], rail: 2)
            f.order([ids[1], ids[2]])
            f.near(f.frame(ids[0]).minX, f.area.minX, "new rail starts at the left")
            f.press("focus up", focus: ids[1]); f.select(ids[2]); f.press("move down", focus: ids[2]); f.order([ids[0], ids[2]], rail: 2)
            f.press("move up", focus: ids[2]); f.order([ids[1], ids[2]])
            f.press("move up", focus: ids[2]); f.order([ids[2]])
            s.expect("moving above the first rail creates a third", f.tessel.status.railCount == 3)
            let before = f.frames(ids)
            f.press("move up", focus: ids[2]); f.unchanged(ids, before)
            f.press("focus down", focus: ids[1]); f.press("move down", focus: ids[1])
            f.order([ids[0], ids[1]], rail: 2); f.order([ids[2]])
            s.expect("the empty source rail disappears", f.tessel.status.railCount == 2)
        })
    }

    @Test("a vertical move inserts after memory before its existing right neighbor")
    func verticalAfterMemory() {
        requireScenario(Scenario.run("vertical move after remembered middle") { s in
            let f = RailFixture(s), ids = f.ids
            f.press("move down", focus: ids[0]); f.press("focus up", focus: ids[1]); f.select(ids[2])
            f.press("move down", focus: ids[2]); f.order([ids[0], ids[2]], rail: 2)
            f.press("focus left", focus: ids[0]); f.press("focus up", focus: ids[1])
            f.press("move down", focus: ids[1]); f.order([ids[0], ids[1], ids[2]])
            s.expect("moving the singleton removes its source rail", f.tessel.status.railCount == 1)
        })
    }

    @Test("directional input before the first catalog arrival is a no-op", arguments: WriteOrder.allCases)
    func beforeArrival(order: WriteOrder) {
        requireScenario(Scenario.run("input before first arrival", writes: order) { s in
            let tessel = s.startTessel(.carousel)
            s.settle()
            let app = s.mac.launch(windows: 1)
            for command in ["focus left", "focus right", "focus up", "focus down"] { tessel.press(command) }
            s.settle()
            s.expect("the first window is still selected", s.mac.focusedWindow == app.windows.first)
            s.expect("first arrival forms rail 1", tessel.windows.first?.rail == 1 && tessel.windows.first?.slot == 1)
            s.expect("rails remain enabled", tessel.status.enabled)
        })
    }
}

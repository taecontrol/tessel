import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailNavigation {
    @Test("#17 E4; #17 E6: fitting focus and wrap preserve every frame", arguments: WriteOrder.allCases)
    func fitting(order: WriteOrder) {
        requireScenario(Scenario.run("fitting traversal", writes: order) { s in
            let f = RailFixture(s), ids = f.ids
            let before = f.frames(ids)
            for id in [ids[1], ids[2], ids[0]] { f.press("focus right", focus: id); f.unchanged(ids, before) }
            f.press("focus left", focus: ids[2]); f.unchanged(ids, before)
        })
    }

    @Test("#17 E4; #17 E20: visible focus retains manually moved frames", arguments: ["default", "alias", "external"])
    func visibleFocus(command: String) {
        requireScenario(Scenario.run("visible focus via \(command)") { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0], b = f.ids[1]
            if command == "alias" {
                f.tessel.changeConfig("[experiments]\nrails = true\n[keys]\nalt-a = 'focus next'\n")
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

    @Test("#17 E5; #17 E6; #17 E27: ring reveal peeks, hides, wraps and never resizes", arguments: WriteOrder.allCases)
    func ring(order: WriteOrder) {
        requireScenario(Scenario.run("five-window ring", writes: order) { s in
            let f = RailFixture(s, widths: Array(repeating: 0.45, count: 5)), ids = f.ids
            let sizes = f.frames(ids).map(\.size), traceStart = f.mac.scheduler.trace.count
            for id in Array(ids.dropFirst()) + [ids[0]] {
                f.press("focus right", focus: id)
                f.invariants(ids, sizes: sizes)
            }
            let a = f.frame(ids[0]), b = f.frame(ids[1])
            f.near(a.maxX, f.area.maxX - 56, "focused right reveal edge")
            f.near(b.minX, f.area.maxX + 10 - 56, "next neighbor leaves a 56-point peek")
            s.expect("the opposite window is hidden", !f.mac.isVisible(ids[2]) && f.mac.isInCloset(ids[2]))
            let stable = f.frames(ids)
            f.press("focus left", focus: ids[4]); f.unchanged(ids, stable)
            f.press("focus left", focus: ids[3])
            f.near(f.frame(ids[3]).minX, f.area.minX + 56, "left reveal edge")
            f.invariants(ids, sizes: sizes)
            s.expect("traversal never writes AXSize", !f.mac.scheduler.trace.dropFirst(traceStart).contains { $0.contains("AccessibilityPort.set AXSize=") })
        })
    }

    @Test("#17 E5: short rings draw each neighbor at its most visible placement", arguments: [2, 3])
    func shortRing(count: Int) {
        requireScenario(Scenario.run("short ring \(count)") { s in
            let f = RailFixture(s, widths: Array(repeating: count == 2 ? 0.6 : 0.4, count: count)), ids = f.ids
            let sizes = f.frames(ids).map(\.size)
            for id in ids.dropFirst() { f.press("focus right", focus: id) }
            let width = f.frame(ids[0]).width, target = f.area.maxX - 56 - width
            let opposite = target + width + 10 - Double(count) * (width + 10)
            s.expect("worked neighbor exposes more on the opposite edge", opposite + width > 56)
            f.near(f.frame(ids.last!).minX, target, "short ring reveal target")
            f.near(f.frame(ids[0]).minX, opposite, "single most-visible neighbor placement")
            f.invariants(ids, sizes: sizes)
        })
    }

    @Test("#17 E5; #17 E6; #17 E10: wide windows center and singleton boundaries do nothing", arguments: [0.94, 1.0])
    func wideAndSingleton(width: Double) {
        requireScenario(Scenario.run("wide and singleton") { s in
            let f = RailFixture(s, widths: [0.3, width]), wide = f.ids[1]
            f.press("focus right", focus: wide)
            f.near(f.frame(wide).midX, f.area.midX, "wide window is centered")
            f.press("move down", focus: wide)
            f.order([wide], rail: 2)
            let before = f.frames(f.ids)
            for command in ["focus right", "focus left", "focus down", "move right", "move left", "move down"] {
                f.press(command, focus: wide); f.unchanged(f.ids, before)
                s.expect("no extra rail at the last singleton", f.tessel.status.railCount == 2)
            }
        })
    }

    @Test("#17 E7; #17 E8; #17 E27: elevator remembers focus and every x, and stops at both ends", arguments: WriteOrder.allCases)
    func elevator(order: WriteOrder) {
        requireScenario(Scenario.run("elevator memory", writes: order) { s in
            let f = RailFixture(s, widths: Array(repeating: 0.45, count: 5)), ids = f.ids
            f.press("move down", focus: ids[0]); f.order([ids[0]], rail: 2)
            f.press("focus up", focus: ids[4])
            f.press("focus right", focus: ids[1]); f.press("focus right", focus: ids[2]); f.press("focus right", focus: ids[3])
            f.press("focus right", focus: ids[4]); f.press("focus left", focus: ids[3])
            let before = f.frames(ids), sizes = before.map(\.size), traceStart = f.mac.scheduler.trace.count
            f.press("focus down", focus: ids[0])
            s.expect("every source tile is hidden", ids.dropFirst().allSatisfy { !f.mac.isVisible($0) })
            let bottom = f.frames(ids)
            f.press("focus down", focus: ids[0]); f.unchanged(ids, bottom)
            f.press("focus up", focus: ids[3]); f.unchanged(ids, before)
            f.press("focus up", focus: ids[3]); f.unchanged(ids, before)
            f.invariants(ids, sizes: sizes)
            s.expect("elevator never writes AXSize", !f.mac.scheduler.trace.dropFirst(traceStart).contains { $0.contains("AccessibilityPort.set AXSize=") })
        })
    }

    @Test("#17 E9: horizontal moves swap, wrap, retain focus and preserve widths", arguments: [false, true])
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
                f.press("move left", focus: ids[0]); f.order([ids[2], ids[1], ids[0]])
                f.press("move right", focus: ids[0]); f.order(ids)
            }
            f.invariants(ids, sizes: sizes)
        })
    }

    @Test("#17 E10; #17 E11: vertical moves insert after memory, create rails, and remove empty rails")
    func verticalMove() {
        requireScenario(Scenario.run("vertical insertion") { s in
            let f = RailFixture(s), ids = f.ids
            f.press("move down", focus: ids[0]); f.order([ids[0]], rail: 2)
            f.order([ids[1], ids[2]])
            f.near(f.frame(ids[0]).minX, f.area.minX, "new rail starts at the left")
            f.press("focus up", focus: ids[2]); f.press("move down", focus: ids[2]); f.order([ids[0], ids[2]], rail: 2)
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

    @Test("#17 E10: a vertical move inserts after memory before its existing right neighbor")
    func verticalAfterMemory() {
        requireScenario(Scenario.run("vertical move after remembered middle") { s in
            let f = RailFixture(s), ids = f.ids
            f.press("move down", focus: ids[0]); f.press("focus up", focus: ids[2])
            f.press("move down", focus: ids[2]); f.order([ids[0], ids[2]], rail: 2)
            f.press("focus left", focus: ids[0]); f.press("focus up", focus: ids[1])
            f.press("move down", focus: ids[1]); f.order([ids[0], ids[1], ids[2]])
            s.expect("moving the singleton removes its source rail", f.tessel.status.railCount == 1)
        })
    }

    @Test("#17 E6: directional input before the first catalog arrival is a no-op", arguments: WriteOrder.allCases)
    func beforeArrival(order: WriteOrder) {
        requireScenario(Scenario.run("input before first arrival", writes: order) { s in
            let tessel = s.startTessel(.rails)
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

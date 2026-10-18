import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailMembership {
    @Test("#17 E12; #17 E13: arrivals anchor the previous window and close selects left, closing the gap", arguments: [false, true])
    func arrivalAndClose(wrapped: Bool) {
        requireScenario(Scenario.run("arrival and close wrapped=\(wrapped)") { s in
            let f = RailFixture(s, widths: wrapped ? Array(repeating: 0.3, count: 5) : [0.22, 0.22]), ids = f.ids
            let anchor: UInt32
            if wrapped {
                for id in ids.reversed() { f.press("focus left", focus: id) }
                f.press("focus right", focus: ids[1]); anchor = ids[1]
            } else { anchor = ids[0] }
            let before = f.frame(anchor)
            var arrived: UInt32 = 0
            s.step("open a window to the right of focus") {
                arrived = f.app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: floor(f.area.width * (wrapped ? 0.1 : 0.22)), height: 400)))
            }
            s.settle(); f.focus(arrived)
            let index = ids.firstIndex(of: anchor)!
            f.order(Array(ids[...index]) + [arrived] + Array(ids.dropFirst(index + 1)))
            f.unchanged([anchor], [before])
            f.near(f.frame(arrived).minX, before.maxX + 10, "arrival is immediately right of focus")
            s.step("close the arrival") { f.app.close(arrived, selecting: ids.last) }
            s.settle(); f.focus(anchor); f.order(ids)
            f.unchanged([anchor], [before])
            f.near(f.frame(ids[index + 1]).minX, before.maxX + 10, "right neighbor closes the hole")
            if !wrapped {
                f.app.close(ids[0], selecting: ids[1]); s.settle(); f.focus(ids[1])
                f.app.close(ids[1]); s.settle()
                s.expect("closing the last window focuses Finder desktop", f.mac.frontmostApp == f.mac.finder.pid && f.mac.focusedWindow == nil)
                s.expect("the last rail disappears", f.tessel.status.railCount == 0 && f.tessel.windows.isEmpty)
            }
        })
    }

    @Test("#17 E12: a new background app's first window inserts after focus and takes focus", arguments: WriteOrder.allCases)
    func firstBackgroundWindow(order: WriteOrder) {
        requireScenario(Scenario.run("first window in a new app", writes: order) { s in
            let f = RailFixture(s, widths: [0.22, 0.22])
            let other = f.mac.launch(), b = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 220, height: 400)))
            f.app.select(f.ids[0])
            s.settle(); f.focus(b); f.order([f.ids[0], b, f.ids[1]])
            f.press("focus right", focus: f.ids[1])
        })
    }

    @Test("#17 E13: coalesced closes retain a surviving logical focus", arguments: [2, 3, 5, 8], WriteOrder.allCases)
    func coalescedCloses(count: Int, order: WriteOrder) {
        for reversed in [false, true] {
            requireScenario(Scenario.run("coalesced \(count) closes reversed=\(reversed)", writes: order) { s in
                let f = RailFixture(s, widths: Array(repeating: min(0.22, 0.8 / Double(count + 1)), count: count + 1)), ids = f.ids
                for id in ids.dropFirst().dropLast() { f.press("focus right", focus: id) }
                let closing = Array(ids.dropLast())
                s.step("close all but the survivor before publication") {
                    for id in reversed ? closing.reversed() : closing { f.app.close(id, selecting: ids.last) }
                }
                s.settle(); f.focus(ids.last!); f.order([ids.last!])
                f.press("send 2", focus: ids.last!); f.order([ids.last!], workspace: 2)
            })
        }
    }

    @Test("#17 E14; #17 E15: send follows, inserts after memory, and workspace return restores the current rail", arguments: [false, true])
    func send(rapid: Bool) {
        requireScenario(Scenario.run("send and return rapid=\(rapid)") { s in
            let f = RailFixture(s), ids = f.ids
            f.press("send 2", focus: ids[0]); f.order([ids[0]], workspace: 2)
            f.press("workspace 1", focus: ids[2])
            if rapid {
                s.step("send then swap before publication") { f.tessel.press("send 2"); f.tessel.press("move left") }
                s.settle(); f.focus(ids[2]); f.order([ids[2], ids[0]], workspace: 2)
                f.press("move right", focus: ids[2])
            } else { f.press("send 2", focus: ids[2]) }
            f.order([ids[0], ids[2]], workspace: 2)
            f.press("move down", focus: ids[2]); f.order([ids[2]], rail: 2, workspace: 2)
            let before = f.frames(ids)
            f.press("workspace 1", focus: ids[1]); f.press("workspace 2", focus: ids[2])
            f.unchanged(ids, before)
            s.expect("all other managed windows are hidden", !f.mac.isVisible(ids[0]) && !f.mac.isVisible(ids[1]))
        })
    }

    @Test("#17 E15: returning to a scrolled workspace restores all positions and hides other workspaces")
    func scrolledWorkspace() {
        requireScenario(Scenario.run("workspace scroll memory") { s in
            let f = RailFixture(s, widths: Array(repeating: 0.45, count: 5)), ids = f.ids
            f.press("send 2", focus: ids[0]); f.press("workspace 1", focus: ids[4])
            f.press("focus right", focus: ids[1]); f.press("focus right", focus: ids[2])
            f.press("focus right", focus: ids[3]); f.press("focus left", focus: ids[2])
            let before = f.frames(Array(ids.dropFirst()))
            f.press("workspace 2", focus: ids[0]); f.press("workspace 1", focus: ids[2])
            f.unchanged(Array(ids.dropFirst()), before)
            s.expect("other workspace stays hidden", !f.mac.isVisible(ids[0]))
        })
    }

    @Test("#17 E14: a send inserts after the destination's remembered window, before its right neighbor")
    func sendAfterMemory() {
        requireScenario(Scenario.run("send after destination memory") { s in
            let f = RailFixture(s, widths: [0.2, 0.2, 0.2, 0.2]), ids = f.ids
            f.press("send 2", focus: ids[0]); f.press("workspace 1", focus: ids[3])
            f.press("send 2", focus: ids[3]); f.order([ids[0], ids[3]], workspace: 2)
            f.press("focus left", focus: ids[0]); f.press("workspace 1", focus: ids[2])
            f.press("send 2", focus: ids[2]); f.order([ids[0], ids[2], ids[3]], workspace: 2)
        })
    }

    @Test("#17 E11; #17 E17: empty rails select adjacent on close/send and most recent on minimize/hide", arguments: ["close", "send", "minimize", "hide", "earlier-close"])
    func emptyRail(operation: String) {
        requireScenario(Scenario.run("empty rail via \(operation)") { s in
            let f = RailFixture(s, widths: [0.22, 0.22]), a = f.ids[0], b = f.ids[1]
            let other = f.mac.launch(), middle = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 220, height: 400)))
            s.settle(); f.focus(middle); f.order([a, middle, b])
            f.press("move down", focus: middle); f.press("focus up", focus: a)
            f.press("focus right", focus: b); f.press("move down", focus: b); f.press("move down", focus: b)
            f.press("focus up", focus: middle); f.press("focus up", focus: a); f.select(middle)
            f.order([a]); f.order([middle], rail: 2); f.order([b], rail: 3)
            s.step(operation) {
                switch operation {
                case "close": other.close(middle, selecting: a)
                case "send": f.tessel.press("send 2")
                case "minimize": other.minimize(middle, selecting: b)
                case "hide": other.hide(omitWindows: true)
                default: f.app.close(a)
                }
            }
            s.settle()
            if operation == "earlier-close" {
                f.focus(middle); f.order([middle]); f.order([b], rail: 2)
                s.expect("deleting an earlier rail retains the active rail", f.tessel.status.rail == 1 && f.tessel.status.railCount == 2)
            } else {
                if operation == "send" { f.press("workspace 1", focus: b) }
                else { f.focus(operation == "close" ? b : a) }
                f.order([a]); f.order([b], rail: 2)
                s.expect("the empty middle rail disappears", f.tessel.status.railCount == 2)
            }
        })
    }

    @Test("#17 E11: closing or sending the last rail selects the rail immediately above", arguments: [false, true])
    func emptyLastRail(send: Bool) {
        requireScenario(Scenario.run("empty last rail send=\(send)") { s in
            let f = RailFixture(s, widths: [0.22, 0.22]), a = f.ids[0], b = f.ids[1]
            let other = f.mac.launch(), middle = other.open(WindowSpec())
            s.settle(); f.press("move down", focus: middle); f.press("focus up", focus: a)
            f.press("focus right", focus: b); f.press("move down", focus: b); f.press("move down", focus: b)
            f.press("focus up", focus: middle); f.press("focus up", focus: a); f.select(b)
            if send { f.press("send 2", focus: b); f.press("workspace 1", focus: middle) }
            else { f.app.close(b, selecting: a); s.settle(); f.focus(middle) }
            f.order([a]); f.order([middle], rail: 2)
            s.expect("the preceding rail becomes the last active rail", f.tessel.status.rail == 2 && f.tessel.status.railCount == 2)
        })
    }

    @Test("#17 E17: minimize/hide restores after the former left neighbor, or after focus when its rail is gone", arguments: [false, true])
    func restore(hide: Bool) {
        requireScenario(Scenario.run("restore placement hide=\(hide)") { s in
            let f = RailFixture(s, widths: [0.22, 0.22, 0.22]), a = f.ids[0], c = f.ids[1], d = f.ids[2]
            let other = f.mac.launch(), b = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 220, height: 400)))
            s.settle(); f.focus(b); f.order([a, b, c, d])
            f.press("focus right", focus: c); f.press("focus left", focus: b)
            if hide { other.hide(omitWindows: true) } else { other.minimize(b, selecting: d) }
            s.settle(); f.focus(c); f.order([a, c, d])
            if hide { other.unhide() } else { other.restore(b) }
            s.settle(); f.focus(b); f.order([a, b, c, d])
            f.press("move down", focus: b); f.order([b], rail: 2)
            f.press("focus up", focus: a); f.press("focus left", focus: d); f.press("focus down", focus: b)
            other.minimize(b); s.settle(); f.focus(d)
            s.expect("minimizing the singleton removes its rail", f.tessel.status.railCount == 1)
            other.restore(b); s.settle(); f.focus(b); f.order([a, c, d, b])
        })
    }

    enum MinimizeStep: String, CaseIterable { case select, read, deliver, begin, complete }

    @Test("#17 E17: minimizing around an external-focus publication is never undone")
    func minimizeDuringExternalFocus() {
        let enumeration = SimulatedMac()
        let orders = enumeration.orders(of: MinimizeStep.allCases, requiring: [
            .init(.select, before: .read), .init(.read, before: .deliver),
            .init(.select, before: .begin), .init(.begin, before: .complete),
        ])
        enumeration.shutdown()
        for order in orders {
            requireScenario(Scenario.run("minimize around external focus", writes: order.writes) { s in
                let f = RailFixture(s, widths: [0.22, 0.22]), c = f.ids[1]
                let other = f.mac.launch(), b = other.open(WindowSpec())
                s.settle(); f.focus(b); f.press("focus right", focus: c)
                for step in order.steps {
                    s.step(step.rawValue) {
                        switch step {
                        case .select: other.select(b)
                        case .read:
                            let result = f.mac.pause(after: .read(other))
                            if case .paused = result {} else { s.expect("captured focus read: \(result)", false) }
                        case .deliver:
                            let result = f.mac.deliver(other)
                            if case .paused = result {} else { s.expect("published focus read: \(result)", false) }
                        case .begin: other.beginMinimize(b)
                        case .complete: other.finishMinimize(b, selecting: c)
                        }
                    }
                }
                s.settle()
                s.expect("native minimize remains in force", f.tessel.windows.first { $0.id == b }?.state == .minimized && !f.mac.isVisible(b))
                f.focus(c)
                other.restore(b); s.settle(); f.focus(b)
            })
        }
    }
}

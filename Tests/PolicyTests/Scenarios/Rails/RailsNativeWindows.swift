import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailNativeWindows {
    @Test("native activation before termination cannot replace the adjacent-rail landing", arguments: [false, true], WriteOrder.allCases)
    func termination(crash: Bool, order: WriteOrder) {
        for exitOrder in TerminationExitOrder.allCases {
            for earlyNotice in [false, true] {
                requireScenario(Scenario.run("termination crash=\(crash) earlyNotice=\(earlyNotice) exit=\(exitOrder.rawValue)", writes: order) { s in
                    let f = RailFixture(s, widths: [0.22, 0.22]), a = f.ids[0], b = f.ids[1]
                    let other = f.mac.launch(), middle = other.open(WindowSpec())
                    s.settle(); f.focus(middle)
                    f.press("move down", focus: middle); f.press("focus up", focus: a)
                    f.press("focus right", focus: b); f.press("move down", focus: b); f.press("move down", focus: b)
                    f.press("focus up", focus: middle); f.press("focus up", focus: a)
                    let dialog = f.app.open(WindowSpec(subrole: "AXDialog"))
                    s.settle(); f.focus(dialog); f.select(middle)
                    s.step("native termination promotes app-A") { other.terminate(activating: a, crash: crash, publishesNotification: earlyNotice, exitOrder: exitOrder) }
                    s.settle()
                    if !earlyNotice {
                        s.step("deliver termination after native activation facts") { other.publishTermination() }
                        s.settle()
                    }
                    f.focus(b); f.order([a]); f.order([b], rail: 2)
                    s.expect("the terminated app has no rows", !f.tessel.windows.contains { $0.id == middle })
                })
            }
        }
    }

    @Test("changed size limits stay tiled, align at the top and reposition the right neighbor", arguments: [false, true])
    func constraints(width: Bool) {
        requireScenario(Scenario.run("changed \(width ? "width" : "height") limit") { s in
            let f = RailFixture(s, widths: [0.5, 0.25]), a = f.ids[0], b = f.ids[1]
            let before = f.frame(a), limit = floor(width ? f.area.width * 0.3 : f.area.height / 2)
            f.app.limitSize(a, maximum: width ? CGSize(width: limit, height: 100_000) : CGSize(width: 100_000, height: limit))
            s.settle(); f.unchanged([a], [before])
            f.tessel.changeConfig("[experiments]\ncarousel = true\n[gaps]\nouter = 11\n")
            s.settle()
            let row = f.tessel.windows.first { $0.id == a }
            s.expect("the constrained window stays tiled", row?.state == .tiled && row?.rail == 1)
            f.near(f.frame(a).minY, f.area.minY + 1, "constraint aligns to the new rail top")
            if width {
                f.near(f.frame(a).width, limit, "accepted width respects the new maximum")
                f.near(f.frame(b).minX, f.frame(a).maxX + 11, "right neighbor follows the accepted width")
            } else {
                f.near(f.frame(a).height, limit, "accepted height respects the maximum")
                s.expect("the reason explains the height and alignment", row?.reason == "maximum height; aligned to top")
            }
            let limited = f.app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 480, height: 400),
                                                minimumSize: CGSize(width: 480, height: 1), maximumSize: CGSize(width: 480, height: 100_000)))
            s.settle(); f.focus(limited)
            f.near(f.frame(limited).width, 480, "a new width-limited window keeps its width")
            s.expect("the new constrained window is tiled", f.tessel.windows.first { $0.id == limited }?.rail == 1)
        })
    }

    @Test("visible focus never redraws a manually moved height-constrained window")
    func constrainedFocus() {
        requireScenario(Scenario.run("visible constrained window") { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0]
            f.app.limitSize(a, maximum: CGSize(width: 100_000, height: f.area.height / 2))
            f.tessel.changeConfig("[experiments]\ncarousel = true\n[gaps]\nouter = 11\n")
            s.settle()
            let original = f.frame(a)
            f.app.drag(a, to: CGPoint(x: original.minX + 23, y: original.minY + 17))
            s.settle()
            let moved = f.frames(f.ids)
            f.press("focus right", focus: f.ids[1]); f.unchanged(f.ids, moved)
        })
    }

    @Test("dialogs retain their frames, sheets follow parents, and native fullscreen never enters a rail")
    func specialWindows() {
        requireScenario(Scenario.run("dialogs sheets fullscreen") { s in
            let f = RailFixture(s, widths: [0.3]), parent = f.ids[0]
            let original = CGRect(x: 170, y: 120, width: 240, height: 180)
            let dialog = f.app.open(WindowSpec(frame: original, subrole: "AXDialog"))
            s.settle(); f.focus(dialog); f.unchanged([dialog], [original])
            s.expect("dialog belongs to the workspace and floats outside the rail", f.tessel.windows.first { $0.id == dialog }.map { $0.workspace == 1 && $0.rail == nil && $0.state == .floats } == true)
            f.press("send 2", focus: dialog); f.unchanged([dialog], [original])
            f.press("workspace 1", focus: parent)
            let sheet = f.app.open(WindowSpec(frame: CGRect(x: 100, y: 100, width: 200, height: 120), parent: parent))
            s.settle()
            f.tessel.press("send 3"); s.settle()
            s.expect("sheet and parent move to the same workspace", [parent, sheet].allSatisfy { id in f.tessel.windows.first { $0.id == id }?.workspace == 3 })
            s.expect("sheet follows parent visibility and has no rail", f.mac.isVisible(sheet) && f.tessel.windows.first { $0.id == sheet }?.rail == nil)
            f.tessel.press("workspace 1"); s.settle()
            s.expect("leaving hides both sheet and parent", !f.mac.isVisible(sheet) && !f.mac.isVisible(parent))
            f.tessel.press("workspace 3"); s.settle()
            s.expect("returning shows both sheet and parent", f.mac.isVisible(sheet) && f.mac.isVisible(parent))
            f.app.close(sheet); f.app.select(parent); s.settle()
            let before = f.frame(parent), traceStart = f.mac.scheduler.trace.count
            f.app.enterFullscreen(parent); s.settle()
            s.expect("fullscreen has no workspace or rail", f.tessel.windows.first { $0.id == parent }.map { $0.state == .fullscreen && $0.workspace == nil && $0.rail == nil } == true)
            f.unchanged([parent], [before])
            s.expect("fullscreen is never resized or positioned", !f.mac.scheduler.trace.dropFirst(traceStart).contains { $0.contains("set AX") && $0.contains("window \(parent) ") })
            f.app.leaveFullscreen(parent); s.settle()
        })
    }

    @Test("native tab replacement keeps rail, slot, width and remembered focus", arguments: ["ordinary", "background", "suspended-neighbor", "suspended-root", "detached"])
    func nativeTabs(mode: String) {
        requireScenario(Scenario.run("native tab replacement \(mode)") { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0], b = f.ids[1]
            let tabs = f.mac.launch(), first = tabs.open(WindowSpec()), next = tabs.open(WindowSpec())
            tabs.groupTabs([first, next], selected: first)
            s.settle(); f.focus(first); f.order([a, first, b])
            if mode == "detached" {
                tabs.detachTab(first); s.settle()
                f.order([a, first, next, b]); f.focus(next)
                s.expect("both detached windows are ordinary roots", f.tessel.windows.filter { [first, next].contains($0.id) }.allSatisfy { $0.tabs == 1 })
                f.press("focus left", focus: first); f.press("move down", focus: first)
                f.press("focus up", focus: a); f.press("focus down", focus: first)
                return
            }
            if mode == "suspended-root" {
                f.press("focus right", focus: b); f.press("focus left", focus: first)
                tabs.minimize(first, selecting: b); s.settle(); f.focus(b)
                f.press("move down", focus: b)
                tabs.restore(next); s.settle(); f.focus(next)
                f.order([a, next]); f.order([b], rail: 2)
                return
            }
            if mode == "suspended-neighbor" {
                f.press("focus right", focus: b)
                f.app.minimize(b, selecting: first); s.settle(); f.focus(first)
                tabs.selectTab(next); s.settle(); f.focus(next); f.order([a, next])
                f.press("focus left", focus: a)
                f.app.restore(b); s.settle(); f.focus(b); f.order([a, next, b])
                return
            }
            f.press("move down", focus: first); f.order([first], rail: 2)
            f.press("focus up", focus: a)
            tabs.selectTab(next)
            if mode == "background" { f.app.select(a) }
            s.settle(); f.order([next], rail: 2)
            s.expect("the former native root is retired", !f.tessel.windows.contains { $0.id == first })
            f.near(f.frame(next).width, f.area.width, "the replacement retains its nominal full arrival width (#49 E1-E3)")
            if mode == "background" { f.focus(a); f.press("focus down", focus: next) }
            else {
                f.focus(next); f.press("focus up", focus: a); f.press("focus right", focus: b)
                f.press("focus down", focus: next)
            }
            f.press("move up", focus: next)
            f.near(f.frame(next).width, f.area.width, "the replacement retains its nominal full width when rejoining the source rail (#49 E14)")
        })
    }

    @Test("an unpublished native successor finishes only the still-current presentation", arguments: [false, true])
    func unpublishedSuccessor(external: Bool) {
        requireScenario(Scenario.run("unpublished tab successor external=\(external)") { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0]
            let tabs = f.mac.launch(), first = tabs.open(WindowSpec()), next = tabs.open(WindowSpec())
            tabs.groupTabs([first, next], selected: first)
            s.settle(); f.press("move down", focus: first); f.press("focus up", focus: a)
            var externalID: UInt32?
            if external {
                let third = f.mac.launch(), id = third.open(WindowSpec())
                s.settle(); f.press("send 3", focus: id); f.press("workspace 1", focus: a)
                externalID = id
            }
            tabs.publishWindows([first]); tabs.publishFocus(false)
            tabs.selectTab(next); f.app.select(a)
            s.settle()
            s.expect("the old listed root has lost its native bar", f.tessel.windows.first { $0.id == first }?.tabs == 1)
            f.tessel.press("focus down"); s.settle()
            s.expect("the destination rail is selected while the root is unpublished", f.tessel.status.rail == 2)
            s.expect("the former root was never reselected", f.mac.focusedWindow != first)
            if let externalID { f.select(externalID) }
            tabs.publishFocus(true); s.settle()
            f.order([next], rail: 2)
            s.expect("the former native root retires when its successor is published", !f.tessel.windows.contains { $0.id == first })
            if let externalID {
                f.focus(externalID)
                s.expect("newer external activation keeps its workspace", f.tessel.status.active == 3)
                f.press("workspace 1", focus: next)
            } else { f.focus(next) }
        })
    }
}

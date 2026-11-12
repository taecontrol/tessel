import CoreGraphics
import Foundation
import Ports
import Simulator
import Testing
@testable import Policy

/// While the screen is locked, macOS answers every window as closed
/// (locked-session-windows). No read made then may change what tessel knows.
@Suite @MainActor struct FoundationLockedSession {
    /// Windows 0 and 1 on rail 1, window 3 alone on rail 2, window 2 on
    /// workspace 2. Window 1 is at half width; the others are full width.
    private func fixture(_ s: Scenario) -> CarouselFixture {
        let f = CarouselFixture(s, presets: [1, 0.5, 1, 1], duration: 0, appCount: 2)
        f.select(f.ids[3]); f.press("move down")
        f.select(f.ids[2]); f.press("send 2")
        f.select(f.ids[1])
        let rows = f.tessel.windows
        s.expect("setup places a window on rail 2", rows.contains { $0.id == f.ids[3] && $0.workspace == 1 && $0.rail == 2 })
        s.expect("setup places a window on workspace 2", rows.contains { $0.id == f.ids[2] && $0.workspace == 2 })
        f.near(f.frame(f.ids[1]).width, f.width(0.5), "setup keeps window 1 at half width")
        return f
    }

    private func membership(_ f: CarouselFixture) -> [String] {
        f.tessel.windows.map { row in
            "\(row.id) \(row.state.rawValue) workspace=\(row.workspace.map(String.init) ?? "none")"
                + " rail=\(row.rail.map(String.init) ?? "none") slot=\(row.slot.map(String.init) ?? "none")"
        }
    }

    private func widths(_ f: CarouselFixture) -> [CGFloat] { f.ids.map { f.frame($0).width } }

    private func click(_ f: CarouselFixture) {
        f.s.step("click") { f.mac.pointerDown(); f.mac.pointerUp() }
    }

    private func windowReads(_ f: CarouselFixture, since start: Int) -> [String] {
        f.mac.scheduler.trace[start...].filter { $0.contains("AccessibilityPort.copy") || $0.contains("AccessibilityPort.windowID") }
    }

    @Test("#69 E1: a mouse release under a locked screen reads nothing and keeps every window's workspace, rail, slot and width",
          arguments: WriteOrder.allCases)
    func lockedReadChangesNothing(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#69 locked read / \(writes)", writes: writes) { s in
            let f = fixture(s)
            let rows = membership(f), sizes = widths(f)
            s.step("lock") { f.mac.lockScreen() }
            let locked = f.mac.scheduler.trace.count
            click(f)
            s.settle()
            s.expect("the windows keep their workspace, rail and slot: \(membership(f))", membership(f) == rows)
            s.expect("the windows keep their widths: \(widths(f))", widths(f) == sizes)
            s.expect("no Accessibility read is made under the lock: \(windowReads(f, since: locked).prefix(3))",
                     windowReads(f, since: locked).isEmpty)
            s.step("unlock") { f.mac.unlockScreen() }
            let unlocked = f.mac.scheduler.trace.count
            s.settle()
            s.expect("the unlock rereads both apps", f.apps.allSatisfy { app in
                f.mac.scheduler.trace[unlocked...].contains { $0.contains("AccessibilityPort.copy AXWindows \(app.alias)") }
            })
            s.expect("the windows are where they were after the unlock: \(membership(f))", membership(f) == rows)
            s.expect("the widths are what they were after the unlock: \(widths(f))", widths(f) == sizes)
        })
    }

    /// Where the lock falls inside a read that the session reported unlocked
    /// when it began.
    enum LockPoint: String, CaseIterable, Sendable {
        /// Before the first answer: the whole read describes closed windows.
        case beforeFirstAnswer
        /// After a truthful window list: the handles then answer as closed.
        case afterWindowList
        /// After the read was committed, before its focus is read for publication.
        case afterCommit
    }

    @Test("#69 E2: a read the lock interrupts changes nothing",
          arguments: LockPoint.allCases.flatMap { point in WriteOrder.allCases.map { (point, $0) } })
    func interruptedReadChangesNothing(_ point: LockPoint, _ writes: WriteOrder) {
        requireCarousel(Scenario.run("#69 interrupted read / \(point.rawValue) / \(writes)", writes: writes) { s in
            let f = fixture(s)
            let rows = membership(f), sizes = widths(f)
            let app = f.apps[0]
            s.after(milliseconds: 0, "click") { f.mac.pointerDown(); f.mac.pointerUp() }
            let name = "\(app.alias) pid=\(app.pid)"
            var held: RunOutcome
            switch point {
            case .beforeFirstAnswer: held = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(name)"))
            case .afterWindowList: held = f.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(name)"))
            case .afterCommit:
                // The read asks for the focused window once before committing
                // and once more to publish.
                held = f.mac.pause(after: .call("AccessibilityPort.copy AXFocusedWindow \(name)"))
                if case .paused = held { held = f.mac.pause(after: .call("AccessibilityPort.copy AXFocusedWindow \(name)")) }
            }
            if case .paused = held {} else { s.expect("the read is held at \(point.rawValue): \(held)", false) }
            s.expect("the read began with the session unlocked", !f.mac.isScreenLocked)
            s.step("lock") { f.mac.lockScreen() }
            s.settle()
            s.expect("the windows keep their workspace, rail and slot: \(membership(f))", membership(f) == rows)
            s.expect("the windows keep their widths: \(widths(f))", widths(f) == sizes)
            s.step("unlock") { f.mac.unlockScreen() }
            s.settle()
            s.expect("the windows are where they were after the unlock: \(membership(f))", membership(f) == rows)
            s.expect("the widths are what they were after the unlock: \(widths(f))", widths(f) == sizes)
        })
    }

    @Test("#69 E3: after the unlock a window closed under the lock is retired and one opened under it joins",
          arguments: WriteOrder.allCases)
    func unlockRereadsEveryApp(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("#69 unlock reread / \(writes)", writes: writes) { s in
            let f = fixture(s)
            let rows = membership(f)
            let closed = f.ids[0]
            s.step("lock") { f.mac.lockScreen() }
            var opened: UInt32 = 0
            s.step("close and open under the lock") {
                f.apps[0].close(closed)
                opened = f.apps[1].open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 451, height: 400), positionAcceptance: .screenEdges),
                                        background: true)
            }
            s.settle()
            s.expect("nothing changes while the screen is locked: \(membership(f))", membership(f) == rows)
            s.step("unlock") { f.mac.unlockScreen() }
            s.settle()
            let after = f.tessel.windows
            s.expect("the closed window is retired: \(membership(f))", !after.contains { $0.id == closed })
            s.expect("the opened window joins the active workspace: \(membership(f))",
                     after.contains { $0.id == opened && $0.workspace == f.tessel.status.active && $0.state == .tiled })
            let kept = Set(f.ids).subtracting([closed])
            s.expect("the other windows keep their workspace: \(membership(f))", kept.allSatisfy { id in
                after.first { $0.id == id }?.workspace == (id == f.ids[2] ? 2 : 1)
            })
        })
    }
}

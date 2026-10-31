import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailOrderingRegressions {
    @Test("#2 E25: a queued raise never restores a window minimized while AXMain returns", arguments: [Layout.carousel], MinimizedRaiseReply.allCases)
    func minimizeBetweenFocusWrites(_ layout: Layout, _ reply: MinimizedRaiseReply) {
        for writes in WriteOrder.allCases {
            requireScenario(Scenario.run("minimize between focus writes in \(layout), reply=\(reply)", writes: writes) { s in
                let mac = s.mac, app = mac.launch(windows: 1)
                let id = app.open(WindowSpec(minimizedRaiseReply: reply))
                app.select(1)
                let tessel = s.startTessel(layout)
                s.settle()
                tessel.press(layout == .carousel ? "focus right" : "focus next")
                let held = mac.pause(after: .call("AccessibilityPort.set AXMain=true window \(id) \(app.alias)"))
                if case .paused = held {} else { s.expect("the main write is outstanding: \(held)", false) }
                // Pause after AXMain takes effect, before its reply can return.
                // A timer could instead run during the later minimize recheck.
                mac.scheduler.resume()
                let returning = mac.pause(after: .call("MainLane.async native event"))
                if case .paused = returning {} else { s.expect("the main write is returning: \(returning)", false) }
                s.expect("the main write selected the window before minimization", mac.focusedWindow == id)
                app.minimize(id, selecting: 1)
                s.settle()
                s.expect("native minimize remains in force", tessel.windows.first { $0.id == id }?.state == .minimized && !mac.isVisible(id))
                s.expect("the minimized window keeps its workspace", tessel.windows.first { $0.id == id }?.workspace == 1)
                s.expect("the available successor is selected and visible", mac.focusedWindow == 1 && mac.isFullyOnScreen(1))
            })
        }
    }

    @Test("a raise that times out on a pending minimize follows the window macOS restores", arguments: [Layout.carousel])
    func raiseDuringPendingMinimize(_ layout: Layout) {
        for writes in WriteOrder.allCases {
            requireScenario(Scenario.run("raise during pending minimize in \(layout)", writes: writes) { s in
                let mac = s.mac, app = mac.launch(windows: 1)
                let id = app.open(WindowSpec(pendingMinimizeRaise: .restoresAfterMinimize))
                app.select(1)
                let tessel = s.startTessel(layout)
                s.settle()
                tessel.press("focus right")
                let held = mac.pause(after: .call("AccessibilityPort.set AXMain=true window \(id) \(app.alias)"))
                if case .paused = held {} else { s.expect("the main write is outstanding: \(held)", false) }
                mac.scheduler.resume()
                let returning = mac.pause(after: .call("MainLane.async native event"))
                if case .paused = returning {} else { s.expect("the main write is returning: \(returning)", false) }
                app.beginMinimize(id)
                mac.scheduler.resume()
                let raised = mac.pause(after: .call("AccessibilityPort.perform AXRaise window \(id) \(app.alias)"))
                if case .paused = raised {} else { s.expect("the raise lands on the pending minimization: \(raised)", false) }
                mac.scheduler.resume()
                let answered = mac.pause(after: .call("AccessibilityPort.copy AXFrontmost \(app.alias) pid=\(app.pid)"))
                if case .paused = answered {} else { s.expect("the raise has answered: \(answered)", false) }
                // The Dock completes the minimization before tessel can retry.
                app.finishMinimize(id, selecting: 1)
                s.expect("the timed-out raise left the minimization to complete", !mac.isVisible(id))
                s.settle()
                s.expect("the restored window is tiled again", tessel.windows.first { $0.id == id }?.state == .tiled)
                s.expect("the restored window keeps its workspace", tessel.windows.first { $0.id == id }?.workspace == 1)
                s.expect("the restored window is selected and visible", mac.focusedWindow == id && mac.isFullyOnScreen(id))
            })
        }
    }

    @Test("a gap redraw cannot discard a pending cross-app native selection")
    func ownerReadSurvivesGapReload() {
        requireScenario(Scenario.run("owner revalidation across gap redraw", writes: .readsFirst) { s in
            let f = RailFixture(s, widths: [0.25]), a = f.ids[0]
            let other = f.mac.launch(), b = other.open(WindowSpec())
            s.settle(); f.press("move down", focus: b); f.press("focus up", focus: a)
            other.activate()
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXRole window \(a) \(f.app.alias)"))
            if case .paused = held {} else { s.expect("owner revalidation is outstanding: \(held)", false) }
            f.tessel.changeConfig("[experiments]\ncarousel = true\n[gaps]\nouter = 11\n")
            let independent = f.mac.scheduler.run()
            if case .paused = independent {} else { s.expect("the gap redraw runs while owner AX is held: \(independent)", false) }
            s.expect("the gap reload completes before revalidation answers", f.tessel.status.gaps.outer == 11)
            s.settle(); f.focus(b)
            s.expect("external activation selects its hidden rail after a nonfocusing redraw", f.tessel.status.rail == 2)
            s.expect("the source rail is hidden", !f.mac.isVisible(a))
        })
    }

    private func initialBackground(_ s: Scenario, fraction: Double) -> (Tessel, Simulator.SimulatedApp, [UInt32], UInt32) {
        let mac = s.mac, app = mac.launch(), area = WorkspaceScenarios.area(mac)
        let ids = (0..<2).map { _ in app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: floor(area.width * fraction), height: 400))) }
        app.select(ids[0])
        let background = mac.launch(), c = background.open(WindowSpec(), background: true)
        let tessel = s.startTessel(text: "[animation]\nduration = 0\n")
        let held = mac.pause(after: .call("AccessibilityPort.copy AXWindows \(background.alias) pid=\(background.pid)"))
        if case .paused = held {} else { s.expect("initial background enumeration is held", false) }
        _ = mac.scheduler.run()
        s.expect("the front app is known before background discovery", Set(tessel.windows.map(\.id)) == Set(ids))
        mac.scheduler.resume()
        return (tessel, app, ids, c)
    }

    @Test("late initial enumeration cannot re-expand after a reorder")
    func lateInitialEnumerationAfterMove() {
        requireScenario(Scenario.run("initial background read across keyboard reorder", writes: .readsFirst) { s in
            let (t, app, ids, c) = initialBackground(s, fraction: 0.5)
            t.press("move right")
            let held = s.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(app.alias) pid=\(app.pid)"))
            if case .paused = held {} else { s.expect("the keyboard presentation is outstanding", false) }
            _ = s.mac.scheduler.run()
            s.expect("background discovery publishes while keyboard AX waits", t.windows.contains { $0.id == c })
            s.settle()
            s.expect("the reorder retains native focus", s.mac.focusedWindow == ids[0])
            let order = t.windows.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }.map(\.id)
            s.expect("initial discovery preserves the completed reorder", order == [ids[1], ids[0], c])
            s.expect("the reordered tile stays complete", s.mac.isFullyOnScreen(ids[0]))
        })
    }

    @Test("#2 E2: background discovery preserves an outstanding keyboard selection")
    func initialBackgroundReadPreservesKeyboardFocus() {
        requireScenario(Scenario.run("initial background read across keyboard focus", writes: .readsFirst) { s in
            let (t, app, ids, c) = initialBackground(s, fraction: 0.25)
            t.press("focus right")
            let held = s.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(app.alias) pid=\(app.pid)"))
            if case .paused = held {} else { s.expect("the keyboard presentation is outstanding", false) }
            _ = s.mac.scheduler.run()
            s.expect("background discovery publishes before the focus write", t.windows.contains { $0.id == c })
            s.expect("the old focus remains while its worker waits", s.mac.focusedWindow == ids[0])
            s.settle()
            s.expect("initial discovery preserves the keyboard destination", s.mac.focusedWindow == ids[1] && s.mac.isFullyOnScreen(ids[1]))
            s.expect("the destination stays on workspace one", t.status.active == 1)
        })
    }
}

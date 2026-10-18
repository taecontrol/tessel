import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailOrderingRegressions {
    @Test("#2 E25; #17 E17: a queued raise never restores a window minimized while AXMain returns", arguments: [Layout.stack, .rails], MinimizedRaiseReply.allCases)
    func minimizeBetweenFocusWrites(_ layout: Layout, _ reply: MinimizedRaiseReply) {
        for writes in WriteOrder.allCases {
            requireScenario(Scenario.run("minimize between focus writes in \(layout), reply=\(reply)", writes: writes) { s in
                let mac = s.mac, app = mac.launch(windows: 1)
                let id = app.open(WindowSpec(minimizedRaiseReply: reply))
                app.select(1)
                let tessel = s.startTessel(layout)
                s.settle()
                tessel.press(layout == .rails ? "focus right" : "focus next")
                let held = mac.pause(after: .call("AccessibilityPort.set AXMain=true window \(id) \(app.alias)"))
                if case .paused = held {} else { s.expect("the main write is outstanding: \(held)", false) }
                mac.scheduler.main.after(milliseconds: 1) {
                    s.expect("the main write selected the window before minimization", mac.focusedWindow == id)
                    app.minimize(id, selecting: 1)
                }
                s.settle()
                s.expect("native minimize remains in force", tessel.windows.first { $0.id == id }?.state == .minimized && !mac.isVisible(id))
                s.expect("the minimized window keeps its workspace", tessel.windows.first { $0.id == id }?.workspace == 1)
                s.expect("the available successor is selected and visible", mac.focusedWindow == 1 && mac.isFullyOnScreen(1))
            })
        }
    }

    @Test("#17 E16: a gap redraw cannot discard a pending cross-app native selection")
    func ownerReadSurvivesGapReload() {
        requireScenario(Scenario.run("owner revalidation across gap redraw", writes: .readsFirst) { s in
            let f = RailFixture(s, widths: [0.25]), a = f.ids[0]
            let other = f.mac.launch(), b = other.open(WindowSpec())
            s.settle(); f.press("move down", focus: b); f.press("focus up", focus: a)
            other.activate()
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXRole window \(a) \(f.app.alias)"))
            if case .paused = held {} else { s.expect("owner revalidation is outstanding: \(held)", false) }
            f.tessel.changeConfig("[experiments]\nrails = true\n[gaps]\nouter = 11\n")
            let independent = f.mac.scheduler.run()
            if case .paused = independent {} else { s.expect("the gap redraw runs while owner AX is held: \(independent)", false) }
            s.expect("the gap reload completes before revalidation answers", f.tessel.status.gaps.outer == 11)
            s.settle(); f.focus(b)
            s.expect("external activation selects its hidden rail after a nonfocusing redraw", f.tessel.status.rail == 2)
            s.expect("the source rail is hidden", !f.mac.isVisible(a))
        })
    }

    @Test("#2 E2; #17 E2: background discovery preserves an outstanding keyboard selection", arguments: [Layout.stack, .rails])
    func initialBackgroundReadPreservesKeyboardFocus(layout: Layout) {
        requireScenario(Scenario.run("initial background read across keyboard focus in \(layout)", writes: .readsFirst) { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0], b = f.ids[1]
            f.tessel.configure(.off); s.settle()
            let background = f.mac.launch()
            let c = background.open(WindowSpec(), background: true)
            f.tessel.configure(layout)
            f.tessel.press(layout == .rails ? "focus right" : "focus next")
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(f.app.alias) pid=\(f.app.pid)"))
            if case .paused = held {} else { s.expect("the keyboard presentation is outstanding: \(held)", false) }
            let independent = f.mac.scheduler.run()
            if case .paused = independent {} else { s.expect("the background snapshot runs while keyboard AX is held: \(independent)", false) }
            s.expect("the background application's initial window is published", f.tessel.windows.contains { $0.id == c })
            s.expect("the keyboard focus write has not executed yet", f.mac.focusedWindow == a)
            s.settle(); f.focus(b)
            s.expect("initial discovery keeps the keyboard destination's workspace", f.tessel.status.active == 1)
        })
    }

}

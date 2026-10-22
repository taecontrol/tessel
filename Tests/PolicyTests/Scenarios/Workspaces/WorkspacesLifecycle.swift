import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct WorkspaceLifecycle {
    @Test("#2 E15: close never follows native focus into another workspace; deliberate selection still does",
          arguments: [false, true], WriteOrder.allCases)
    func closeFocus(last: Bool, writes: WriteOrder) {
        for readBeforeClose in [false, true] {
            let result = Scenario.run("close last=\(last), read-before-close=\(readBeforeClose)", writes: writes) { scenario in
                let app = scenario.mac.launch(windows: last ? 2 : 3)
                let sent: UInt32 = last ? 2 : 3
                let tessel = scenario.startTessel(.carousel)
                scenario.settle()
                WorkspaceScenarios.press(scenario, tessel, "send 3", shown: sent)
                WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: last ? 1 : 2)
                if !last { WorkspaceScenarios.press(scenario, tessel, "focus left", shown: 1) }
                scenario.step(readBeforeClose ? "close during the focused-window read" : "close before the read") {
                    if readBeforeClose {
                        app.select(1)
                        let outcome = scenario.mac.pause(after: .call("AccessibilityPort.copy AXFocusedWindow app-A pid=100"))
                        if case .paused = outcome {} else { scenario.expect("in-flight read reached: \(outcome)", false) }
                    }
                    app.close(1, selecting: sent)
                }
                scenario.settle()
                scenario.expect("closing retains workspace 1", tessel.status.active == 1)
                scenario.expect("the closed row is retired", WorkspaceScenarios.row(tessel, 1) == nil)
                if last { WorkspaceScenarios.empty(scenario) }
                else { WorkspaceScenarios.shown(scenario, 2) }
                scenario.step("user deliberately selects the hidden window after close") { app.select(sent) }
                scenario.settle()
                scenario.expect("deliberate selection follows workspace 3", tessel.status.active == 3)
                WorkspaceScenarios.shown(scenario, sent)
            }
            requireScenario(result)
        }
    }

    @Test("#2 E16: plain activation rescues hidden focus, including an attached sheet", arguments: [false, true])
    func externalActivation(sheet: Bool) {
        requireScenario(Scenario.run("external activation, sheet=\(sheet)") { scenario in
            _ = scenario.mac.launch(windows: 1)
            let other = scenario.mac.launch(windows: 1)
            let attached: UInt32? = sheet ? other.open(WindowSpec(subrole: "AXDialog", parent: 2)) : nil
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 2, sheet: attached)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: 1)
            scenario.step("activate app-B without ordering its closeted window") { other.activate() }
            scenario.expect("plain activation alone leaves the focus hidden", scenario.mac.focusedWindow == (attached ?? 2) && !scenario.mac.isVisible(2))
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 2, sheet: attached)
            scenario.expect("activation rescues workspace 3", tessel.status.active == 3)
            if let attached { scenario.expect("the attached sheet is visible", scenario.mac.isVisible(attached)) }
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: 1)
            other.activate()
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 2, sheet: attached)
        })
    }

    @Test("#2 E16: failed or cancelled presentations release focus intent for actual external activation", arguments: [false, true])
    func failedPresentation(cancelled: Bool) {
        requireScenario(Scenario.run("presentation failure, cancelled=\(cancelled)", writes: .readsFirst) { scenario in
            let app = scenario.mac.launch(windows: 2)
            let empty = scenario.mac.launch()
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 2", shown: 2)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: 1)
            WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 1)
            scenario.step("app hangs before a focus presentation can complete") {
                app.hang()
                tessel.press("workspace 2")
                if cancelled { tessel.press("workspace 1") }
            }
            scenario.settle()
            scenario.expect("the requested destination remains selected", tessel.status.active == (cancelled ? 1 : 2))
            scenario.expect("the failed presentation did not focus window 2", app.focusedWindow == 1)
            app.resume()
            empty.activate()
            scenario.settle()
            scenario.expect("read recovery does not acknowledge an unperformed focus", tessel.status.active == (cancelled ? 1 : 2))
            // #33 E18 keeps the old view until the replacement is ready.
            // A failed destination never becomes visible or receives focus.
            scenario.expect("the failed destination stays in the closet", !scenario.mac.isVisible(2))
            scenario.step("external activation explicitly selects the actual hidden focus") { app.activate(); app.select(1) }
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 1)
            scenario.expect("external activation rescues workspace 3", tessel.status.active == 3)
        })
    }

    @Test("#2 E17: activating an app whose focused window is here keeps the current workspace")
    func activationHere() {
        requireScenario(Scenario.run("activation here") { scenario in
            let (app, tessel) = WorkspaceScenarios.split(scenario)
            let empty = scenario.mac.launch()
            empty.activate()
            scenario.settle()
            app.activate()
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 1)
            scenario.expect("activation stays on workspace 1", tessel.status.active == 1)
        })
    }

    @Test("#2 E18: activating a windowless app does not switch workspace")
    func activationWindowless() {
        requireScenario(Scenario.run("windowless activation") { scenario in
            let (_, tessel) = WorkspaceScenarios.split(scenario)
            let empty = scenario.mac.launch()
            empty.activate()
            scenario.settle()
            scenario.expect("windowless activation keeps workspace 1", tessel.status.active == 1)
            scenario.expect("windowless app remains frontmost", scenario.mac.frontmostApp == empty.pid)
            scenario.expect("the selected workspace's window remains visible", scenario.mac.isVisible(1))
        })
    }

    @Test("#2 E25: minimize chooses a recent window or desktop and restore returns", arguments: [false, true])
    func minimize(last: Bool) {
        requireScenario(Scenario.run("minimize, last=\(last)") { scenario in
            let app = scenario.mac.launch(windows: last ? 1 : 2)
            let id: UInt32 = last ? 1 : 2
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            app.minimize(id, selecting: last ? nil : 1)
            scenario.settle()
            if last { WorkspaceScenarios.empty(scenario) } else { WorkspaceScenarios.shown(scenario, 1) }
            scenario.expect("minimized window keeps workspace 1", WorkspaceScenarios.row(tessel, id)?.workspace == 1)
            scenario.expect("minimized state is published", WorkspaceScenarios.row(tessel, id)?.state == .minimized)
            app.restore(id)
            scenario.settle()
            WorkspaceScenarios.shown(scenario, id)
            scenario.expect("restoration returns to workspace 1", tessel.status.active == 1)
        })
    }

    @Test("#2 E25: restoring from another workspace returns to the minimized window's workspace")
    func restoreElsewhere() {
        requireScenario(Scenario.run("restore across workspaces") { scenario in
            let (app, tessel) = WorkspaceScenarios.split(scenario)
            WorkspaceScenarios.press(scenario, tessel, "workspace 2", shown: 2)
            app.minimize(2)
            scenario.settle()
            WorkspaceScenarios.empty(scenario)
            let c = app.open()
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 1", shown: c)
            app.restore(2)
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 2)
            scenario.expect("restoration returns to the original workspace 2", tessel.status.active == 2 && WorkspaceScenarios.row(tessel, 2)?.workspace == 2)
            scenario.expect("the other workspace remains hidden", !scenario.mac.isVisible(1) && !scenario.mac.isVisible(c))
        })
    }

    @Test("#2 E26: hide chooses a recent window or desktop and reactivation returns", arguments: [false, true])
    func hide(last: Bool) {
        requireScenario(Scenario.run("hide, last=\(last)") { scenario in
            if !last { _ = scenario.mac.launch(windows: 1) }
            let app = scenario.mac.launch(windows: 1)
            let id = app.windows[0]
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            app.hide(omitWindows: true)
            scenario.settle()
            if last { WorkspaceScenarios.empty(scenario) } else { WorkspaceScenarios.shown(scenario, 1) }
            scenario.expect("the omitted hidden row retains membership", WorkspaceScenarios.row(tessel, id)?.workspace == 1 && WorkspaceScenarios.row(tessel, id)?.state == .hidden)
            app.activate()
            scenario.settle()
            WorkspaceScenarios.shown(scenario, id)
        })
    }

    @Test("#2 E26: unhide uses the app's actual focus across its windows' workspaces")
    func unhideFocus() {
        requireScenario(Scenario.run("unhide actual focus") { scenario in
            let (app, tessel) = WorkspaceScenarios.split(scenario)
            WorkspaceScenarios.press(scenario, tessel, "workspace 2", shown: 2)
            WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 2)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: 1)
            app.hide(omitWindows: true)
            scenario.settle()
            WorkspaceScenarios.empty(scenario)
            scenario.expect("all hidden windows retain their workspaces", WorkspaceScenarios.row(tessel, 1)?.workspace == 1 && WorkspaceScenarios.row(tessel, 2)?.workspace == 3)
            let foreground = scenario.mac.launch(windows: 1)
            let c = foreground.windows[0]
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 2", shown: c)
            app.activate()
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 1)
            scenario.expect("unhide follows focused window 1", tessel.status.active == 1)
            scenario.expect("the other window retains its hidden workspace", !scenario.mac.isVisible(2) && WorkspaceScenarios.row(tessel, 2)?.workspace == 3)
        })
    }

    @Test("#2 E27: fullscreen has no workspace, keeps its frame and visibility, and cannot send a closeted sibling", arguments: [false, true])
    func fullscreen(transientRoot: Bool) {
        requireScenario(Scenario.run("native fullscreen, auxiliary root=\(transientRoot)") { scenario in
            let app = scenario.mac.launch(windows: 2)
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            let frame = scenario.mac.frame(2)
            let auxiliary = app.beginFullscreenTransition(2, publishingRoot: transientRoot)
            app.enterFullscreen(2)
            scenario.settle()
            scenario.expect("fullscreen has explicit nil membership", WorkspaceScenarios.row(tessel, 2)?.state == .fullscreen && WorkspaceScenarios.row(tessel, 2)?.workspace == nil)
            scenario.expect("fullscreen remains visible and focused", scenario.mac.isVisible(2) && scenario.mac.focusedWindow == 2)
            scenario.expect("fullscreen is not resized", scenario.mac.frame(2) == frame)
            scenario.expect("the sibling stays closeted", !scenario.mac.isVisible(1))
            let checkpoint = scenario.mac.scheduler.trace.count
            WorkspaceScenarios.press(scenario, tessel, "send 2")
            scenario.expect("a fullscreen send is ignored", tessel.status.active == 1 && WorkspaceScenarios.row(tessel, 1)?.workspace == 1)
            scenario.expect("fullscreen retains its frame and focus", scenario.mac.frame(2) == frame && scenario.mac.focusedWindow == 2)
            scenario.expect("no hide or AX write targets fullscreen", !scenario.mac.scheduler.trace.dropFirst(checkpoint).contains { $0.contains("ClosetPort.hide windows=[2") || $0.contains("AccessibilityPort.set") })
            app.finishFullscreenTransition(2)
            scenario.settle()
            if let auxiliary { scenario.expect("the completed transition retires its auxiliary root before fullscreen exit", WorkspaceScenarios.row(tessel, auxiliary) == nil) }
            scenario.expect("completing the transition retains fullscreen focus and state", scenario.mac.focusedWindow == 2 && WorkspaceScenarios.row(tessel, 2)?.state == .fullscreen)
            app.leaveFullscreen(2)
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 2)
            scenario.expect("fullscreen exit rejoins workspace 1", WorkspaceScenarios.row(tessel, 2)?.workspace == 1)
        })
    }

    @Test("#2 E30: a hung app keeps its CLI row and cannot block another app's workspace switch")
    func hungApp() {
        requireScenario(Scenario.run("hung app switching") { scenario in
            let (app, tessel) = WorkspaceScenarios.split(scenario)
            let hung = scenario.mac.launch(windows: 1)
            let h = hung.windows[0]
            scenario.settle()
            WorkspaceScenarios.shown(scenario, h)
            app.select(1)
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 1)
            hung.hang()
            hung.activate()
            app.activate()
            var switchCompleted = false
            scenario.step("switch with an unrelated AX timeout in flight") { tessel.press("workspace 2") }
            scenario.mac.scheduler.main.after(milliseconds: 499) {
                switchCompleted = scenario.mac.focusedWindow == 2 && scenario.mac.isVisible(2)
                scenario.expect("CLI reads retain the hung app's complete row", WorkspaceScenarios.row(tessel, h) != nil)
            }
            scenario.settle()
            scenario.expect("switch completes independently of read retries", switchCompleted)
            WorkspaceScenarios.shown(scenario, 2)
            scenario.expect("the hung app remains observable", WorkspaceScenarios.row(tessel, h)?.workspace == 1)
        })
    }
}

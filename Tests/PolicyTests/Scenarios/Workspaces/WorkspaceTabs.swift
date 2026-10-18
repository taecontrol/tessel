import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct WorkspaceNativeTabs {
    @Test("#2 E12: selecting or inserting a native tab preserves arrival, membership, hidden intent and focus history",
          arguments: [false, true], WriteOrder.allCases)
    func replacement(inserting: Bool, writes: WriteOrder) {
        requireScenario(Scenario.run("native front replacement, inserting=\(inserting)", writes: writes) { scenario in
            let mac = scenario.mac
            let app = mac.launch(windows: 1)
            let tessel = scenario.startTessel(.stack)
            scenario.settle()
            let first = app.open(), second = app.open(), third = app.open()
            app.groupTabs([first, second, third], selected: first)
            scenario.settle()
            WorkspaceScenarios.shown(scenario, first)
            scenario.expect("native group has one three-tab row", tessel.windows.count == 2 && WorkspaceScenarios.row(tessel, first)?.tabs == 3)
            let c = app.open()
            scenario.settle()
            WorkspaceScenarios.shown(scenario, c)
            WorkspaceScenarios.press(scenario, tessel, "focus previous", shown: first)
            let replacement: UInt32
            if inserting { replacement = app.addTab(to: first) }
            else { replacement = second; app.selectTab(replacement) }
            scenario.settle()
            scenario.expect("replacement inherits membership without an extra row", tessel.windows.count == 3 && WorkspaceScenarios.row(tessel, replacement)?.workspace == 1)
            scenario.expect("replacement reports the native count", WorkspaceScenarios.row(tessel, replacement)?.tabs == (inserting ? 4 : 3))
            WorkspaceScenarios.shown(scenario, replacement)
            WorkspaceScenarios.press(scenario, tessel, "focus next", shown: c)
            WorkspaceScenarios.press(scenario, tessel, "focus previous", shown: replacement)

            let foreground = mac.launch(windows: 1)
            let d = foreground.windows[0]
            scenario.settle()
            WorkspaceScenarios.shown(scenario, d)
            WorkspaceScenarios.press(scenario, tessel, "send 2", shown: d)
            let background: UInt32
            if inserting { background = app.addTab(to: first, activating: false) }
            else { background = third; app.selectTabInBackground(background) }
            scenario.settle()
            scenario.expect("background front keeps workspace 1 and one group row", tessel.windows.count == 4 && WorkspaceScenarios.row(tessel, background)?.workspace == 1)
            scenario.expect("background replacement stays hidden", !mac.isVisible(background))
            scenario.expect("background replacement does not switch workspaces", tessel.status.active == 2)
            WorkspaceScenarios.shown(scenario, d)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: background)
            WorkspaceScenarios.press(scenario, tessel, "send 3", shown: background)
            for _ in 0..<4 {
                WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: c)
                WorkspaceScenarios.press(scenario, tessel, "workspace 3", shown: background)
            }
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: c)
            scenario.expect("sent native group stays hidden after returning", !mac.isVisible(background))
            let hidden: UInt32
            if inserting { hidden = app.addTab(to: first) }
            else { hidden = first; app.selectTab(hidden) }
            scenario.settle()
            scenario.expect("hidden group's selected front retains workspace 3", tessel.windows.count == 4 && WorkspaceScenarios.row(tessel, hidden)?.workspace == 3)
            scenario.expect("external native selection returns to workspace 3", tessel.status.active == 3)
            WorkspaceScenarios.shown(scenario, hidden)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: c)
            scenario.expect("replacement hides on return", !mac.isVisible(hidden))
        })
    }
}

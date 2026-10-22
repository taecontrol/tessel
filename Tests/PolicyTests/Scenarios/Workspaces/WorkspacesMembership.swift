import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct WorkspaceMembership {
    @Test("#2 E4: workspace shortcuts hide, fill and focus in both directions")
    func switchBothWays() {
        requireScenario(Scenario.run("switch both ways") { scenario in
            let (_, tessel) = WorkspaceScenarios.split(scenario)
            for (workspace, id, hidden) in [(2, UInt32(2), UInt32(1)), (1, UInt32(1), UInt32(2))] {
                WorkspaceScenarios.press(scenario, tessel, "workspace \(workspace)", shown: id)
                scenario.expect("workspace \(workspace) is active", tessel.status.active == workspace)
                scenario.expect("window \(hidden) is hidden", !scenario.mac.isVisible(hidden))
            }
        })
    }

    @Test("#2 E5: the workspace-ten command selects and sends to workspace ten")
    func workspaceTen() {
        requireScenario(Scenario.run("workspace ten") { scenario in
            _ = scenario.mac.launch(windows: 2)
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 10", shown: 2)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: 1)
            WorkspaceScenarios.press(scenario, tessel, "workspace 10", shown: 2)
            scenario.expect("window 2 belongs to workspace 10", WorkspaceScenarios.row(tessel, 2)?.workspace == 10)
            scenario.expect("workspace 10 is active", tessel.status.active == 10)
            scenario.expect("Option+0 resolves to workspace 10", tessel.status.keys["alt-0"] == "workspace 10")
        })
    }

    @Test("#2 E6; #2 E9: selecting or sending to the current workspace is a no-op", arguments: [false, true])
    func currentWorkspace(send: Bool) {
        requireScenario(Scenario.run("current workspace, send=\(send)") { scenario in
            let app = scenario.mac.launch(windows: 1)
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            app.drag(1, to: CGPoint(x: 110, y: 130))
            app.resize(1, to: CGSize(width: 420, height: 280))
            scenario.settle()
            let frame = scenario.mac.frame(1)
            let checkpoint = scenario.mac.scheduler.trace.count
            WorkspaceScenarios.press(scenario, tessel, send ? "send 1" : "workspace 1")
            scenario.expect("the manually set frame is unchanged", scenario.mac.frame(1) == frame)
            scenario.expect("no presentation was requested", !scenario.mac.scheduler.trace.dropFirst(checkpoint).contains { $0.contains("AccessibilityPort.set") || $0.contains("AXRaise") })
            scenario.expect("membership is unchanged", WorkspaceScenarios.row(tessel, 1)?.workspace == 1)
        })
    }

    @Test("#2 E7: an empty workspace activates only a safe Finder desktop", arguments: [false, true])
    func emptyWorkspace(ordinaryFinderWindow: Bool) {
        requireScenario(Scenario.run("empty workspace, Finder window=\(ordinaryFinderWindow)") { scenario in
            let mac = scenario.mac
            if ordinaryFinderWindow { _ = mac.finder.open() }
            let app = mac.launch(windows: 1)
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "workspace 8")
            scenario.expect("workspace 8 is active", tessel.status.active == 8)
            scenario.expect("all managed windows are hidden", mac.visibleOrder.isEmpty)
            scenario.expect("Finder activation obeys its desktop guard", mac.frontmostApp == (ordinaryFinderWindow ? app.pid : mac.finder.pid))
        })
    }

    @Test("#2 E10: sending a dialog preserves its frame")
    func sendDialog() {
        requireScenario(Scenario.run("send dialog") { scenario in
            let app = scenario.mac.launch(windows: 1)
            let dialog = app.open(WindowSpec(subrole: "AXDialog"))
            let frame = scenario.mac.frame(dialog)
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            WorkspaceScenarios.shown(scenario, dialog, floating: true)
            WorkspaceScenarios.press(scenario, tessel, "send 4", shown: dialog, floating: true)
            scenario.expect("the dialog belongs to workspace 4", WorkspaceScenarios.row(tessel, dialog)?.workspace == 4)
            scenario.expect("sending preserves its original frame", scenario.mac.frame(dialog) == frame)
        })
    }

    @Test("#2 E11: sending the last window leaves the source workspace empty")
    func sendLastWindow() {
        requireScenario(Scenario.run("send last window") { scenario in
            _ = scenario.mac.launch(windows: 1)
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 1)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1")
            WorkspaceScenarios.empty(scenario)
        })
    }

    @Test("#2 E24: attached sheets share their parent's workspace, visibility and send")
    func attachedSheet() {
        requireScenario(Scenario.run("sheet ownership") { scenario in
            let app = scenario.mac.launch(windows: 1)
            let sheet = app.open(WindowSpec(subrole: "AXDialog", parent: 1))
            let tessel = scenario.startTessel(.carousel)
            scenario.settle()
            scenario.expect("sheet starts visible", scenario.mac.isVisible(sheet))
            let other = app.open()
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 2", shown: other)
            scenario.expect("parent and sheet hide together", !scenario.mac.isVisible(1) && !scenario.mac.isVisible(sheet))
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: 1, sheet: sheet)
            scenario.expect("sheet returns with its parent", scenario.mac.isVisible(sheet))
            scenario.expect("sheet belongs to the parent's workspace", WorkspaceScenarios.row(tessel, sheet)?.workspace == WorkspaceScenarios.row(tessel, 1)?.workspace)
            WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 1, sheet: sheet)
            scenario.expect("sending a focused sheet moves both rows", WorkspaceScenarios.row(tessel, sheet)?.workspace == 3 && WorkspaceScenarios.row(tessel, 1)?.workspace == 3)
            scenario.expect("the sent sheet remains visible", scenario.mac.isVisible(sheet))
        })
    }
}

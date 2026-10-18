import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct WorkspaceGeometry {
    @Test("#2 E19: tiles fill the visible frame with the configured gap and tolerate one point", arguments: [0.0, 10.0])
    func filled(gap: Double) {
        for onePointShort in [false, true] {
            requireScenario(Scenario.run("fill gap=\(gap), one-point-short=\(onePointShort)") { scenario in
                let app = scenario.mac.launch()
                let target = WorkspaceScenarios.area(scenario.mac, gap: gap)
                let spec = WindowSpec(maximumSize: CGSize(width: 100_000, height: onePointShort ? target.height - 1 : 100_000))
                let id = app.open(spec)
                let tessel = scenario.startTessel()
                scenario.settle()
                tessel.changeConfig(WorkspaceScenarios.enabled + "[gaps]\nouter = \(gap)\n")
                scenario.settle()
                WorkspaceScenarios.shown(scenario, id, gap: gap)
                scenario.expect("one-point readback remains tiled", WorkspaceScenarios.row(tessel, id)?.state == .tiled)
                scenario.expect("fill is not classified as constrained", WorkspaceScenarios.row(tessel, id)?.reason.contains("cannot fill") == false)
                if onePointShort { scenario.expect("the one-point constraint was exercised", scenario.mac.frame(id)?.height == target.height - 1) }
            })
        }
    }

    @Test("#2 E20: successful width clamping floats centered on every show, including native front replacement", arguments: [false, true])
    func constrained(nativeTabs: Bool) {
        requireScenario(Scenario.run("width-clamped window, native tabs=\(nativeTabs)") { scenario in
            let app = scenario.mac.launch()
            var id = app.open(WindowSpec(maximumSize: CGSize(width: 500, height: 100_000)))
            var replacement: UInt32?
            if nativeTabs {
                replacement = app.open(WindowSpec(maximumSize: CGSize(width: 500, height: 100_000)))
                app.groupTabs([id, replacement!], selected: id)
            }
            let tessel = scenario.startTessel(.stack)
            scenario.settle()
            scenario.expect("initial clamping is explained", WorkspaceScenarios.row(tessel, id)?.reason == "cannot fill the screen")
            if let replacement { app.selectTab(replacement); id = replacement; scenario.settle() }
            for workspace in [1, 2, 1] {
                if workspace != tessel.status.active { WorkspaceScenarios.press(scenario, tessel, "send \(workspace)") }
                WorkspaceScenarios.shown(scenario, id, floating: true)
                let frame = scenario.mac.frame(id) ?? .zero
                let area = WorkspaceScenarios.area(scenario.mac)
                scenario.expect("the width constraint was accepted", frame.width == 500 && frame.width < area.width - 100)
                scenario.expect("the constrained frame is centered", abs(frame.midX - area.midX) <= 1 && abs(frame.midY - area.midY) <= 1)
                scenario.expect("every show retains float classification and workspace", WorkspaceScenarios.row(tessel, id)?.state == .floats && WorkspaceScenarios.row(tessel, id)?.reason == "cannot fill the screen" && WorkspaceScenarios.row(tessel, id)?.workspace == workspace)
            }
        })
    }

    @Test("#2 E20: a constrained float stays above the workspace's tile")
    func constrainedAboveTile() {
        requireScenario(Scenario.run("constrained float above tile") { scenario in
            let app = scenario.mac.launch(windows: 1)
            let tessel = scenario.startTessel(.stack)
            scenario.settle()
            let limited = app.open(WindowSpec(maximumSize: CGSize(width: 500, height: 100_000)))
            scenario.settle()
            WorkspaceScenarios.shown(scenario, limited, floating: true)
            scenario.expect("the constrained window floats with an explanation", WorkspaceScenarios.row(tessel, limited)?.state == .floats && WorkspaceScenarios.row(tessel, limited)?.reason == "cannot fill the screen")
            scenario.expect("the original tile remains visible underneath", scenario.mac.isVisible(1) && scenario.mac.visibleOrder.first == limited)
        })
    }

    @Test("#2 E21: manual frames survive tab selection, app termination and dialog churn until shown again", arguments: [false, true])
    func manualFrame(nativeTabs: Bool) {
        requireScenario(Scenario.run("manual frame, native tabs=\(nativeTabs)") { scenario in
            let app = scenario.mac.launch(windows: 2)
            var id: UInt32 = 1
            var replacement: UInt32?
            if nativeTabs { replacement = app.open(); app.groupTabs([1, replacement!], selected: 1); app.select(2) }
            let tessel = scenario.startTessel(.stack)
            scenario.settle()
            WorkspaceScenarios.press(scenario, tessel, "send 2", shown: 2)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: id)
            let frame = CGRect(x: 120, y: 130, width: 430, height: 290)
            app.drag(id, to: frame.origin); app.resize(id, to: frame.size)
            scenario.settle()
            if let replacement { app.selectTab(replacement); id = replacement; scenario.settle() }
            let empty = scenario.mac.launch()
            empty.quit()
            scenario.settle()
            scenario.expect("the manual frame survives unrelated termination and native selection", scenario.mac.frame(id) == frame)
            let dialog = app.open(WindowSpec(subrole: "AXDialog"))
            scenario.settle()
            WorkspaceScenarios.shown(scenario, dialog, floating: true)
            scenario.expect("opening a dialog keeps the tile's frame", scenario.mac.frame(id) == frame)
            app.close(dialog, selecting: id)
            scenario.settle()
            scenario.expect("closing the dialog keeps the tile's frame", scenario.mac.frame(id) == frame)
            WorkspaceScenarios.press(scenario, tessel, "workspace 2", shown: 2)
            WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: id)
        })
    }

    @Test("#2 E22: an oversized gap centers the constrained window on the display")
    func oversizedGap() {
        requireScenario(Scenario.run("oversized gap") { scenario in
            let app = scenario.mac.launch()
            let id = app.open(WindowSpec(minimumSize: CGSize(width: 100, height: 80)))
            let tessel = scenario.startTessel()
            scenario.settle()
            tessel.changeConfig(WorkspaceScenarios.enabled + "[gaps]\nouter = 10000\n")
            scenario.settle()
            let frame = scenario.mac.frame(id) ?? .zero
            let display = WorkspaceScenarios.area(scenario.mac, gap: 0)
            scenario.expect("minimum size prevents filling the oversized-gap area", WorkspaceScenarios.row(tessel, id)?.state == .floats && WorkspaceScenarios.row(tessel, id)?.reason == "cannot fill the screen")
            scenario.expect("the accepted frame stays centered on the display", abs(frame.midX - display.midX) <= 1 && abs(frame.midY - display.midY) <= 1)
        })
    }

    @Test("#2 E22: gap reload lays out only the visible window until switching")
    func gapReload() {
        requireScenario(Scenario.run("gap reload") { scenario in
            let (_, tessel) = WorkspaceScenarios.split(scenario)
            let hiddenFrame = scenario.mac.frame(2)
            tessel.changeConfig(WorkspaceScenarios.enabled + "[gaps]\nouter = 20\n")
            scenario.settle()
            WorkspaceScenarios.shown(scenario, 1, gap: 20)
            scenario.expect("hidden frame does not change on reload", scenario.mac.frame(2) == hiddenFrame)
            WorkspaceScenarios.press(scenario, tessel, "workspace 2")
            WorkspaceScenarios.shown(scenario, 2, gap: 20)
        })
    }
}

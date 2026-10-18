import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FoundationLifecycle {
    @Test("#1 E7: a background creation publishes before 500 virtual ms and stays classified for twenty queries", arguments: WriteOrder.allCases)
    func created(_ writes: WriteOrder) {
        requireScenario(Scenario.run("background creation notification", writes: writes) { scenario in
            let mac = scenario.mac
            let app = mac.launch(windows: 1)
            let tessel = scenario.startTessel()
            scenario.settle()
            let start = mac.scheduler.now
            let id = app.open(background: true)
            scenario.after(milliseconds: 500, "twenty queries after the creation deadline") {
                FoundationProof.row(id, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
                let expected = FoundationProof.snapshot(tessel.windows)
                for _ in 0..<20 { scenario.expect("classification stays identical across twenty queries", FoundationProof.snapshot(tessel.windows) == expected) }
            }
            scenario.settle()
            scenario.expect("a background open keeps the anchor focused", mac.focusedWindow == 1)
            FoundationProof.publication(tessel, pid: app.pid, since: start, within: 500, scenario: scenario) {
                $0.contains { $0.id == id && $0.state == .tiled && $0.reason == "standard window" }
            }
            let later = tessel.windowPublications.filter { $0.pid == app.pid && $0.at >= start + 500 }
            scenario.expect("later settling never changes the new classification", later.allSatisfy {
                $0.windows?.contains { $0.id == id && $0.state == .tiled && $0.reason == "standard window" } == true
            })
        })
    }

    @Test("#1 E8: a background close with a retained AX handle and an app quit publish before 500 virtual ms", arguments: WriteOrder.allCases)
    func closedAndQuit(_ writes: WriteOrder) {
        requireScenario(Scenario.run("destruction and termination notifications", writes: writes) { scenario in
            let mac = scenario.mac
            let app = mac.launch(windows: 1)
            let tessel = scenario.startTessel()
            scenario.settle()
            let id = app.open(background: true)
            scenario.settle()
            FoundationProof.row(id, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
            app.publishNextWindowLists(Array(repeating: .includingClosed([id]), count: 20))
            let closedAt = mac.scheduler.now
            scenario.step("close the background window without a focus notification") { app.close(id) }
            scenario.settle()
            scenario.expect("only the live anchor remains", tessel.windows.map(\.id) == [1])
            FoundationProof.publication(tessel, pid: app.pid, since: closedAt, within: 500, scenario: scenario) { !$0.contains { $0.id == id } }
            let other = mac.launch(windows: 2)
            scenario.settle()
            let otherIDs = Set(other.windows)
            scenario.expect("setup: the second app has two published windows", Set(tessel.windows.map(\.id)).isSuperset(of: otherIDs) && otherIDs.count == 2)
            let quitAt = mac.scheduler.now
            scenario.step("quit the second app") { other.quit() }
            scenario.settle()
            scenario.expect("termination removes every second-app row", Set(tessel.windows.map(\.id)).isDisjoint(with: otherIDs))
            FoundationProof.publication(tessel, pid: other.pid, since: quitAt, within: 500, scenario: scenario) { $0.isEmpty }
            FoundationProof.row(1, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
        })
    }

    @Test("#1 E21: AX timeouts retain all classifications while other apps open and close", arguments: WriteOrder.allCases)
    func hungApp(_ writes: WriteOrder) {
        requireScenario(Scenario.run("one app hangs while another remains responsive", writes: writes) { scenario in
            let mac = scenario.mac
            let app = mac.launch(windows: 2)
            app.open(WindowSpec(resizable: false))
            app.open(WindowSpec(subrole: "AXDialog"))
            app.open(WindowSpec(subrole: "AXFloatingWindow"))
            app.open(WindowSpec(subrole: "AXDialog", parent: 1))
            let tabs = (0..<3).map { _ in app.open() }
            app.groupTabs(tabs, selected: tabs[0])
            let tessel = scenario.startTessel()
            scenario.settle()
            scenario.expect("setup: standard, fixed, dialog, panel, sheet and native tabs are classified", tessel.windows.count == 7)
            scenario.expect("setup: the native group has three tabs", tessel.windows.contains { $0.id == tabs[0] && $0.tabs == 3 })
            let expected = FoundationProof.snapshot(tessel.windows)
            let hungIDs = Set(tessel.windows.map(\.id))
            scenario.step("the app posts a resize then blocks its main thread") {
                app.resize(1, to: CGSize(width: 500, height: 320))
                app.hang()
            }
            let other = mac.launch()
            for index in 0..<3 {
                let openedAt = mac.scheduler.now
                let id = other.open()
                scenario.settle()
                FoundationProof.row(id, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
                FoundationProof.publication(tessel, pid: other.pid, since: openedAt, within: 500, scenario: scenario) { $0.contains { $0.id == id } }
                let rows = tessel.windows.filter { hungIDs.contains($0.id) }
                scenario.expect("hung rows keep their complete last snapshot on query \(index)", FoundationProof.snapshot(rows) == expected)
                let closedAt = mac.scheduler.now
                other.close(id)
                scenario.settle()
                scenario.expect("responsive window \(id) disappears", !tessel.windows.contains { $0.id == id })
                FoundationProof.publication(tessel, pid: other.pid, since: closedAt, within: 500, scenario: scenario) { $0.isEmpty }
            }
            let hungPublications = tessel.windowPublications.filter { $0.pid == app.pid }.map { FoundationProof.snapshot($0.windows ?? []) }
            scenario.expect("a failed AX refresh never publishes an empty or partial replacement", hungPublications.allSatisfy { $0 == expected })
        })
    }
}

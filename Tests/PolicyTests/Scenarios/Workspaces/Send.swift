import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct WorkspaceSend {
    enum EmptyPath: String, CaseIterable, Sendable {
        case emptyAXWindows, zeroIDs, minimizedOmissions, failedReads, mixedReads, realClose
    }

    @Test("#2 E8: sending follows the window and preserves every live row through empty-list paths (#22)",
          arguments: EmptyPath.allCases, WriteOrder.allCases)
    func emptyLists(path: EmptyPath, writes: WriteOrder) {
        // Capture before send or after send; publication always follows capture.
        for captureBeforeSend in [false, true] {
            let result = Scenario.run("#22 \(path.rawValue), capture-before-send=\(captureBeforeSend)", writes: writes) { scenario in
                let mac = scenario.mac
                let app = mac.launch(windows: 2)
                let tessel = scenario.startTessel(.stack)
                scenario.settle()
                WorkspaceScenarios.shown(scenario, 2)
                var publications: [(Int, [UInt32])] = []
                tessel.rows.onUpdate = { pid, rows in
                    if pid == app.pid {
                        let ids = rows?.map(\.id) ?? []
                        publications.append((mac.scheduler.now, ids))
                        mac.scheduler.note("CLI rows app-A ids=\(ids.sorted())")
                    }
                }
                if path == .minimizedOmissions {
                    WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 2)
                    scenario.step("minimize both live windows, preserving their published rows") {
                        app.minimize(1); app.minimize(2)
                    }
                    scenario.settle()
                }
                let replies: [WindowListReply]
                switch path {
                case .emptyAXWindows, .minimizedOmissions: replies = [.omitting([1, 2]), .omitting([1, 2])]
                case .zeroIDs: replies = [.zeroIDs([1, 2]), .zeroIDs([1, 2])]
                case .failedReads: replies = [.failure(.cannotComplete), .failure(.apiDisabled)]
                case .mixedReads: replies = [.complete, .omitting([1, 2]), .omitting([1, 2]), .complete]
                case .realClose: replies = [.includingClosed([2]), .includingClosed([2])]
                }
                if path == .realClose {
                    WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 2)
                    scenario.step("close sent window for real, retaining its listed AX handle") {
                        app.close(2, selecting: 1)
                        app.publishNextWindowLists(replies)
                    }
                    scenario.settle()
                    scenario.expect("real close retires the sent row", WorkspaceScenarios.row(tessel, 2) == nil)
                    scenario.expect("the previous live window remains listed", WorkspaceScenarios.row(tessel, 1)?.workspace == 1)
                    scenario.expect("close does not leave the empty workspace", tessel.status.active == 3)
                    WorkspaceScenarios.empty(scenario)
                } else {
                    if !captureBeforeSend && path != .minimizedOmissions {
                        WorkspaceScenarios.press(scenario, tessel, "send 3", shown: 2)
                    }
                    scenario.step("app publishes \(path.rawValue), then reports activation") {
                        app.publishNextWindowLists(replies)
                        app.activate()
                    }
                    scenario.step("capture read before its CLI publication") {
                        let outcome = mac.pause(after: .read(app))
                        if case .paused = outcome {} else { scenario.expect("read captured: \(outcome)", false) }
                    }
                    if captureBeforeSend && path != .minimizedOmissions {
                        scenario.step("send 3 while the read waits for delivery") { tessel.press("send 3") }
                    }
                    scenario.step("deliver captured read") {
                        let outcome = mac.deliver(app)
                        if case .paused = outcome {} else { scenario.expect("read delivered: \(outcome)", false) }
                    }
                    scenario.settle()
                    scenario.expect("every publication retains living sent window 2; publications=\(publications)",
                                    publications.allSatisfy { $0.1.contains(2) })
                    scenario.expect("send keeps workspace 3 in the CLI row", WorkspaceScenarios.row(tessel, 2)?.workspace == 3)
                    scenario.expect("send follows workspace 3", tessel.status.active == 3)
                    if path == .minimizedOmissions {
                        scenario.expect("the living sent row stays minimized", WorkspaceScenarios.row(tessel, 2)?.state == .minimized)
                        app.restore(2)
                        scenario.settle()
                    }
                    WorkspaceScenarios.shown(scenario, 2)
                }
                if path == .minimizedOmissions {
                    app.restore(1)
                    scenario.settle()
                }
                WorkspaceScenarios.press(scenario, tessel, "workspace 1", shown: 1)
                tessel.rows.onUpdate = nil
            }
            requireScenario(result)
        }
    }
}

import Ports
import Simulator
import Testing
@testable import Policy

extension DiagnosticsScenarios {
    @Test("settling reads after exhaustion do not duplicate the read failure")
    func settlingReadsRecordExhaustionOnce() {
        requireCarousel(Scenario.run("diagnostic exhaustion while native focus is settling") { s in
            let f = RailFixture(s, widths: [0.3])
            f.app.hang()
            f.mac.clearDiagnosticHistory()
            let traceStart = f.mac.scheduler.trace.count
            // Main-window changes start additional settling reads alongside
            // the ordinary retry chain; some arrive after its fifth failure.
            f.app.select(f.ids[0])
            s.settle()
            let reads = f.mac.scheduler.trace.dropFirst(traceStart).filter { $0.contains("AccessibilityPort.copy AXWindows \(f.app.alias) pid=\(f.app.pid)") }
            let failures = f.mac.diagnosticEvents.map(\.diagnostic).filter { if case .readFailed = $0 { true } else { false } }
            s.expect("settling really reads beyond the exhaustion point", reads.count > 5)
            s.expect("the exhausted burst still records only one error", failures == [
                .readFailed(pid: f.app.pid, bundleID: f.tessel.windows[0].bundleId, attempts: 5),
            ])
        })
    }

    @Test("a fullscreen transition records its state even when an app's custom subrole equals the fullscreen reason")
    func stateOnlyChangeIsRecorded() {
        requireCarousel(Scenario.run("diagnostic state cannot be inferred from its reason") { s in
            let app = s.mac.launch()
            // Unknown AX subroles become the ignored classification's reason.
            // That app-owned identifier can coincide with Tessel's vocabulary.
            let id = app.open(WindowSpec(subrole: "native fullscreen"))
            let tessel = s.startTessel()
            s.settle()
            s.expect("the custom subrole starts ignored", tessel.windows.first { $0.id == id }?.state == .ignored)
            s.mac.clearDiagnosticHistory()
            app.enterFullscreen(id)
            s.settle()
            s.expect("fullscreen records the state change even though its other fields match", s.mac.diagnosticEvents.contains {
                guard case .window(.changed(let before, let after), _) = $0.diagnostic else { return false }
                return after.id == id && before.state == "ignored" && after.state == "fullscreen"
                    && before.reason == after.reason && before.workspace == after.workspace
                    && before.rail == after.rail && before.visible == after.visible
            })
        })
    }

    @Test("a rail-only move records membership even when classification and visibility stay the same")
    func railOnlyChangeIsRecorded() {
        requireCarousel(Scenario.run("diagnostic for a tile moving to another rail") { s in
            let f = RailFixture(s, widths: [0.3, 0.3]), id = f.ids[0]
            f.mac.clearDiagnosticHistory()
            f.press("move down", focus: id)
            let changes = f.mac.diagnosticEvents.compactMap { event -> WindowChange? in
                guard case .window(let change, "after command move down") = event.diagnostic else { return nil }
                return change
            }
            s.expect("the moved tile records its rail-only change", changes.contains {
                guard case .changed(let before, let after) = $0 else { return false }
                return after.id == id && before.rail == 1 && after.rail == 2
                    && before.workspace == after.workspace && before.state == after.state
                    && before.reason == after.reason && before.visible == after.visible
            })
        })
    }

    @Test("native tab grouping records a changed reason without changing the selected tile's state")
    func reasonOnlyChangeIsRecorded() {
        requireCarousel(Scenario.run("diagnostic for a changed native tab count") { s in
            let f = RailFixture(s, widths: [0.3, 0.3]), id = f.ids[0]
            f.mac.clearDiagnosticHistory()
            f.app.groupTabs(f.ids, selected: id)
            s.settle()
            let changes = f.mac.diagnosticEvents.compactMap { event -> WindowChange? in
                guard case .window(let change, _) = event.diagnostic else { return nil }
                return change
            }
            s.expect("the selected tile records its new classification reason", changes.contains {
                guard case .changed(let before, let after) = $0 else { return false }
                return after.id == id && before.reason == "standard window" && after.reason == "standard window; 2 native tabs"
                    && before.workspace == after.workspace && before.rail == after.rail
                    && before.state == after.state && before.visible == after.visible
            })
        })
    }

    @Test("a pointer-queued command records once at receipt and not again when reconciliation executes it")
    func queuedCommandRecordsOnlyAtReceipt() {
        requireCarousel(Scenario.run("diagnostic receipt during pointer reconciliation") { s in
            let f = RailFixture(s, widths: [0.3, 0.3])
            f.mac.pointerDown()
            f.mac.pointerUp()
            f.mac.clearDiagnosticHistory()
            let receipt = Diagnostic.command("workspace 2", workspace: 1, rail: 1, focused: f.ids[0])
            f.tessel.press("workspace 2")
            s.expect("the queued command records its receipt before it executes",
                     f.tessel.status.active == 1 && f.mac.diagnosticEvents.map(\.diagnostic) == [receipt])
            s.settle()
            let commands = f.mac.diagnosticEvents.map(\.diagnostic).filter { if case .command = $0 { true } else { false } }
            s.expect("reconciliation executes the command without duplicating its receipt", f.tessel.status.active == 2 && commands == [receipt])
        })
    }

    @Test("an unreadable config records its read error and a subsequent successful read records recovery")
    func unreadableConfigurationIsRecorded() {
        requireCarousel(Scenario.run("diagnostic for config read failure and recovery") { s in
            let tessel = s.startTessel()
            s.settle()
            let revision = tessel.configuration.revision
            s.mac.clearDiagnosticHistory()
            tessel.changeConfig(nil, unreadable: true)
            s.settle()
            s.expect("the read failure records its stable message and leaves the revision intact",
                     tessel.configuration.revision == revision && s.mac.diagnosticEvents.map(\.diagnostic)
                        == [.configError(line: 1, message: "Unable to read configuration file")])
            s.mac.clearDiagnosticHistory()
            tessel.changeConfig(nil)
            s.settle()
            s.expect("a successful read of unchanged contents records recovery",
                     s.mac.diagnosticEvents.map(\.diagnostic) == [.configLoaded(state: "defaults", revision: revision + 1)])
        })
    }
}

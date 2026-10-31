import CoreGraphics
import Foundation
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct DiagnosticsScenarios {
    @Test("#62 E3: an omitted snapshot records the old membership before a returning window's new arrival")
    func goneThenReappearedKeepsBothMemberships() {
        requireCarousel(Scenario.run("gone from workspace 2 rail 2, returned on workspace 1") { s in
            let mac = s.mac
            let anchor = mac.launch(windows: 1)
            let app = mac.launch(windows: 2)
            let base = app.windows[0], window = app.windows[1]
            app.select(base)
            let tessel = s.startTessel(text: "[animation]\nduration = 0\n")
            s.settle()
            WorkspaceScenarios.press(s, tessel, "send 2", shown: base)
            WorkspaceScenarios.press(s, tessel, "workspace 1")
            app.select(window); s.settle()
            WorkspaceScenarios.press(s, tessel, "send 2", shown: window)
            WorkspaceScenarios.press(s, tessel, "move down", shown: window)
            WorkspaceScenarios.press(s, tessel, "workspace 1")
            anchor.select(anchor.windows[0]); s.settle()
            let before = tessel.windows.first { $0.id == window }!
            s.expect("setup: W is hidden on workspace 2, rail 2", before.workspace == 2 && before.rail == 2 && !before.visible)
            let observations = tessel.windows.filter { $0.bundleId == before.bundleId }.map {
                WindowObservation(record: $0, frame: mac.frame($0.id)!, parent: nil)
            }
            mac.clearDiagnosticHistory()

            // Exercise the complete catalog-snapshot boundary. AXWindows alone
            // omitting a live handle is deliberately repaired by WindowCatalog;
            // this example is about what Workspaces records if W is absent.
            s.step("the app's complete snapshot omits W") {
                tessel.workspaces.update(pid: app.pid, observations: observations.filter { $0.record.id != window },
                                         focused: nil, frontmost: false, change: .snapshot)
            }
            s.settle()
            s.expect("the omitted snapshot really forgets W", !tessel.windows.contains { $0.id == window })
            let gone = Diagnostic.window(.gone(DiagnosticsProof.window(before, pid: app.pid)),
                                         after: "after snapshot \(before.bundleId)")
            let afterOmission = DiagnosticsProof.values(mac)
            s.expect("the old workspace and rail are recorded before W returns; actual \(afterOmission)", afterOmission.contains(gone))
            s.step("the next complete snapshot lists W again") {
                tessel.workspaces.update(pid: app.pid, observations: observations, focused: nil, frontmost: false, change: .snapshot)
            }
            s.settle()
            s.expect("the returning W actually joins workspace 1, rail 1",
                     tessel.windows.contains { $0.id == window && $0.workspace == 1 && $0.rail == 1 && $0.state == .tiled })
            let entries = DiagnosticsProof.values(mac)
            let arrivals = entries.indices.filter { index in
                guard case .window(.appeared(let value), let after) = entries[index] else { return false }
                return value.id == window && value.pid == app.pid && value.bundleID == before.bundleId
                    && value.state == "tiled" && value.reason == "standard window" && value.workspace == 1 && value.rail == 1
                    && after == "after snapshot \(before.bundleId)"
            }
            s.expect("exactly one gone entry preserves W's old membership; actual \(entries)", entries.filter { $0 == gone }.count == 1)
            s.expect("exactly one appeared entry records W's new membership; actual \(entries)", arrivals.count == 1)
            s.expect("gone precedes appeared", entries.firstIndex(of: gone).map { old in arrivals.first.map { old < $0 } ?? false } == true)
        })
    }

    @Test("#62 E4: commands record once at receipt with their original context and tag their following effects")
    func commandsRecordReceiptContextAndEffects() {
        requireCarousel(Scenario.run("command receipt, wall hit and asynchronous results") { s in
            let f = RailFixture(s, widths: [0.3, 0.3])
            f.tessel.changeConfig("[animation]\nduration = 0\n[keys]\nalt-q = 'focus next'\nalt-w = 'focus previous'\n")
            s.settle()
            f.mac.clearDiagnosticHistory()
            f.tessel.press("focus left")
            let wall = Diagnostic.command("focus left", workspace: 1, rail: 1, focused: f.ids[0])
            s.expect("the wall-hit command is recorded synchronously; actual \(DiagnosticsProof.values(f.mac))",
                     DiagnosticsProof.values(f.mac) == [wall])
            s.settle()
            s.expect("a no-op focus left produces exactly its command entry", DiagnosticsProof.values(f.mac) == [wall])

            for command in ["send 2", "workspace 1", "focus right", "focus up", "focus down", "move left", "move right",
                            "move down", "move up", "cycle width", "focus next", "focus previous", "focus recent", "toggle float", "toggle layer"] {
                let receipt = Diagnostic.command(command, workspace: f.tessel.status.active, rail: f.tessel.status.rail,
                                                 focused: f.mac.focusedWindow)
                f.mac.clearDiagnosticHistory()
                s.step("receive \(command)") { f.tessel.press(command) }
                s.expect("\(command) records its pre-command context on receipt; actual \(DiagnosticsProof.values(f.mac))",
                         DiagnosticsProof.values(f.mac).first == receipt)
                s.settle()
                let entries = DiagnosticsProof.values(f.mac)
                let commands = entries.filter { if case .command = $0 { true } else { false } }
                s.expect("\(command) records exactly one command, including asynchronous completion; actual \(commands)", commands == [receipt])
                if command == "send 2" {
                    s.expect("send records the resulting workspace change after its receipt; actual \(entries)", entries.dropFirst().contains {
                        guard case .window(.changed(let from, let to), let after) = $0 else { return false }
                        return to.id == f.ids[0] && from.workspace == 1 && to.workspace == 2 && after == "after command send 2"
                    })
                }
                if command == "workspace 1" {
                    s.expect("the following focus change names its command; actual \(entries)", entries.dropFirst().contains(
                        .focus(from: f.ids[0], to: f.ids[1], after: "after command workspace 1")))
                }
            }

            // Switching workspace shows or hides windows without moving them,
            // so their entries are due to visibility alone. A hide is tagged
            // with its command; a show is published by the snapshot that
            // confirms the window on screen.
            let original = f.tessel.status.active
            for target in [original == 1 ? 2 : 1, original] {
                f.mac.clearDiagnosticHistory()
                s.step("switch to workspace \(target)") { f.tessel.press("workspace \(target)") }
                s.settle()
                let entries = DiagnosticsProof.values(f.mac)
                let visibility = entries.compactMap { entry -> (DiagnosticWindow, DiagnosticWindow, String)? in
                    guard case .window(.changed(let from, let to), let after) = entry, from.visible != to.visible,
                          from.workspace == to.workspace, from.rail == to.rail, from.state == to.state, from.reason == to.reason
                    else { return nil }
                    return (from, to, after)
                }
                s.expect("workspace \(target) records a visibility-only change; actual \(entries)", !visibility.isEmpty)
                s.expect("every window hidden by workspace \(target) names its command; actual \(entries)",
                         visibility.allSatisfy { $0.1.visible || $0.2 == "after command workspace \(target)" })
            }
        })
    }

    @Test("#62 E5: unchanged windows, app geometry and slot-only swaps produce no window diagnostics")
    func unchangedGeometryAndSlotsAreSilent() {
        requireCarousel(Scenario.run("ignore unchanged snapshots, app frames and slot-only changes") { s in
            let f = RailFixture(s, widths: [0.3, 0.3])
            let id = f.ids[0]
            let before = f.tessel.windows.map { DiagnosticsProof.window($0, pid: f.app.pid) }
            for change in ["unchanged read", "app move", "app resize"] {
                f.mac.clearDiagnosticHistory()
                s.step(change) {
                    let frame = f.frame(id)
                    if change == "app resize" {
                        f.app.resizeFromApplication(id, to: CGSize(width: frame.width - 20, height: frame.height))
                    } else {
                        f.app.moveFromApplication(id, to: CGPoint(x: frame.minX + (change == "app move" ? 8 : 0), y: frame.minY))
                    }
                }
                s.settle()
                let notices = DiagnosticsProof.values(f.mac).filter { $0.level == .notice }
                s.expect("\(change) records no notice; actual \(notices)", notices.isEmpty)
                s.expect("\(change) preserves every diagnostic field", f.tessel.windows.map { DiagnosticsProof.window($0, pid: f.app.pid) } == before)
            }
            f.mac.clearDiagnosticHistory()
            f.press("move right", focus: id)
            f.order([f.ids[1], id])
            let changes = DiagnosticsProof.values(f.mac).filter { if case .window = $0 { true } else { false } }
            s.expect("a swap that changes only slots records no window entry; actual \(changes)", changes.isEmpty)
            let after = f.tessel.windows.map { DiagnosticsProof.window($0, pid: f.app.pid) }
            s.expect("the swap preserves workspace, rail, state, reason and visibility", zip(before, after).allSatisfy {
                $0.id == $1.id && $0.workspace == $1.workspace && $0.rail == $1.rail
                    && $0.state == $1.state && $0.reason == $1.reason && $0.visible == $1.visible
            })
        })
    }

    @Test("#62 E6: every arrival including ignored windows records its classification once and records later classification changes")
    func classificationsRecordArrivalsChangesAndNoRereadNoise() {
        requireCarousel(Scenario.run("classification diagnostics include ignored surfaces") { s in
            let mac = s.mac, app = mac.launch()
            let tile = app.open()
            let panel = app.open(WindowSpec(subrole: "AXFloatingWindow"))
            let ignored = app.open(WindowSpec(subrole: "AXUnknown"))
            let fixed = app.open(WindowSpec(resizable: false))
            app.select(tile)
            let tessel = s.startTessel(text: "[animation]\nduration = 0\n")
            s.settle()
            let expected = [(tile, "tiled", "standard window"), (panel, "floats", "AXFloatingWindow"),
                            (ignored, "ignored", "AXUnknown"), (fixed, "floats", "fixed size")]
            let entries = DiagnosticsProof.values(mac)
            for (id, state, reason) in expected {
                s.expect("setup: window \(id) has the expected classification", tessel.windows.contains { $0.id == id && $0.state.rawValue == state && $0.reason == reason })
                let arrivals = entries.compactMap { entry -> DiagnosticWindow? in
                    guard case .window(.appeared(let value), _) = entry, value.id == id else { return nil }
                    return value
                }
                s.expect("window \(id) records \(state) and its reason exactly once on arrival; actual \(arrivals)", arrivals.count == 1
                         && arrivals.first?.state == state && arrivals.first?.reason == reason
                         && arrivals.first?.pid == app.pid && arrivals.first?.bundleID == tessel.windows.first { $0.id == id }?.bundleId)
            }
            mac.clearDiagnosticHistory()
            s.step("the tile is moved to the floating layer") { tessel.press("toggle float") }
            s.settle()
            s.expect("setup: the classification actually changed", tessel.windows.contains { $0.id == tile && $0.state == .floats && $0.reason == "moved to the layer" })
            let classifications = DiagnosticsProof.values(mac).filter {
                guard case .window(.changed(let from, let to), _) = $0 else { return false }
                return to.id == tile && (from.state != to.state || from.reason != to.reason)
            }
            s.expect("the new classification and reason are recorded once; actual \(classifications)", classifications.count == 1 && classifications.contains {
                guard case .window(.changed(let from, let to), _) = $0 else { return false }
                return from.state == "tiled" && to.state == "floats" && to.reason == "moved to the layer"
            })
            mac.clearDiagnosticHistory()
            app.moveFromApplication(tile, to: mac.frame(tile)!.origin)
            s.settle()
            s.expect("a re-read with unchanged classification records nothing; actual \(DiagnosticsProof.values(mac))", DiagnosticsProof.values(mac).isEmpty)
        })
    }

    @Test("#62 E7: read exhaustion records one error after five attempts and a new event re-arms it")
    func readFailuresRecordOncePerExhaustedBurst() {
        requireCarousel(Scenario.run("read failures are recorded at exhaustion, not per attempt") { s in
            let f = RailFixture(s, widths: [0.3])
            f.app.hang()
            let bundle = f.tessel.windows[0].bundleId
            let failed = Diagnostic.readFailed(pid: f.app.pid, bundleID: bundle, attempts: 5)
            for burst in 1...2 {
                f.mac.clearDiagnosticHistory()
                let traceStart = f.mac.scheduler.trace.count
                s.step("app event starts hung read burst \(burst)") { f.app.activate() }
                var beforeExhaustion: [Diagnostic] = []
                s.after(milliseconds: 1_000, "inspect before the fifth attempt") {
                    beforeExhaustion = DiagnosticsProof.values(f.mac).filter { if case .readFailed = $0 { true } else { false } }
                }
                s.settle()
                let reads = f.mac.scheduler.trace.dropFirst(traceStart).filter { $0.contains("AccessibilityPort.copy AXWindows \(f.app.alias) pid=\(f.app.pid)") }
                s.expect("setup: burst \(burst) exhausts exactly five actual reads (got \(reads.count))", reads.count == 5)
                s.expect("no read-failed entry precedes exhaustion", beforeExhaustion.isEmpty)
                let failures = DiagnosticsProof.values(f.mac).filter { if case .readFailed = $0 { true } else { false } }
                s.expect("burst \(burst) records one five-attempt failure; actual \(failures)", failures == [failed])
                s.expect("read failure is an error", failures.map(\.level) == [.error])
            }
        })
    }

    @Test("#62 E8: disabling failures retain their reason at error level while Quit is a notice")
    func disableReasonsAreErrorsAndQuitIsNotice() {
        for reason in ["SkyLight could not hide a window", "Could not register workspace hotkeys", "SkyLight window hiding is unavailable"] {
            requireCarousel(Scenario.run("disable diagnostic: \(reason)") { s in
                let f = RailFixture(s, widths: [0.3])
                f.mac.clearDiagnosticHistory()
                // All existing failure paths converge here; this tests their
                // diagnostic boundary without inventing new native failures.
                f.tessel.workspaces.disable(reason: reason)
                s.settle()
                s.expect("setup: management is disabled with its actual failure", !f.tessel.status.enabled && f.tessel.status.reason == reason)
                let failures = DiagnosticsProof.values(f.mac).filter { if case .disabled = $0 { true } else { false } }
                s.expect("disable records its reason once; actual \(failures)", failures == [.disabled(reason: reason)])
                s.expect("disable records an error", failures.map(\.level) == [.error])
            })
        }
        requireCarousel(Scenario.run("ordinary Quit diagnostic") { s in
            let f = RailFixture(s, widths: [0.3])
            f.mac.clearDiagnosticHistory()
            f.tessel.quit()
            s.settle()
            s.expect("setup: Quit completed cleanup", f.tessel.quitCompletions == 1 && !f.tessel.status.enabled)
            let entries = DiagnosticsProof.values(f.mac)
            s.expect("Quit records exactly one quit notice; actual \(entries)", entries.filter { $0 == .quit } == [.quit] && entries.filter { $0 == .quit }.map(\.level) == [.notice])
            s.expect("Quit records no error", !entries.contains { $0.level == .error })
        })
    }

    @Test("#62 E9: invalid config records its line and message and successful reloads record state and revision")
    func configurationRecordsErrorsAndSuccessfulRevisions() {
        requireCarousel(Scenario.run("configuration error and recovery diagnostics") { s in
            let tessel = s.startTessel()
            s.settle()
            let mac = s.mac, revision = tessel.configuration.revision
            mac.clearDiagnosticHistory()
            tessel.changeConfig("[gaps]\nouter = -1\n")
            s.settle()
            s.expect("setup: the parser rejected line 2 and retained the revision", tessel.configuration.error?.line == 2 && tessel.configuration.revision == revision)
            let error = Diagnostic.configError(line: 2, message: "outer must be a nonnegative TOML number")
            s.expect("config error records the parser's line and message; actual \(DiagnosticsProof.values(mac))", DiagnosticsProof.values(mac) == [error])
            s.expect("config error is an error", DiagnosticsProof.values(mac).map(\.level) == [.error])
            for (text, state) in [("[gaps]\nouter = 24\n" as String?, "loaded"), (nil, "defaults")] {
                mac.clearDiagnosticHistory()
                let next = tessel.configuration.revision + 1
                tessel.changeConfig(text)
                s.settle()
                s.expect("setup: successful reload publishes \(state), revision \(next)", tessel.configuration.state == state && tessel.configuration.revision == next && tessel.configuration.error == nil)
                s.expect("successful reload records its state and revision; actual \(DiagnosticsProof.values(mac))",
                         DiagnosticsProof.values(mac) == [.configLoaded(state: state, revision: next)])
            }
        })
    }

    @Test("#62 E15: sixty virtual seconds idle across multiple workspaces and rails record nothing")
    func idleAcrossWorkspacesAndRailsRecordsNothing() {
        requireCarousel(Scenario.run("sixty virtual seconds with windows on multiple workspaces and rails") { s in
            let f = RailFixture(s, widths: [0.3, 0.3, 0.3, 0.3])
            f.press("send 2", focus: f.ids[0])
            f.press("workspace 1")
            f.select(f.ids[1]); f.press("send 2", focus: f.ids[1])
            f.press("move down", focus: f.ids[1])
            f.press("workspace 1")
            f.select(f.ids[2]); f.press("move down", focus: f.ids[2])
            s.expect("setup: windows occupy two workspaces and multiple rails",
                     Set(f.tessel.windows.compactMap(\.workspace)) == [1, 2] && f.tessel.windows.filter { $0.rail == 2 }.count == 2)
            f.mac.clearDiagnosticHistory()
            let began = f.mac.scheduler.now
            f.mac.scheduler.maxMilliseconds = began + 60_001
            s.after(milliseconds: 60_000, "end the idle observation") {}
            s.settle()
            s.expect("the idle window lasts sixty virtual seconds", f.mac.scheduler.now == began + 60_000)
            s.expect("idle records no diagnostics; actual \(DiagnosticsProof.values(f.mac))", f.mac.diagnosticEvents.isEmpty)
        })
    }

    @Test("#62 E18: recording adds only trace notes, never interleavings, and repeated scenarios keep the same digest")
    func recordingPreservesSchedulingAndReplayDigest() {
        let results = (0..<3).map { _ in
            Scenario.run("diagnostic recording and replay") { s in
                let mac = s.mac
                let lane = mac.scheduler.serialLane(label: "diagnostics-probe")
                lane.async { mac.diagnostics.record(.configLoaded(state: "defaults", revision: 1)) }
                let transitions = mac.scheduler.transitions, now = mac.scheduler.now, trace = mac.scheduler.trace
                mac.diagnostics.record(.enabled)
                s.expect("recording cannot run a ready worker", mac.diagnosticEvents.map(\.diagnostic) == [.enabled])
                s.expect("recording changes no scheduler transitions or virtual time", mac.scheduler.transitions == transitions && mac.scheduler.now == now)
                s.expect("recording adds only one trace note", mac.scheduler.trace.count == trace.count + 1 && Array(mac.scheduler.trace.prefix(trace.count)) == trace)
                s.settle()
                s.expect("AX-lane recording also needs no main hop", mac.diagnosticEvents.map(\.diagnostic) == [.enabled, .configLoaded(state: "defaults", revision: 1)])
                let f = RailFixture(s, widths: [0.3, 0.3])
                f.press("send 2", focus: f.ids[0]); f.press("workspace 1", focus: f.ids[1])
            }
        }
        for result in results { requireCarousel(result) }
        #expect(Set(results.map(\.digest)).count == 1, "identical scenarios must retain the same trace digest")
    }
}

@MainActor private enum DiagnosticsProof {
    static func values(_ mac: SimulatedMac) -> [Diagnostic] { mac.diagnosticEvents.map(\.diagnostic) }

    static func window(_ row: WindowRecord, pid: Int32) -> DiagnosticWindow {
        DiagnosticWindow(id: row.id, pid: pid, bundleID: row.bundleId, state: row.state.rawValue, reason: row.reason,
                         workspace: row.workspace, rail: row.rail, slot: row.slot, visible: row.visible)
    }
}

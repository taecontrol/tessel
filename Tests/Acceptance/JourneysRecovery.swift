import Carbon
import CoreGraphics
import Darwin
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("crash and quit journey")
    func crashAndQuit() throws {
        var menuRestart: (old: pid_t, new: pid_t)?
        var cliRestart: (old: pid_t, new: pid_t)?
        try step("#67 E1 menu restart returns both windows to workspace 1 and preserves permission, config and keys") {
            let ids = try desktop.railSetup([0.5, 0.5], duration: 0)
            let before = try harness.status()
            try desktop.expectInside(ids)
            try desktop.pressMenuItem("Restart Tessel")
            // E1's final state uses the repository's single generous 5 s margin.
            // No elapsed-time assertion belongs in a journey; the CLI's exact
            // ten-second deadline is exercised by the virtual-clock policy test.
            let after = try harness.waitForRestart(previous: before.pid)
            menuRestart = (before.pid, after.pid)
            try requireFinalState("the previous process exited and only the ready replacement remains") {
                processIDs(appExecutable) == [after.pid] && kill(before.pid, 0) == -1 && errno == ESRCH
            }
            try #require(after.permission == "granted")
            try #require(after.config.path == before.config.path)
            try requireFinalState("both fixtures are on rail 1 of workspace 1") {
                let rows = try harness.rows()
                return try harness.status().workspaces?.active == 1
                    && ids.allSatisfy { id in rows.contains { $0.id == id && $0.workspace == 1 && $0.rail == 1 && $0.visible == true } }
            }
            try desktop.expectInside(ids)
            try desktop.activate(key: "w0")
            try desktop.post(kVK_ANSI_L)
            try desktop.expectFocus(ids[1])
        }
        try step("#67 E2 CLI restart prints the replacement pid and returns only after that pid is ready") {
            let old = harness.appPID
            let ready = try restartThroughCLI()
            cliRestart = (old, ready.pid)
        }
        try step("a delayed CLI request for the previous pid joins its ready replacement (transport wiring)") {
            let pair = try #require(cliRestart)
            let client = try StreamClient(path: harness.endpoint(), timeout: margin)
            let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            try client.send(Data("restart \(String(deadline, radix: 36)) \(pair.old)\n".utf8))
            struct Reply: Decodable { let restarted: pid_t?; let error: String? }
            let reply = try JSONDecoder().decode(Reply.self, from: client.readLine(limit: 4096))
            try #require(reply.error == nil && reply.restarted == pair.new)
            try #require(try harness.status().pid == pair.new)
        }
        try step("#67 E4; #67 E5 restart markers precede old-pid quit, which precedes new-pid startup and window management") {
            let menu = try #require(menuRestart), cli = try #require(cliRestart)
            for (source, pair) in [("menu", menu), ("cli", cli)] {
                var entries: [Harness.LifecycleEntry] = []
                try requireFinalState("the requested, quit and started lifecycle records are available") {
                    entries = try harness.lifecycleEntries(pids: [pair.old, pair.new])
                    return entries.contains { $0.pid == pair.old && $0.message == "restart requested from \(source)" }
                        && entries.contains { $0.pid == pair.old && $0.message == "quit" }
                        && entries.contains { $0.pid == pair.new && $0.message.hasPrefix("started ") }
                }
                let requested = try #require(entries.firstIndex { $0.pid == pair.old && $0.message == "restart requested from \(source)" })
                let quit = try #require(entries.firstIndex { $0.pid == pair.old && $0.message == "quit" })
                let started = try #require(entries.firstIndex { $0.pid == pair.new && $0.message.hasPrefix("started ") })
                try #require(requested < quit && quit < started, "the old instance must quit before the new instance starts setup")
                try #require(entries.filter { $0.pid == pair.old && $0.message == "restart requested from \(source)" }.count == 1)
                try #require(!entries.prefix(quit + 1).contains { $0.pid == pair.new }, "the replacement must emit no setup or window diagnostics while the previous instance runs")
            }
        }
        try step("#67 E3 restart reveals a workspace-2 tile and a hidden manually floating window on the current desktop") {
            try desktop.clear()
            // Moving a tile to the layer gives it half the desktop width.
            // Leave room for that observed width when restart tiles it again.
            let ids = try desktop.railSetup([0.2, 0.2, 0.5], duration: 0)
            try desktop.key(2, send: true)
            try requireFinalState("the first tile is on workspace 2") { try harness.row(ids[0])?.workspace == 2 }
            try desktop.key(1)
            // Finish the workspace handoff before selecting the next tile
            // through Tessel, so its focus decision precedes the float key.
            try desktop.expectFocus(ids[1])
            try desktop.post(kVK_ANSI_L)
            try desktop.expectFocus(ids[2])
            try desktop.post(kVK_ANSI_F)
            try requireFinalState("the third standard fixture is manually floating") { try harness.row(ids[2])?.state == "floats" }
            try desktop.post(kVK_ANSI_Z)
            try requireFinalState("both the workspace-2 tile and floating fixture are hidden") {
                let visible = try desktop.observe(focusedOnly: true).visibleIDs
                return !visible.contains(ids[0]) && !visible.contains(ids[2])
            }
            _ = try restartThroughCLI()
            try requireFinalState("the restart forgets workspace and manual-float placement") {
                let rows = try harness.rows()
                return ids.allSatisfy { id in rows.contains { $0.id == id && $0.workspace == 1 && $0.rail == 1 && $0.visible == true } }
            }
            try desktop.expectInside(ids)
        }
        try step("#67 E9 launch failure keeps the old process and layout, reports the reason in CLI, alert and log") {
            try desktop.clear()
            let ids = try desktop.railSetup([1.0 / 3, 2.0 / 3], duration: 0, arguments: ["--test-failed-relaunch"])
            defer { harness.stopApp() }
            try requireFinalState("both fixtures are managed before requesting a failed relaunch") {
                Set(try harness.rows().map(\.id)) == Set(ids)
            }
            try desktop.expectInside(ids)
            let old = harness.appPID
            let before = try harness.rows().sorted { $0.id < $1.id }
            let frames = try ids.map { try #require(try desktop.window($0)).frame }
            let result = try harness.invoke("restart")
            try #require(result.status == 1 && result.output.isEmpty)
            let prefix = "Tessel could not restart: "
            try #require(result.error.hasPrefix(prefix) && result.error.hasSuffix("\n") && result.error.split(separator: "\n").count == 1)
            let reason = String(result.error.dropFirst(prefix.count).dropLast())
            try #require(!reason.isEmpty)
            try #require(result.error == "Tessel could not restart: \(reason)\n")
            try requireFinalState("the CLI launch refusal is recorded") {
                try harness.lifecycleEntries(pids: [old]).contains { $0.message == "restart failed: \(reason)" }
            }
            try #require(try harness.status().pid == old && processIDs(appExecutable) == [old])
            try #require(try harness.rows().sorted { $0.id < $1.id } == before)
            for (id, frame) in zip(ids, frames) { try #require(try desktop.window(id)?.frame == frame) }
            try desktop.pressMenuItem("Restart Tessel")
            try desktop.expectRestartAlert(reason: reason)
            try requireFinalState("both failed launches are recorded without a quit") {
                let entries = try harness.lifecycleEntries(pids: [old])
                return entries.filter { $0.message == "restart failed: \(reason)" }.count == 2
                    && !entries.contains { $0.message == "quit" }
            }
            try #require(try harness.status().pid == old && processIDs(appExecutable) == [old])
            try #require(try harness.rows().sorted { $0.id < $1.id } == before)
            for (id, frame) in zip(ids, frames) { try #require(try desktop.window(id)?.frame == frame) }
            try desktop.expectInside(ids)
        }
        try step("#2 E28 quit returns managed windows and releases hotkeys") {
            try desktop.clear()
            let (a, b) = try desktop.split()
            harness.stopApp()
            try desktop.expectInside([a, b])
            try desktop.activate(key: "a")
            try desktop.expectPassedKey(kVK_ANSI_1)
            let status = try harness.invoke("status", "--json")
            try #require(status.status != 0 && status.error.contains("Tessel is not running"))
            try step("#67 E7 CLI restart while stopped reports not running and launches nothing") {
                let result = try harness.invoke("restart")
                try #require(result.status == 1 && result.output.isEmpty)
                try #require(result.error == "Tessel is not running\n")
                try #require(processIDs(appExecutable).isEmpty)
            }
        }
        try step("#2 E29 crash recovery returns orphans after a successful AX enumeration") {
            do {
                try desktop.clear()
                let (a, b) = try desktop.split()
                try #require(try !desktop.visible(b))
                kill(harness.appPID, SIGKILL)
                try requireFinalState("the crashed app exited") { !harness.appIsRunning }
                try harness.startApp(fixtureReady: false)
                try requireFinalState("both recovered fixtures assigned to workspace 1") {
                    let rows = try harness.rows()
                    return [a, b].allSatisfy { id in rows.contains { $0.id == id && $0.workspace == 1 } }
                }
                let current = try #require(try finalValue {
                    try desktop.observe(focusedOnly: true).windows.first { $0.main && $0.focused && $0.visible }?.id
                })
                try desktop.post(current == a ? kVK_ANSI_L : kVK_ANSI_H)
                try desktop.expectShown(current == a ? b : a)
            }
            try desktop.clear()
            let (a, b) = try desktop.split()
            kill(harness.appPID, SIGKILL)
            try requireFinalState("the app exited before blocked-AX recovery") { !harness.appIsRunning }
            try desktop.writeConfig("")
            kill(fixture.pid, SIGSTOP)
            do {
                defer { kill(fixture.pid, SIGCONT) }
                try harness.startApp(fixtureReady: false)
                try requireFinalState("startup has no successful fixture enumeration") { try harness.rows().isEmpty }
                guard let listing = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
                    throw HarnessError("cannot read fixture visibility while AX is blocked")
                }
                let orphanVisible = listing.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == b }
                try #require(!orphanVisible, "recovery must not show an orphan before the first successful AX enumeration")
            }
            try requireFinalState("the orphan catalogued after AX resumes") { try harness.row(b) != nil }
            for (key, id) in [("a", a), ("b", b)] { try desktop.activate(key: key); try desktop.expectFocus(id) }
        }
        try step("rail quit and crash preserve managed windows") {
            for crash in [false, true] {
                try desktop.clear()
                let ids = try desktop.railSetup([0.6, 0.6, 0.6, 0.6], duration: 0)
                if crash {
                    kill(harness.appPID, SIGKILL)
                    try requireFinalState("the crashed process exits") { !harness.appIsRunning }
                    try harness.startApp(fixtureReady: false)
                    for (index, id) in ids.enumerated() { try desktop.activate(key: "w\(index)"); try desktop.expectFocus(id) }
                } else { harness.stopApp(); try desktop.expectInside(ids) }
            }
        }
        try step("#67 E11 a replacement abandons a live previous pid before any setup or window management") {
            try desktop.clear()
            harness.stopApp()
            let id = try fixture.open(key: "previous", ["widthFraction": 0.5])
            let area = try desktop.observe().area
            try fixture.command("move", ["key": "previous", "frame": [area[0] + 30, area[1] + 50, 240, 180]])
            try desktop.expectInside([id])
            let before = try #require(try desktop.window(id)).frame
            let previous = fixture.pid
            try #require(kill(previous, 0) == 0)
            // One test second replaces the production guard's ten seconds;
            // the observation still uses the single shared final-state margin.
            try harness.startApp(fixtureReady: false, arguments: ["--restart-after", String(previous), "--test-short-restart-wait"], waitUntilReady: false)
            let replacement = harness.appPID
            let pending = try harness.invoke("status", "--json")
            try #require(pending.status == 1 && pending.error == "Tessel is not running\n", "a replacement waiting on its previous pid must expose no endpoint")
            var entries: [Harness.LifecycleEntry] = []
            try requireFinalState("the waiting replacement records abandonment and exits") {
                entries = try harness.lifecycleEntries(pids: [replacement])
                return entries.contains { $0.message == "restart abandoned: previous instance \(previous) still running" }
                    && !processIDs(appExecutable).contains(replacement)
            }
            try #require(kill(previous, 0) == 0, "the previous process must never be killed")
            try #require(!entries.contains { $0.message.hasPrefix("started ") || $0.message == "enabled" || $0.message.hasPrefix("window ") })
            try #require(try desktop.window(id)?.frame == before)
            try desktop.expectInside([id])
        }
        try step("#2 E34 missing SkyLight and failed hide disable safely; test arguments stay private") {
            for failure in ["--test-missing-skylight", "--test-failed-hide"] {
                try desktop.clear()
                harness.stopApp()
                // Both must not fit: short rails now retain their widths, so
                // two ordinary fixtures would never exercise failed hiding.
                let ids = try [fixture.open(key: "a", ["widthFraction": 1.0]), fixture.open(key: "b", ["widthFraction": 1.0])]
                let area = try desktop.observe().area
                for key in ["a", "b"] {
                    try fixture.command("move", ["key": key, "frame": [area[0] + 10, area[1] + 100, area[2] - 20, 300]])
                }
                try desktop.expectInside(ids)
                try desktop.activate(key: "b")
                let frame = try #require(try desktop.window(ids[1])).frame
                try desktop.writeConfig(desktop.carousel)
                try harness.startApp(fixtureReady: false, arguments: [failure])
                try requireFinalState("the unavailable hiding mechanism reported") {
                    let status = try harness.status().workspaces
                    return status?.enabled == false && status?.reason.lowercased().contains("skylight") == true
                }
                try desktop.expectInside(ids)
                if failure == "--test-missing-skylight" {
                    try #require(try desktop.window(ids[1])?.frame == frame)
                    try desktop.expectMenu(try #require(try harness.status().workspaces).reason, open: true)
                    try step("#67 E6 restart from disabled workspaces carries the test arguments and the disabled reason") {
                        let before = try harness.status()
                        let after = try restartThroughCLI()
                        try #require(after.pid != before.pid && after.config.path == before.config.path)
                        try #require(after.workspaces?.enabled == false && after.workspaces?.reason == before.workspaces?.reason)
                        try desktop.expectInside(ids)
                    }
                }
                try desktop.activate(key: "b")
                try desktop.expectPassedKey(kVK_ANSI_1)
            }
            for argument in ["--test-missing-skylight", "--test-failed-hide", "--test-capture-ui", "--test-failed-relaunch", "--test-short-restart-wait"] {
                try #require(try run([appExecutable.path, "--check-permission", argument], timeout: margin).status == 2)
            }
            try #require(try run([appExecutable.path, "--check-permission", "--test-fixture-only", "--test-unknown"], timeout: margin).status == 2)
            let output = root.appending(path: ".work/daily-journey-arguments")
            defer { try? FileManager.default.removeItem(at: output) }
            try run([buildTool.path, "--variant", "daily", "--output-dir", output.path], timeout: 600, check: true)
            let executable = output.appending(path: "Tessel.app/Contents/MacOS/TesselApp")
            for argument in ["--test-fixture-only", "--test-missing-skylight", "--test-failed-hide", "--test-capture-ui", "--test-failed-relaunch", "--test-short-restart-wait"] {
                // Exit before AppKit starts even if an argument guard regresses.
                try #require(try run([executable.path, "--check-permission", argument], timeout: margin).status == 2)
            }
        }
    }

    /// The CLI itself must wait for readiness. Polling here could hide a command
    /// that returned as soon as LaunchServices accepted the launch.
    private func restartThroughCLI() throws -> Status {
        let old = harness.appPID
        let result = try harness.invoke("restart")
        try #require(result.status == 0 && result.error.isEmpty)
        let ready = try harness.status()
        try #require(ready.pid != old)
        try #require(result.output == "Tessel restarted (pid \(ready.pid))\n")
        harness.trackRestartedApp(ready.pid)
        try requireFinalState("the old instance exits, leaving exactly the CLI's ready replacement") {
            processIDs(appExecutable) == [ready.pid] && kill(old, 0) == -1 && errno == ESRCH
        }
        return ready
    }
}

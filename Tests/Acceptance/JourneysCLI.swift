import Darwin
import Foundation
import OSLog
import Testing

extension Acceptance.Journeys {
    @Test("#62 E1: a workspace key logs its command before each changed window with exact JSON entry fields")
    func logOrdersCommandBeforeChangedWindows() throws {
        let reports = try diagnosticReportsDirectory()
        let window = try fixture.open(key: "diagnosticWindow")
        try desktop.activate(key: "diagnosticWindow")
        try desktop.configure("[animation]\nduration = 0\n", layout: "carousel")
        try requireFinalState("the diagnostic fixture is visible on workspace 1") {
            try harness.row(window)?.workspace == 1 && harness.row(window)?.visible == true
        }
        let pid = harness.appPID
        let baseline = try ownLogEntries(pid: pid, reports: reports).count
        try desktop.key(2)
        try requireFinalState("the workspace key hid its fixture") {
            try harness.status().workspaces?.active == 2 && harness.row(window)?.visible == false
        }
        var entries: [DiagnosticLogEntry] = []
        try requireFinalState("the workspace command and its window change are persisted") {
            entries = Array(try ownLogEntries(pid: pid, reports: reports).dropFirst(baseline))
            return entries.contains { $0.category == "commands" && $0.message.contains("workspace 2") }
                && entries.contains { $0.category == "windows" && $0.message.contains("after command workspace 2") }
        }
        let commands = entries.indices.filter { entries[$0].category == "commands" && entries[$0].message.contains("workspace 2") }
        let windows = entries.indices.filter { entries[$0].category == "windows" && entries[$0].message.contains("after command workspace 2") }
        try #require(commands.count == 1 && windows.count == 1, "one command and one changed fixture must be recorded")
        try #require(commands[0] < windows[0])
        try #require(entries[windows[0]].message.range(of: "\\b\(window)\\b", options: .regularExpression) != nil)
        try #require(entries[commands[0]].level == "notice" && entries[windows[0]].level == "notice")
    }

    @Test("#62 E2: neither log format exposes the fixture's secret title")
    func logOmitsWindowTitlesInBothFormats() throws {
        let title = "Fixture secret 1234"
        let reports = try diagnosticReportsDirectory()
        let window = try fixture.open(key: "privateDiagnostic", ["title": title])
        try desktop.activate(key: "privateDiagnostic")
        try requireFinalState("the titled fixture is catalogued") { try harness.row(window) != nil }
        var own: [DiagnosticLogEntry] = []
        try requireFinalState("this instance's log includes the titled fixture") {
            own = try ownLogEntries(pid: harness.appPID, reports: reports)
            return own.contains { $0.category == "windows" && $0.message.range(of: "\\b\(window)\\b", options: .regularExpression) != nil }
        }
        try #require(own.allSatisfy { !$0.message.contains(title) }, "JSON messages must omit the fixture title")
        for flags in [[], ["--json"]] {
            let result = try harness.invoke(["log", "--last", "5m", "--reports", reports.path] + flags)
            try #require(result.status == 0, "tessel log must accept the requested format (exit \(result.status))")
            let leaked = (result.output + result.error).contains(title)
            try #require(!leaked, "neither format may contain the invented fixture title")
        }
    }

    @Test("#62 E10: posted lock and unlock notifications appear in order in the system category")
    func logRecordsLockAndUnlockNotifications() throws {
        let reports = try diagnosticReportsDirectory()
        let pid = harness.appPID
        let baseline = try ownLogEntries(pid: pid, reports: reports).count
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(Notification.Name("com.apple.screenIsLocked"), object: nil, userInfo: nil, deliverImmediately: true)
        try requireFinalState("the harness's lock notification is persisted") {
            try ownLogEntries(pid: pid, reports: reports).dropFirst(baseline).contains { $0.category == "system" && $0.message == "screen locked" }
        }
        center.postNotificationName(Notification.Name("com.apple.screenIsUnlocked"), object: nil, userInfo: nil, deliverImmediately: true)
        var events: [DiagnosticLogEntry] = []
        try requireFinalState("the harness's unlock notification is persisted") {
            events = try ownLogEntries(pid: pid, reports: reports).dropFirst(baseline).filter {
                $0.category == "system" && ["screen locked", "screen unlocked"].contains($0.message)
            }
            return events.contains { $0.message == "screen unlocked" }
        }
        try #require(events.map(\.message) == ["screen locked", "screen unlocked"])
        try #require(events.allSatisfy { $0.level == "notice" })
    }

    @Test("#62 E12: log remains readable after its instance quits and ends that run with a quit notice")
    func logReadsTheRunAfterQuit() throws {
        let reports = try diagnosticReportsDirectory()
        let window = try fixture.open(key: "quitDiagnostic")
        try requireFinalState("the quit fixture is catalogued") { try harness.row(window) != nil }
        let pid = harness.appPID
        let before = try ownLogEntries(pid: pid, reports: reports)
        try #require(!before.isEmpty, "the run must have entries before Quit")
        harness.stopApp()
        try #require(!harness.appIsRunning)
        var after: [DiagnosticLogEntry] = []
        try requireFinalState("the stopped instance's final quit entry is readable") {
            after = try ownLogEntries(pid: pid, reports: reports)
            return after.last?.message == "quit"
        }
        try #require(after.count > before.count && after.last?.level == "notice")
        try #require(Array(after.prefix(before.count)) == before, "Quit preserves the earlier entries of this run")
        let text = try harness.invoke("log", "--last", "5m", "--reports", reports.path)
        try #require(text.status == 0, "text log must also work with Tessel stopped")
        try requireDiagnosticTextLines(text.output, including: after)
    }

    @Test("#62 E13: log lists only this bundle's crash report inside the requested window with its path and date")
    func logFiltersCrashReportsByBundleAndDate() throws {
        let reports = try diagnosticReportsDirectory()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let date = now.addingTimeInterval(-60)
        let kept = try writeDiagnosticReport(in: reports, name: "inside", bundleID: "com.taecontrol.tessel.dev", date: date)
        let old = try writeDiagnosticReport(in: reports, name: "outside", bundleID: "com.taecontrol.tessel.dev", date: now.addingTimeInterval(-600))
        let other = try writeDiagnosticReport(in: reports, name: "other", bundleID: "com.example.other", date: date)
        let document = try diagnosticLog(["--last", "5m"], reports: reports)
        _ = try document.entries(for: harness.appPID)
        try #require(document.crashReports.count == 1)
        let report = try #require(document.crashReports.first)
        try #require(Set(report.keys) == ["path", "date"] && report["path"] as? String == kept.path)
        try #require(diagnosticDate(report["date"], represents: date), "the reported date comes from the report header")
        let text = try harness.invoke("log", "--last", "5m", "--reports", reports.path)
        try #require(text.status == 0)
        try #require(text.output.contains(kept.path) && !text.output.contains(old.path) && !text.output.contains(other.path))
        let lines = text.output.components(separatedBy: .newlines)
        let pathIndex = try #require(lines.firstIndex { $0.contains(kept.path) })
        try #require(lines[..<pathIndex].contains { $0.lowercased().contains("crash report") }, "text lists paths under a crash-report heading")
    }

    @Test("#62 E14: log accepts minutes, hours and days, defaults to one hour, and rejects bad arguments with usage")
    func logDurationWindowsAndArgumentErrors() throws {
        let reports = try diagnosticReportsDirectory()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var paths: [String] = []
        let ages: [TimeInterval] = [15 * 60, 45 * 60, 3 * 3600, 24 * 3600, 3 * 24 * 3600]
        for (index, age) in ages.enumerated() {
            paths.append(try writeDiagnosticReport(in: reports, name: "age-\(index)", bundleID: "com.taecontrol.tessel.dev",
                                                   date: now.addingTimeInterval(-age)).path)
        }
        for (flags, count) in [(["--last", "30m"], 1), (["--last", "6h"], 3), (["--last", "2d"], 4), ([], 2)] {
            let document = try diagnosticLog(flags, reports: reports)
            let entries = try document.entries(for: harness.appPID)
            try #require(Set(document.crashReports.compactMap { $0["path"] as? String }) == Set(paths.prefix(count)),
                         "the report window must match \(flags.isEmpty ? "the one-hour default" : flags.joined(separator: " "))")
            let text = try harness.invoke(["log", "--reports", reports.path] + flags)
            try #require(text.status == 0)
            try requireDiagnosticTextLines(text.output, including: entries)
        }
        for flags in [["--last", "0m"], ["--last", "5x"], ["--last"], ["--unknown"]] {
            let result = try harness.invoke(["log"] + flags)
            try #require(result.status == 2 && result.error.contains("Usage: tessel"), "invalid log arguments must exit 2 with usage")
        }
    }

    @Test("#62 E17: a completed harness run writes no entries into the daily subsystem")
    func harnessDiagnosticsNeverEnterTheDailySubsystem() throws {
        let began = Date()
        let pid = harness.appPID
        let window = try fixture.open(key: "namespaceDiagnostic")
        try desktop.activate(key: "namespaceDiagnostic")
        try requireFinalState("the namespace fixture is managed") { try harness.row(window) != nil }
        try desktop.key(2)
        try requireFinalState("the namespace workspace command completed") { try harness.status().workspaces?.active == 2 }
        harness.stopApp()
        try #require(!harness.appIsRunning)
        let count = try diagnosticEntryCount(subsystem: "com.taecontrol.tessel", pid: pid, from: began, through: Date())
        try #require(count == 0, "the daily subsystem must contain no entry from the harness PID")
    }

    private func diagnosticReportsDirectory() throws -> URL {
        let directory = harness.directory.appending(path: "diagnostic-reports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func diagnosticLog(_ flags: [String], reports: URL) throws -> DiagnosticLogDocument {
        let result = try harness.invoke(["log", "--json", "--reports", reports.path] + flags)
        try #require(result.status == 0, "tessel log must accept the query (exit \(result.status))")
        return try DiagnosticLogDocument(result.outputData)
    }

    private func ownLogEntries(pid: Int32, reports: URL) throws -> [DiagnosticLogEntry] {
        try diagnosticLog(["--last", "5m"], reports: reports).entries(for: pid)
    }

    @Test("CLI and config files journey")
    func cliAndConfigFiles() throws {
        let window = try fixture.open(["title": "Fixture secret 1234"])
        try requireFinalState("the fixture listed for CLI queries") { try harness.row(window) != nil }
        try step("#1 E10 neither CLI format exposes window titles") {
            for flags in [[], ["--json"]] {
                let result = try harness.invoke(["windows"] + flags)
                let leaked = (result.output + result.error).contains("Fixture secret 1234")
                try #require(result.status == 0 && !leaked, "CLI output must omit fixture titles")
            }
            let result = try harness.invoke("windows", "--json")
            let objects = try JSONSerialization.jsonObject(with: result.outputData) as? [[String: Any]] ?? []
            let keys = objects.first { ($0["id"] as? NSNumber)?.uint32Value == window && $0["bundleId"] as? String == fixtureID }
                .map { Set($0.keys) }
            try #require(keys == ["id", "app", "bundleId", "state", "reason", "tabs", "workspace", "visible", "rail", "slot", "answeredAt"])
        }
        try step("#1 E12; #55 E12 status reports permission, config path, error line, version and development login-item unavailability") {
            let status = try harness.status()
            try #require(status.openAtLogin == Status.OpenAtLogin(state: "unavailable", reason: "development build"))
            try #require(status.permission == "granted" && status.config.path == harness.configFile.path)
            try #require(status.config.state == "defaults" && status.version.hasPrefix("0.1.0"))
            try desktop.writeConfig("[experiments]\nunknown = true\n")
            try requireFinalState("the config error and its source line in status") {
                let config = try harness.status().config
                return config.state == "error" && config.error?.line == 2
            }
            try desktop.expectMenu("Configuration error (line 2)")
            try FileManager.default.removeItem(at: harness.configFile)
            try requireFinalState("config returned to defaults after the error") { try harness.status().config.state == "defaults" }
        }
        try step("CLI reports a stalled or absent app (wiring)") {
            @MainActor func failure() throws -> ProcessResult {
                guard let result = try finalValue({
                    let result = try harness.invoke("windows")
                    return result.status != 0 ? result : nil
                }) else { throw HarnessError("the CLI did not fail within the final-state margin") }
                return result
            }
            kill(harness.appPID, SIGSTOP)
            do {
                defer { kill(harness.appPID, SIGCONT) }
                let result = try failure()
                try #require(result.status != 0 && result.error.contains("Tessel is not responding"), "a stalled server must not hang the CLI")
            }
            harness.stopApp()
            let result = try failure()
            try #require(result.status != 0 && result.error.contains("Tessel is not running"))
            try harness.startApp(fixtureReady: false)
            try requireFinalState("the same fixture observed after restarting") { try harness.row(window) != nil }
        }
        try step("#1 U-cli-args unsupported commands and arguments fail with usage") {
            for arguments in [[], ["move"], ["windows", "--titles"], ["status", "--json", "extra"]] {
                let result = try harness.invoke(arguments)
                try #require(result.status == 2 && result.error.contains("Usage: tessel"))
            }
        }
        try step("#1 U-private-transport the endpoint is private to its Unix user") {
            let endpoint = try harness.endpoint()
            for (path, mode) in [(endpoint, mode_t(0o600)), ((endpoint as NSString).deletingLastPathComponent, mode_t(0o700))] {
                var info = stat()
                try #require(stat(path, &info) == 0)
                try #require(info.st_uid == getuid() && info.st_mode & 0o7777 == mode)
            }
            if onDisposableRunner {
                let shared = URL(fileURLWithPath: "/private/tmp/tessel-journey-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
                defer { try? FileManager.default.removeItem(at: shared) }
                let probe = shared.appending(path: "NativeContracts")
                try FileManager.default.copyItem(at: try harness.contractsExecutable(), to: probe)
                try #require(chmod(probe.path, 0o755) == 0)
                let denied = try run(["sudo", "-n", "-u", "nobody", probe.path, "connect", endpoint], timeout: margin)
                try #require(denied.status == 0, "a different Unix user must be denied access")
            }
        }
        try step("#1 U-read-only-transport mutation requests are rejected") {
            let client = try StreamClient(path: try harness.endpoint(), timeout: margin)
            try client.send(Data("move\n".utf8))
            let response = try JSONSerialization.jsonObject(with: try client.readLine(limit: 4096)) as? [String: Any]
            let rejected = (response?["error"] as? String)?.contains("read-only") == true
            try #require(rejected)
        }
        try step("#1 U-stalled-clients malformed and stalled clients cannot block queries") {
            for payload in [Data(), Data(repeating: 0x78, count: 33), Data(repeating: 0x78, count: 33) + Data([0x0a]), Data([0xff, 0x0a])] {
                let client = try StreamClient(path: try harness.endpoint(), timeout: margin)
                try client.send(payload)
                try requireFinalState("status still available beside a stalled client") { try harness.status().permission == "granted" }
                try #require(try client.receive(1).isEmpty, "malformed or stalled clients must be disconnected")
            }
        }
        try step("#1 U-observer-identity the observer rejects a replaced fixture while its PID lives") {
            let target = try FixtureSession(directory: harness.directory, number: 98)
            let pid = target.pid
            var replaced = false
            defer {
                if replaced {
                    _ = finalState { kill(pid, 0) != 0 }
                    target.disconnect()
                } else { target.stop() }
            }
            _ = try harness.observer.command("observe", ["pids": [pid]])
            try target.command("replaceProcess")
            replaced = true
            try requireFinalState("the observer rejected replaced code") {
                do { _ = try harness.observer.command("observe", ["pids": [pid]]) }
                catch let error as HarnessError where error.description == "the observer accepts fixture processes only" { return true }
                return false
            }
            try #require(kill(pid, 0) == 0, "the observer must reject replaced code before its PID exits")
        }
        try step("#1 U-cpu-oracle resource CPU agrees with the process CPU clock") {
            let before = try resources(getpid()).cpuNanoseconds
            let clock = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            while clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - clock < 20_000_000 {}
            let after = try resources(getpid()).cpuNanoseconds
            let elapsed = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - clock)
            try #require(Double(after - before) > elapsed * 0.75 && Double(after - before) < elapsed * 1.25)
        }
        try step("#1 U-notification-retries native retries and symlinked bundle namespaces hold") {
            let executable = try harness.contractsExecutable()
            let contract = try run([executable.path], timeout: margin)
            try #require(contract.status == 0, "native subscription retry contract failed")
            func endpoint(_ command: URL, _ environment: [String: String]) throws -> String {
                let result = try run([command.path, "namespace"], environment: environment, timeout: margin)
                guard result.status == 0 else { throw HarnessError("the native namespace probe failed") }
                return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var namespaces: [String] = []
            var secondary = executable
            for index in 0..<2 {
                let bundle = harness.directory.appending(path: "Generic Journey \(index).app")
                let macOS = bundle.appending(path: "Contents/MacOS")
                try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
                try writeInfoPlist(["CFBundleIdentifier": "org.example.journey.\(index)", "CFBundleExecutable": "Primary", "CFBundlePackageType": "APPL"],
                                   to: bundle.appending(path: "Contents/Info.plist"))
                try FileManager.default.copyItem(at: executable, to: macOS.appending(path: "Primary"))
                secondary = macOS.appending(path: "Secondary")
                try FileManager.default.copyItem(at: executable, to: secondary)
                let alias = harness.directory.appending(path: "journey-link-\(index)")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondary)
                let direct = try endpoint(secondary, harness.environment)
                namespaces.append(direct)
                try #require(try endpoint(alias, harness.environment) == direct, "a symlink must preserve the bundle namespace")
            }
            try #require(namespaces[0] != namespaces[1], "different bundles must have separate endpoints")
            var alternate = harness.environment
            alternate["XDG_CONFIG_HOME"] = harness.directory.appending(path: "alternate-config").path
            try #require(try endpoint(secondary, alternate) != namespaces[1], "different configs must have separate endpoints")
        }
    }
}

private struct DiagnosticLogEntry: Equatable {
    let level: String
    let category: String
    let message: String
    // Keep date representation opaque: the contract specifies a date field,
    // not a particular JSON date encoding.
    let date: String
}

private struct DiagnosticLogDocument {
    let rawEntries: [[String: Any]]
    let crashReports: [[String: Any]]

    init(_ data: Data) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try #require(Set(object.keys) == ["entries", "crashReports"])
        rawEntries = try #require(object["entries"] as? [[String: Any]])
        crashReports = try #require(object["crashReports"] as? [[String: Any]])
    }

    func entries(for pid: Int32) throws -> [DiagnosticLogEntry] {
        // A development log contains other harness runs and manual sessions.
        // Select this run before judging entry fields or message ordering.
        try rawEntries.filter { ($0["pid"] as? NSNumber)?.int32Value == pid }.map { entry in
            try #require(Set(entry.keys) == ["date", "level", "category", "pid", "message"])
            let level = try #require(entry["level"] as? String)
            try #require(["notice", "error"].contains(level))
            let date = try #require(entry["date"])
            try #require(date is String || date is NSNumber, "a log entry needs a date")
            return DiagnosticLogEntry(level: level, category: try #require(entry["category"] as? String),
                                      message: try #require(entry["message"] as? String), date: String(describing: date))
        }
    }
}

private func requireDiagnosticTextLines(_ text: String, including entries: [DiagnosticLogEntry]) throws {
    for entry in entries {
        let suffix = " \(entry.level) \(entry.category) \(entry.message)"
        let lines = text.components(separatedBy: .newlines).filter { $0.hasSuffix(suffix) }
        try #require(lines.contains { $0.range(of: #"^\d{2}:\d{2}:\d{2} "#, options: .regularExpression) != nil },
                     "each own-PID entry has an HH:MM:SS level category message text line")
    }
}

private func writeDiagnosticReport(in directory: URL, name: String, bundleID: String, date: Date) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
    let header: [String: Any] = ["app_name": "TesselApp", "bundleID": bundleID, "timestamp": formatter.string(from: date), "bug_type": "309"]
    let file = directory.appending(path: "TesselApp-\(name).ips")
    try (JSONSerialization.data(withJSONObject: header) + Data("\n{}\n".utf8)).write(to: file)
    return file
}

private func diagnosticDate(_ value: Any?, represents expected: Date) -> Bool {
    if let number = value as? NSNumber {
        return abs(number.doubleValue - expected.timeIntervalSince1970) < 1
            || abs(number.doubleValue - expected.timeIntervalSinceReferenceDate) < 1
    }
    guard let text = value as? String else { return false }
    let iso = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
        iso.formatOptions = options
        if let date = iso.date(from: text), abs(date.timeIntervalSince(expected)) < 1 { return true }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
    return formatter.date(from: text).map { abs($0.timeIntervalSince(expected)) < 1 } == true
}

// Read only a known instance's subsystem/PID and count entries. Never expose
// another instance's messages in a negative assertion's failure output.
func diagnosticEntryCount(subsystem: String, pid: Int32, from start: Date, through end: Date) throws -> Int {
    let store = try OSLogStore.local()
    let entries = try store.getEntries(at: store.position(date: start), matching: NSPredicate(format: "subsystem == %@", subsystem))
    return entries.reduce(0) { count, entry in
        guard let entry = entry as? OSLogEntryLog, entry.processIdentifier == pid,
              entry.date >= start, entry.date <= end else { return count }
        return count + 1
    }
}

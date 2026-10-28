import Darwin
import Foundation
import Testing

extension Acceptance.Journeys {
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
                try #require(result.status != 0 && result.error.contains("tessel is not responding"), "a stalled server must not hang the CLI")
            }
            harness.stopApp()
            let result = try failure()
            try #require(result.status != 0 && result.error.contains("tessel is not running"))
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

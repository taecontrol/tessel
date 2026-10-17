import Darwin
import Foundation
import Testing

/// The accepted #1 examples, exercised at the shipped CLI boundary.
/// Suites run one at a time: they share one desktop, app instance, and fixture.
@Suite(.serialized)
enum Acceptance {}

/// Helpers shared by suites that run inside an `AppSession`.
/// Keep raw CLI output out of `#expect`: a failure prints every captured value.
@MainActor
protocol AppSessionTest {}

extension AppSessionTest {
    var harness: Harness { Harness.shared }
    var fixture: FixtureSession { harness.fixture }

    @discardableResult
    func expectState(_ id: UInt32, _ state: String, _ reason: String? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> Row {
        let row = try eventualValue { try harness.row(id).flatMap { $0.state == state ? $0 : nil } }
        let found = try #require(row, "fixture window \(id) did not become \(state) within 500 ms", sourceLocation: sourceLocation)
        if let reason { #expect(found.reason.contains(reason), sourceLocation: sourceLocation) }
        return found
    }

    /// Whether the fixture's rows reach a state within the deadline.
    func converges(within timeout: Double = 0.5, _ predicate: ([Row]) -> Bool) throws -> Bool {
        try eventually(within: timeout) { predicate(try harness.rows()) }
    }

    func states(_ rows: [Row]) -> [UInt32: String] {
        Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { $1 })
    }

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: harness.configFile)
    }
}

extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct Functional: AppSessionTest {
        init() throws { try Harness.shared.reset() }

        static func tiles(_ kind: String) -> Bool { ["standard", "noFullscreen"].contains(kind) }

        @Test func observerRejectsAReplacedFixtureBeforeReadingWindows() throws {
            let target = try FixtureSession(directory: harness.directory, number: 98)
            let pid = target.pid
            var replaced = false
            defer {
                if replaced {
                    // The replacement exits itself. Never signal a reused PID.
                    _ = eventually(within: 3) { kill(pid, 0) != 0 }
                    target.disconnect()
                } else { target.stop() }
            }
            _ = try harness.observer.command("observe", ["pids": [pid]])
            try target.command("replaceProcess")
            replaced = true
            let refused = try eventually(within: 1) {
                do { _ = try harness.observer.command("observe", ["pids": [pid]]) }
                catch let error as HarnessError where error.description == "the observer accepts fixture processes only" {
                    return true
                }
                return false
            }
            #expect(refused)
            #expect(kill(pid, 0) == 0, "the observer must reject replaced code while its PID is still alive")
        }

        @Test func e01StandardResizableWindowTilesWithReason() throws {
            try expectState(try fixture.open(), "tiled", "standard window")
        }

        @Test func e02FullscreenButtonIsNotAClassificationSignal() throws {
            let window = try fixture.open(kind: "noFullscreen")
            try expectState(window, "tiled", "standard window")
            let observed = try #require(try harness.probe().first { $0.id == window })
            #expect(observed.subrole == "AXStandardWindow")
            #expect(observed.fullscreen == "none")
            #expect(observed.sizeSettable)
        }

        @Test func e03NonresizableWindowFloatsWithFixedSizeReason() throws {
            let window = try fixture.open(kind: "fixed")
            try expectState(window, "floats", "fixed size")
            let observed = try #require(try harness.probe(resizing: window).first { $0.id == window })
            #expect(!observed.sizeSettable)
            #expect(observed.resizeError == -25200)
        }

        @Test(arguments: ["dialog", "panel", "sheet"])
        func e04DialogPanelAndSheetFloatWithSubrole(kind: String) throws {
            let window = try fixture.open(kind: kind)
            try expectState(window, "floats")
            let observed = try harness.probe()
            let flattened = observed + observed.flatMap(\.sheets)
            let subrole = try #require(flattened.first { $0.id == window }?.subrole)
            #expect(subrole != "AXStandardWindow")
            try expectState(window, "floats", subrole)
            let fixtureIDs = Set(try fixture.command("ping").windows.values)
            #expect(try converges { $0.count == fixtureIDs.count && Set($0.map(\.id)) == fixtureIDs })
        }

        @Test func e05NativeTabsKeepOneFrontEntryAndExposeMinimizedAXEntries() throws {
            let reply = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3])
            let first = try #require(reply.windows["tabs0"])
            try #require(try converges { $0.count == 1 && $0[0].tabs == 3 })
            #expect(try harness.rows()[0].reason.contains("3 native tabs"))
            var observed = try harness.probe()
            try #require(observed.count == 1, "fixture must match Terminal's one-front-tab AX signature")
            #expect(observed[0].tabs == 3)
            let before = observed[0].id
            let second = try #require(reply.windows["tabs1"])
            try fixture.command("tab", ["key": "tabs1"])
            try #require(try converges { $0.count == 1 && $0[0].id == second })
            observed = try harness.probe()
            try #require(observed.count == 1)
            #expect(observed[0].id != before)
            try fixture.command("addTab", ["key": "tabs3", "reference": "tabs1"])
            try #require(try converges { $0.count == 1 && $0[0].tabs == 4 })
            try fixture.command("close", ["key": "tabs3"])
            try #require(try converges { $0.count == 1 && $0[0].tabs == 3 })
            try fixture.command("tab", ["key": "tabs0"])
            try expectState(first, "tiled")
            try fixture.command("hide")
            try #require(try converges { $0.count == 1 && $0[0].state == "hidden" && $0[0].tabs == 3 })
            try fixture.command("show")
            try #require(try converges { $0.count == 1 && $0[0].state == "tiled" && $0[0].tabs == 3 })
            try fixture.command("minimize", ["key": "tabs0"])
            let group = Set(try (0..<3).map { try #require(reply.windows["tabs\($0)"]) })
            try #require(try converges { $0.count == 3 && Set($0.map(\.id)) == group && $0.allSatisfy { $0.state == "minimized" } })
            #expect(try harness.rows().map(\.tabs).sorted() == [1, 1, 3])
            #expect(Set(try harness.probe().map(\.id)) == group)
            // An unrelated minimized window must never be guessed into the group.
            let separate = try fixture.open(key: "separate")
            try fixture.command("minimize", ["key": "separate"])
            try #require(try converges {
                $0.count == 4 && Set($0.map(\.id)) == group.union([separate]) && $0.allSatisfy { $0.state == "minimized" }
            })
            try fixture.command("close", ["key": "separate"])
            try fixture.command("restore", ["key": "tabs0"])
            try #require(try converges { $0.count == 1 && $0[0].state == "tiled" && $0[0].tabs == 3 })
            for key in ["tabs0", "tabs1", "tabs2"] { try fixture.command("close", ["key": key]) }
            #expect(try converges { $0.isEmpty })
        }

        @Test func e05ReplacingNativeTabFrontDuringInsertionKeepsOneEntry() throws {
            let group = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3])
            try #require(try converges { $0.count == 1 && $0[0].tabs == 3 })
            // Insertion can briefly leave AXWindows pointing at the old front
            // while AXFocusedWindow already identifies its replacement.
            for _ in 0..<20 {
                let front = try #require(try harness.rows().first?.id)
                let target = try #require((0..<3).map { "tabs\($0)" }.first { group.windows[$0] != front })
                try fixture.command("tab", ["key": target])
                try fixture.command("addTab", ["key": "inserted", "reference": target])
                try #require(try converges { $0.count == 1 && $0[0].tabs == 4 })
                try fixture.command("close", ["key": "inserted"])
                try #require(try converges { $0.count == 1 && $0[0].tabs == 3 })
            }
        }

        @Test func e05FocusedNativeTabReplacementSurvivesLaggingWindowList() throws {
            let group = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3])
            let first = try #require(group.windows["tabs0"])
            let selected = try #require(group.windows["tabs1"])
            try #require(try converges { $0.count == 1 && $0[0].id == first && $0[0].tabs == 3 })
            // AXWindows can retain the old front while AXFocusedWindow exposes
            // the uncached replacement. Keep that ordering stable instead of
            // hoping a normal tab transition lands between two AX requests.
            try fixture.command("windowList", ["keys": ["tabs0"]])
            let changed = try fixture.command("tab", ["key": "tabs1"])
            #expect(changed.nativeTabs["tabs1"] == 3)
            try #require(try converges { $0.count == 1 && $0[0].id == selected && $0[0].tabs == 3 })
        }

        @Test func e05FormerNativeRootIsRetiredAfterLosingItsBarBeforeFocusMoves() throws {
            let group = try fixture.command("open", ["kind": "tabs", "key": "tabs", "count": 3])
            let first = try #require(group.windows["tabs0"])
            let selected = try #require(group.windows["tabs1"])
            try #require(try converges { $0.count == 1 && $0[0].id == first && $0[0].tabs == 3 })
            // A read can find the former root without its bar before it can
            // identify the successor. Hold that ordering with real AppKit tabs.
            try fixture.command("windowList", ["keys": ["tabs0"]])
            try fixture.command("focusedWindow", ["published": false])
            let changed = try fixture.command("tab", ["key": "tabs1"])
            #expect(changed.nativeTabs["tabs1"] == 3)
            try #require(try converges { $0.count == 1 && $0[0].id == first && $0[0].tabs == 1 },
                         "the former root must be observed without its native bar")
            try fixture.command("focusedWindow", ["published": true])
            try #require(try converges { $0.count == 1 && $0[0].id == selected && $0[0].tabs == 3 })
        }

        @Test(arguments: ["emptyContentTabs", "contentTabs", "segmentedTabs"])
        func e05ContentTabsDoNotCountAsNativeWindowTabs(kind: String) throws {
            let reply = try fixture.command("open", ["kind": kind, "key": "content"])
            #expect(reply.nativeTabs["content"] == 1)
            #expect(reply.contentPages["content"] == 3)
            let window = try #require(reply.windows["content"])
            let row = try expectState(window, "tiled", "standard window")
            #expect(row.tabs == 1)
            #expect(!row.reason.contains("native tabs"))
            if kind != "segmentedTabs" {
                #expect(try harness.probe().first { $0.id == window }?.tabs == 3)
            }
        }

        enum NativeTabCase: String, CaseIterable, Sendable {
            case mixed, plus, nonclosableStartup

            var options: [String: Any] {
                switch self {
                case .mixed: ["windowKind": "manyContentTabs"]
                case .plus: ["windowKind": "newTabButton"]
                case .nonclosableStartup: ["closable": false]
                }
            }
        }

        @Test(arguments: NativeTabCase.allCases)
        func e05NativeTabCountIgnoresContentAndExtraControls(_ tabCase: NativeTabCase) throws {
            let startup = tabCase == .nonclosableStartup
            if startup { harness.stopApp() }
            defer { if startup && !harness.appIsRunning { try? harness.startApp() } }
            let reply = try fixture.command("open", tabCase.options.merging(["kind": "tabs", "key": "group", "count": 3]) { $1 })
            #expect(Set(reply.nativeTabs.values) == [3])
            if tabCase == .mixed { #expect(Set(reply.contentPages.values) == [5]) }
            if startup { try harness.startApp(fixtureReady: false) }
            try #require(try converges { $0.count == 1 && $0[0].tabs == 3 })
            #expect(try harness.rows()[0].reason.contains("3 native tabs"))
            let observed = try harness.probe()
            try #require(observed.count == 1)
            if tabCase == .plus { #expect(observed[0].extraTabButtons == 1) }
            if startup {
                #expect(Set(reply.closable.values) == [false])
                #expect(observed[0].perTabButtons == 0)
            }
            try fixture.command("tab", ["key": "group1"])
            let second = try #require(reply.windows["group1"])
            #expect(try converges { $0.count == 1 && $0[0].id == second && $0[0].tabs == 3 })
        }

        @Test func e06MinimizedAndHiddenTakePrecedenceAndRestore() throws {
            var ids: [String: UInt32] = [:]
            for kind in ["standard", "noFullscreen", "fixed", "dialog", "panel"] {
                let window = try fixture.open(kind: kind, key: kind)
                ids[kind] = window
                let expected = Self.tiles(kind) ? "tiled" : "floats"
                try expectState(window, expected)
                try fixture.command("minimize", ["key": kind])
                try expectState(window, "minimized")
                try fixture.command("restore", ["key": kind])
                try expectState(window, expected)
            }
            try fixture.command("hide")
            try #require(try converges { $0.count == ids.count && $0.allSatisfy { $0.state == "hidden" } })
            try fixture.command("show")
            let restored = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, Self.tiles($0.key) ? "tiled" : "floats") })
            try #require(try converges { states($0) == restored })
            let fixed = try #require(ids["fixed"])
            try fixture.command("minimize", ["key": "fixed"])
            try expectState(fixed, "minimized")
            try fixture.command("hide")
            let hidden = Dictionary(uniqueKeysWithValues: ids.filter { $0.key != "fixed" }.map { ($0.value, "hidden") })
            let snapshot = try eventualValue { () throws -> [Row]? in
                let rows = try harness.rows()
                return states(rows.filter { $0.id != fixed }) == hidden ? rows : nil
            }
            let rows = try #require(snapshot, "fixture did not reach the hidden state within 500 ms")
            #expect(states(rows) == hidden.merging([fixed: "minimized"]) { $1 })
            try fixture.command("show")
            try fixture.command("restore", ["key": "fixed"])
            try expectState(fixed, "floats", "fixed size")
        }

        @Test func e07NewWindowConvergesWithin500msAndStaysClassified() throws {
            try expectState(try fixture.open(key: "anchor"), "tiled")
            sleep(seconds: 0.55)  // Earlier settling must not observe the new window.
            let window = try fixture.open(kind: "noFullscreen", key: "background", ["background": true])
            let expected = try expectState(window, "tiled")
            sleep(seconds: 0.5)
            for _ in 0..<20 { #expect(try harness.row(window) == expected) }
        }

        @Test func e08ClosedWindowsAndTerminatedAppsDisappearWithin500ms() throws {
            try expectState(try fixture.open(key: "anchor"), "tiled")
            let window = try fixture.open(key: "background", ["background": true])
            try expectState(window, "tiled")
            sleep(seconds: 0.55)  // A settling or focus event must not replace destruction.
            try fixture.command("close", ["key": "background", "retain": true])
            #expect(try eventually { try harness.row(window) == nil })
            let other = try FixtureSession(directory: harness.directory, number: 1)
            harness.otherFixtures.append(other)
            let quit = try other.open(key: "quit")
            try expectState(quit, "tiled")
            other.stop()
            harness.otherFixtures.removeAll { $0 === other }
            #expect(try eventually { try harness.row(quit) == nil })
        }

        @Test func e09StartupDiscoversExistingWindowsAndNativeTabGroups() throws {
            harness.stopApp()
            defer { if !harness.appIsRunning { try? harness.startApp(fixtureReady: false) } }
            var expected: [UInt32: String] = [:]
            for kind in ["standard", "noFullscreen", "fixed", "dialog", "panel", "sheet"] {
                expected[try fixture.open(kind: kind, key: kind)] = Self.tiles(kind) ? "tiled" : "floats"
                if kind == "sheet" {
                    expected[try #require(try fixture.command("ping").windows["sheetParent"])] = "tiled"
                }
            }
            let reply = try fixture.command("open", ["kind": "tabs", "key": "existingTabs", "count": 3])
            expected[try #require(reply.windows["existingTabs0"])] = "tiled"
            try harness.startApp(fixtureReady: false)
            for (window, state) in expected { try expectState(window, state) }
            #expect(try harness.rows().filter { $0.tabs == 3 }.count == 1)
            let before = try harness.rows()
            harness.stopApp()
            try harness.startApp(fixtureReady: false)
            try #require(try converges { $0 == before })
            harness.stopApp()
            try fixture.command("minimize", ["key": "fixed"])
            try fixture.command("minimize", ["key": "existingTabs0"])
            try fixture.command("hide")
            try harness.startApp(fixtureReady: false)
            let tabIDs = Set(try (0..<3).map { try #require(reply.windows["existingTabs\($0)"]) })
            var minimized = tabIDs
            minimized.insert(try #require(try fixture.command("ping").windows["fixed"]))
            var expectedStates = Dictionary(before.map { ($0.id, "hidden") }, uniquingKeysWith: { $1 })
            for id in minimized { expectedStates[id] = "minimized" }
            try #require(try converges { states($0) == expectedStates })
            #expect(try harness.rows().filter { tabIDs.contains($0.id) }.map(\.tabs).sorted() == [1, 1, 3])
        }

        @Test func e10NeitherCLIFormatExposesWindowTitles() throws {
            let window = try fixture.open(["title": "Fixture secret 1234"])
            try expectState(window, "tiled")
            for flags in [[], ["--json"]] {
                let result = try harness.invoke(["windows"] + flags)
                let leaked = (result.output + result.error).contains("Fixture secret 1234")
                #expect(result.status == 0)
                #expect(!leaked, "CLI leaked a fixture window title")
            }
            let listing = try harness.invoke("windows", "--json")
            let objects = try JSONSerialization.jsonObject(with: listing.outputData) as? [[String: Any]] ?? []
            let keys = objects.first { ($0["id"] as? NSNumber)?.uint32Value == window && $0["bundleId"] as? String == fixtureID }
                .map { Set($0.keys) }
            #expect(keys == ["id", "app", "bundleId", "state", "reason", "tabs", "workspace", "visible"])
        }

        @Test func e11AbsentAppFailsInUnderOneSecond() throws {
            kill(harness.appPID, SIGSTOP)
            do {
                defer { kill(harness.appPID, SIGCONT) }
                let started = monotonicSeconds()
                let result = try harness.invoke("windows")
                #expect(monotonicSeconds() - started < 1)
                #expect(result.status != 0, "a stalled server must not hang the CLI")
            }
            harness.stopApp()
            defer { try? harness.startApp() }
            let started = monotonicSeconds()
            let result = try harness.invoke("windows")
            #expect(monotonicSeconds() - started < 1)
            #expect(result.status != 0)
            #expect(result.error.contains("tessel is not running"))
        }

        @Test(arguments: [[], ["move"], ["windows", "--titles"], ["status", "--json", "extra"]])
        func cliRejectsUnsupportedCommandsAndArguments(_ arguments: [String]) throws {
            let result = try harness.invoke(arguments)
            #expect(result.status == 2)
            #expect(result.error.contains("Usage: tessel"))
        }

        @Test func transportIsPrivateToTheCurrentUser() throws {
            let endpoint = try harness.endpoint()
            for (path, mode) in [(endpoint, mode_t(0o600)), ((endpoint as NSString).deletingLastPathComponent, mode_t(0o700))] {
                var info = stat()
                try #require(stat(path, &info) == 0)
                #expect(info.st_uid == getuid())
                #expect(info.st_mode & 0o7777 == mode)
            }
            guard onDisposableRunner else { return }
            // Another user needs a readable copy of the probe; the test's directory is private.
            let shared = URL(fileURLWithPath: "/private/tmp/tessel-contract-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            defer { try? FileManager.default.removeItem(at: shared) }
            let probe = shared.appending(path: "NativeContracts")
            try FileManager.default.copyItem(at: try harness.contractsExecutable(), to: probe)
            chmod(probe.path, 0o755)
            let denied = try run(["sudo", "-n", "-u", "nobody", probe.path, "connect", endpoint], timeout: 5)
            #expect(denied.status == 0, "a different Unix user must be denied access")
        }

        @Test func transportRejectsMutations() throws {
            let client = try StreamClient(path: try harness.endpoint(), timeout: 0.9)
            try client.send(Data("move\n".utf8))
            let response = try JSONSerialization.jsonObject(with: try client.readLine(limit: 4096)) as? [String: Any]
            let error = response?["error"] as? String ?? ""
            #expect(error.contains("read-only"))
        }

        @Test(arguments: [Data(), Data(repeating: 0x78, count: 33), Data(repeating: 0x78, count: 33) + Data([0x0a]), Data([0xff, 0x0a])])
        func stalledOrMalformedClientsDoNotBlockQueries(_ payload: Data) throws {
            let client = try StreamClient(path: try harness.endpoint(), timeout: 0.9)
            try client.send(payload)
            let started = monotonicSeconds()
            #expect(try harness.status().permission == "granted")
            #expect(monotonicSeconds() - started < 1)
            #expect(try client.receive(1).isEmpty, "a malformed or stalled client must be disconnected")
        }

        @Test func resourceCPUMeasurementMatchesTheProcessCPUClock() throws {
            let before = try resources(getpid()).cpuNanoseconds
            let clock = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            while clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - clock < 20_000_000 {}
            let after = try resources(getpid()).cpuNanoseconds
            let elapsed = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - clock)
            #expect(Double(after - before) > elapsed * 0.75)
            #expect(Double(after - before) < elapsed * 1.25)
        }

        @Test func nativeNotificationRetriesAndSymlinkedBundleNamespaces() throws {
            // This command-line probe has no tessel bundle ID and never queries AX.
            // It exercises native CF identity and Foundation's bundle resolution.
            let executable = try harness.contractsExecutable()
            let contract = try run([executable.path], timeout: 2)
            #expect(contract.status == 0, "transient AX registrations: \(contract.error)")

            func endpoint(_ command: URL, _ environment: [String: String]) throws -> String {
                let result = try run([command.path, "namespace"], environment: environment, timeout: 2)
                guard result.status == 0 else { throw HarnessError("namespace probe failed: \(result.error)") }
                return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var namespaces: [String] = []
            var secondary = executable
            for index in 0..<2 {
                let bundle = harness.directory.appending(path: "Generic Contract \(index).app")
                let macOS = bundle.appending(path: "Contents/MacOS")
                try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
                try writeInfoPlist(["CFBundleIdentifier": "org.example.foundation-contract.\(index)",
                                    "CFBundleExecutable": "Primary", "CFBundlePackageType": "APPL"],
                                   to: bundle.appending(path: "Contents/Info.plist"))
                try FileManager.default.copyItem(at: executable, to: macOS.appending(path: "Primary"))
                secondary = macOS.appending(path: "Secondary")
                try FileManager.default.copyItem(at: executable, to: secondary)
                let alias = harness.directory.appending(path: "contract-link-\(index)")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondary)
                let direct = try endpoint(secondary, harness.environment)
                namespaces.append(direct)
                #expect(try endpoint(alias, harness.environment) == direct, "a symlink must preserve the bundle's namespace")
            }
            #expect(namespaces[0] != namespaces[1], "different bundles must have separate endpoints")
            var alternate = harness.environment
            alternate["XDG_CONFIG_HOME"] = harness.directory.appending(path: "alternate-config").path
            #expect(try endpoint(secondary, alternate) != namespaces[1], "different configs must have separate endpoints")
        }

        @Test func e12StatusReportsPermissionConfigPathErrorLineAndVersion() throws {
            let status = try harness.status()
            #expect(status.permission == "granted")
            #expect(status.config.path == harness.configFile.path)
            #expect(status.config.state == "defaults")
            #expect(status.version.hasPrefix("0.1.0"))
            try writeConfig("[experiments]\nunknown = true\n")
            let errored = try eventualValue(within: 1) { () throws -> Status? in
                let status = try harness.status()
                return status.config.state == "error" ? status : nil
            }
            #expect(try #require(errored).config.error?.line == 2)
        }

        @Test func e15SignedRebuildPreservesAccessibility() throws {
            let before = try harness.status()
            #expect(before.permission == "granted")
            let window = try fixture.open()
            try expectState(window, "tiled")
            harness.stopApp()
            defer { if !harness.appIsRunning { try? harness.startApp() } }
            try run([buildTool.path], timeout: 600, check: true)
            try harness.startApp()
            let after = try harness.status()
            #expect(after.version != before.version, "the test must exercise a changed binary")
            #expect(after.permission == "granted")
            try expectState(window, "tiled")
        }

        @Test(arguments: [nil, "", "-", "adhoc", "Ad-Hoc", "Sign to run locally", "Unavailable fixture signing identity"] as [String?])
        func e16MissingOrAdhocSigningConfigurationCannotProduceABundle(identity: String?) throws {
            let config = harness.directory.appending(path: "NoIdentity.local.xcconfig")
            try? FileManager.default.removeItem(at: config)
            if let identity { try Data("CODE_SIGN_IDENTITY = \(identity)\n".utf8).write(to: config) }
            let output = harness.directory.appending(path: "unsigned-output-" + UUID().uuidString)
            let result = try run([buildTool.path, "--signing-config", config.path, "--output-dir", output.path], timeout: 2)
            #expect(result.status != 0)
            #expect(result.error.contains("docs/development.md"))
            if identity != "Unavailable fixture signing identity" {
                #expect(result.error.contains("Signing.local.xcconfig"))
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }

        @Test func e16SigningIdentityRequiresExactAvailableNameOrFingerprint() throws {
            // Exercise the build's external-command boundary without touching the
            // keychain or producing a binary with any tessel bundle ID.
            let shims = harness.directory.appending(path: "signing-tools-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: false)
            let marker = harness.directory.appending(path: "signing-command-reached")
            let fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567"
            let name = "Generic Contract Signing Identity"
            let listing = "  1) \(fingerprint) \"\(name)\"\n     1 valid identities found\n"
            let commands = [
                "security": "#!/bin/sh\ncat <<'IDENTITIES'\n" + listing + "IDENTITIES\n",
                "xcrun": "#!/bin/sh\nprintf compiler > \"$TESSEL_SIGNING_PROBE\"\nexit 91\n",
                "codesign": "#!/bin/sh\nprintf signer > \"$TESSEL_SIGNING_PROBE\"\nexit 92\n",
            ]
            for (command, body) in commands {
                FileManager.default.createFile(atPath: shims.appending(path: command).path, contents: Data(body.utf8),
                                               attributes: [.posixPermissions: 0o755])
            }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = shims.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["TESSEL_SIGNING_PROBE"] = marker.path
            let invalid = ["CODE_SIGN_IDENTITY = \t \n", "CODE_SIGN_IDENTITY = \"  \t \"\n",
                           "CODE_SIGN_IDENTITY = \nOTHER_SETTING = ignored\n",
                           "CODE_SIGN_IDENTITY = Contract Signing\n",
                           "CODE_SIGN_IDENTITY = " + fingerprint.prefix(20) + "\n"]
            let valid = ["CODE_SIGN_IDENTITY = \"\(name)\"\n", "CODE_SIGN_IDENTITY = " + fingerprint.lowercased() + "\n"]
            for (index, text) in (invalid + valid).enumerated() {
                try? FileManager.default.removeItem(at: marker)
                let config = harness.directory.appending(path: "GenericIdentity.local.xcconfig")
                try Data(text.utf8).write(to: config)
                let output = harness.directory.appending(path: "signing-boundary-output-\(index)-" + UUID().uuidString)
                let result = try run([buildTool.path, "--signing-config", config.path, "--output-dir", output.path],
                                     environment: environment, timeout: 3)
                let reached = (try? String(contentsOf: marker, encoding: .utf8))
                #expect(result.status != 0, "the fake compiler must prevent every build (case \(index))")
                if index < invalid.count {
                    #expect(reached == nil, "an invalid identity reached compilation or signing (case \(index))")
                    #expect(!FileManager.default.fileExists(atPath: output.path), "an invalid identity created build output (case \(index))")
                    #expect(result.error.contains("docs/development.md"), "invalid identity lacks setup guidance (case \(index))")
                } else {
                    #expect(reached == "compiler", "an exact available identity must reach the compiler, never the signer (case \(index))")
                    let bundles = (try? FileManager.default.contentsOfDirectory(atPath: output.path))?.filter { $0.hasSuffix(".app") } ?? []
                    #expect(bundles.isEmpty, "the fake compiler must not install a bundle (case \(index))")
                }
            }
        }

        @Test func e17MissingConfigurationUsesDefaultsWithoutAnError() throws {
            harness.stopApp()
            try? FileManager.default.removeItem(at: harness.configFile)
            try harness.startApp()
            let config = try harness.status().config
            #expect(config.state == "defaults")
            #expect(config.error == nil)
            #expect(config.effective == Status.Effective(experiments: [:]))
        }

        @Test func e18ValidSaveAndAtomicReplaceReloadWithinOneSecond() throws {
            var before = try harness.status().config.revision
            try writeConfig("# Valid foundation configuration\n[experiments]\n")
            try #require(try eventually(within: 1) { try harness.status().config.state == "loaded" })
            let config = try harness.status().config
            #expect(config.revision > before)
            before = config.revision
            try writeConfig("[experiments] # edited in place\n")
            try #require(try eventually(within: 1) { try harness.status().config.revision > before })
            before = try harness.status().config.revision
            let replacement = harness.configFile.deletingPathExtension().appendingPathExtension("new")
            try Data("['experiments'] # saved atomically\n".utf8).write(to: replacement)
            try #require(rename(replacement.path, harness.configFile.path) == 0)
            try #require(try eventually(within: 1) { try harness.status().config.revision > before })
            before = try harness.status().config.revision
            try writeConfig("[\"\\U00000065xperiments\"]\r\n")
            #expect(try eventually(within: 1) {
                let config = try harness.status().config
                return config.state == "loaded" && config.revision > before
            })
        }

        nonisolated static let malformedConfigurations: [(String, Data, Int)] = [
            ("unclosed table", Data("# bad table\n[experiments\n".utf8), 2),
            ("unknown key", Data("[experiments]\nunknown = true\n".utf8), 2),
            ("unknown table", Data("[unknown]\n".utf8), 1),
            ("unknown key after CRLF", Data("[experiments]\r\nunknown = true\r\n".utf8), 2),
            ("no-break space", Data("\u{a0}[experiments]\n".utf8), 1),
            ("duplicate table", Data("[experiments]\n[experiments]\n".utf8), 2),
            ("NUL in comment", Data("# comment\n# bad\u{0}comment\n".utf8), 2),
            ("DEL in comment", Data("# comment\n# bad\u{7f}comment\n".utf8), 2),
            ("invalid escape", Data("[\"\\qexperiments\"]\n".utf8), 1),
            ("surrogate escape", Data("[\"\\uD800\"]\n".utf8), 1),
            ("escape beyond Unicode", Data("[\"\\U00110000\"]\n".utf8), 1),
            ("text after quoted key", Data("[\"experiments\"\" ]\n".utf8), 1),
            ("array of tables", Data("[[experiments]]\n".utf8), 1),
            ("oversized document", Data(String(repeating: "#", count: 65_537).utf8), 1),
            ("invalid UTF-8", Data([0xff]), 1),
        ]

        @Test(arguments: malformedConfigurations)
        func e19InvalidOrUnknownTOMLKeepsLastValidConfiguration(_ name: String, _ text: Data, _ line: Int) throws {
            let revision = try harness.status().config.revision
            try writeConfig("[experiments] # before malformed input \(revision)\n")
            try #require(try eventually(within: 1) {
                let config = try harness.status().config
                return config.state == "loaded" && config.error == nil && config.revision > revision
            })
            let valid = try harness.status().config
            try text.write(to: harness.configFile)
            let status = try eventualValue(within: 1) { () throws -> Status? in
                let status = try harness.status()
                return status.config.state == "error" && status.config.error?.line == line ? status : nil
            }
            let errored = try #require(status, "\(name) did not report an error on line \(line)")
            #expect(errored.config.effective == valid.effective)
            #expect(errored.config.revision == valid.revision)
            #expect(errored.permission == "granted")
            #expect(harness.appIsRunning)
        }

        @Test func e19UnreadableConfigurationIsAnErrorAndRecovers() throws {
            try writeConfig("[experiments] # repaired\n")
            try #require(try eventually(within: 1) {
                let config = try harness.status().config
                return config.state == "loaded" && config.error == nil
            })
            chmod(harness.configFile.path, 0)
            let unreadable = try eventually(within: 1) { try harness.status().config.state == "error" }
            chmod(harness.configFile.path, 0o600)
            #expect(unreadable)
            #expect(try eventually(within: 1) {
                let config = try harness.status().config
                return config.state == "loaded" && config.error == nil
            })
        }

        @Test func e20DeletingConfigurationReturnsToDefaults() throws {
            try writeConfig("[experiments]\n")
            try #require(try eventually(within: 1) { try harness.status().config.state == "loaded" })
            try FileManager.default.removeItem(at: harness.configFile)
            try #require(try eventually(within: 1) { try harness.status().config.state == "defaults" })
            #expect(try harness.status().config.effective == Status.Effective(experiments: [:]))
        }

        @Test func e21ABlockedAppKeepsLastClassificationWithoutBlockingOtherApps() throws {
            try expectState(try fixture.open(), "tiled")
            for kind in ["noFullscreen", "fixed", "dialog", "panel", "sheet"] {
                try expectState(try fixture.open(kind: kind, key: kind), kind == "noFullscreen" ? "tiled" : "floats")
            }
            try fixture.command("open", ["kind": "tabs", "key": "hungTabs", "count": 3])
            try #require(try converges { $0.contains { $0.tabs == 3 } })
            sleep(seconds: 0.55)
            let expected = Dictionary(try harness.rows().map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            try fixture.command("hang")
            let other = try FixtureSession(directory: harness.directory, number: 2)
            harness.otherFixtures.append(other)
            let outcome = Result { () throws -> Void in
                for index in 0..<3 {
                    let key = "responsive\(index)"
                    let window = try other.open(key: key)
                    try expectState(window, "tiled")
                    let started = monotonicSeconds()
                    let observed = Dictionary(try harness.rows().filter { expected[$0.id] != nil }.map { ($0.id, $0) },
                                              uniquingKeysWith: { $1 })
                    #expect(observed == expected)
                    #expect(monotonicSeconds() - started < 1)
                    try other.command("close", ["key": key])
                    try #require(try eventually { try harness.row(window) == nil })
                }
            }
            // The hung fixture cannot serve later tests; replace it.
            harness.fixture.stop()
            other.stop()
            harness.otherFixtures.removeAll { $0 === other }
            harness.fixture = try FixtureSession(directory: harness.directory, number: 3)
            try outcome.get()
        }
    }
}

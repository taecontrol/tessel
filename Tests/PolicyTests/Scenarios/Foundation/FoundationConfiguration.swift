import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FoundationConfiguration {
    @Test("#1 E17: an absent config starts with every default and no error")
    func missing() {
        requireScenario(Scenario.run("missing configuration at startup") { scenario in
            let tessel = scenario.startTessel()
            scenario.settle()
            let config = tessel.configuration
            scenario.expect("missing config is reported as defaults", config.state == "defaults")
            scenario.expect("missing config has no error", config.error == nil)
            scenario.expect("every effective setting uses its default", config.effective == Configuration())
            scenario.expect("experiments are off", !tessel.status.enabled)
            scenario.expect("startup publishes the same default status", tessel.configurationPublications.last?.status.state == "defaults")
        })
    }

    @Test("#1 E18: save and replacement callbacks publish parsed config before one virtual second", arguments: WriteOrder.allCases)
    func reload(_ writes: WriteOrder) {
        requireScenario(Scenario.run("configuration file event callbacks", writes: writes) { scenario in
            let tessel = scenario.startTessel()
            scenario.settle()
            let saves = [
                ("first save", "# Valid foundation configuration\n[experiments]\n"),
                ("in-place save", "[experiments] # edited in place\n"),
                ("atomic replacement callback", "['experiments'] # saved atomically\n"),
                ("escaped table name and CRLF", "[\"\\U00000065xperiments\"]\r\n"),
            ]
            for (name, text) in saves {
                let revision = tessel.configuration.revision
                let watches = tessel.configurationWatchRequests
                let start = scenario.mac.scheduler.now
                scenario.step(name) { tessel.changeConfig(text) }
                scenario.settle()
                let config = tessel.configuration
                scenario.expect("\(name) loads without error", config.state == "loaded" && config.error == nil)
                scenario.expect("\(name) publishes a newer revision", config.revision > revision)
                scenario.expect("\(name) parses the complete configuration", config.effective == Configuration())
                expectReload(tessel, since: start, after: revision, state: "loaded", scenario: scenario)
                scenario.expect("\(name) requests a watcher refresh", tessel.configurationWatchRequests > watches)
            }
            let revision = tessel.configuration.revision
            let watches = tessel.configurationWatchRequests
            let start = scenario.mac.scheduler.now
            scenario.step("coalesced saves before the reload debounce") {
                tessel.changeConfig("[gaps]\nouter = 15\n")
                tessel.changeConfig("[gaps]\nouter = 24\n")
            }
            scenario.settle()
            scenario.expect("the debounce applies only the newest file contents", tessel.configuration.revision == revision + 1 && tessel.configuration.effective.gaps.outer == 24)
            scenario.expect("coalesced file events request one watcher refresh", tessel.configurationWatchRequests == watches + 1)
            scenario.expect("the config callback applies the new value to policy", tessel.status.gaps.outer == 24)
            expectReload(tessel, since: start, after: revision, state: "loaded", scenario: scenario)
        })
    }

    nonisolated static let malformed: [(String, Data, Int)] = [
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
    private let valid = "[experiments]\nworkspaces = false\n[gaps]\nouter = 24\n"

    @Test("#1 E19: malformed or unknown TOML publishes its line and retains the last valid config", arguments: malformed)
    func invalid(_ name: String, _ data: Data, _ line: Int) {
        requireScenario(Scenario.run("invalid config: \(name)") { scenario in
            let app = scenario.mac.launch(windows: 1)
            let tessel = scenario.startTessel()
            tessel.changeConfig(valid)
            scenario.settle()
            let before = tessel.configuration
            scenario.expect("setup: the valid config differs from defaults", before.state == "loaded" && before.effective.gaps.outer == 24)
            scenario.step("file event supplies \(name)") { tessel.changeConfig(contents: data) }
            scenario.settle()
            let errored = tessel.configuration
            scenario.expect("\(name) reports an error on line \(line)", errored.state == "error" && errored.error?.line == line && errored.error?.message.isEmpty == false)
            scenario.expect("an invalid edit keeps the complete effective config", errored.effective == before.effective && errored.revision == before.revision)
            scenario.expect("the callback driving status and menu receives the error line", tessel.configurationPublications.last?.status.error?.line == line)
            scenario.expect("invalid config preserves the applied policy", tessel.status.gaps.outer == 24)
            let id = app.open(background: true)
            scenario.settle()
            FoundationProof.row(id, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
            let start = scenario.mac.scheduler.now
            scenario.step("correct the file after \(name)") { tessel.changeConfig(valid) }
            scenario.settle()
            scenario.expect("correction clears the error and keeps the valid values", tessel.configuration.error == nil && tessel.configuration.effective == before.effective)
            expectReload(tessel, since: start, after: before.revision, state: "loaded", scenario: scenario)
        })
    }

    @Test("#1 E19: an unreadable file keeps the last config and recovers from identical bytes")
    func unreadable() {
        requireScenario(Scenario.run("read failure followed by permission recovery") { scenario in
            let tessel = scenario.startTessel()
            tessel.changeConfig(valid)
            scenario.settle()
            let before = tessel.configuration
            tessel.changeConfig(valid, unreadable: true)
            scenario.settle()
            scenario.expect("a read failure reports a line-one error", tessel.configuration.state == "error" && tessel.configuration.error?.line == 1)
            scenario.expect("a read failure keeps the last valid config and revision", tessel.configuration.effective == before.effective && tessel.configuration.revision == before.revision)
            scenario.expect("the status/menu callback receives the read failure", tessel.configurationPublications.last?.status.state == "error")
            let start = scenario.mac.scheduler.now
            tessel.changeConfig(valid)
            scenario.settle()
            scenario.expect("readability recovery clears the error without changing the bytes", tessel.configuration.error == nil && tessel.configuration.effective == before.effective)
            expectReload(tessel, since: start, after: before.revision, state: "loaded", scenario: scenario)
        })
    }

    @Test("#1 E20: deleting a loaded config restores defaults and leaves catalog observation running")
    func deleted() {
        requireScenario(Scenario.run("delete configuration callback") { scenario in
            let app = scenario.mac.launch(windows: 1)
            let tessel = scenario.startTessel()
            tessel.changeConfig(valid)
            scenario.settle()
            let revision = tessel.configuration.revision
            scenario.step("file event supplies an absent file") { tessel.changeConfig(nil) }
            scenario.settle()
            let config = tessel.configuration
            scenario.expect("deletion reports defaults without an error", config.state == "defaults" && config.error == nil)
            scenario.expect("deletion restores every effective default", config.effective == Configuration() && config.revision > revision)
            scenario.expect("default policy values reach the callback", tessel.status.gaps == Gaps())
            let id = app.open(background: true)
            scenario.settle()
            FoundationProof.row(id, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
        })
    }

    private func expectReload(_ tessel: Tessel, since start: Int, after revision: UInt64, state: String, scenario: Scenario) {
        let publication = tessel.configurationPublications.first { $0.at >= start && $0.status.revision > revision && $0.status.state == state && $0.status.error == nil }
        scenario.expect("\(state) config published before \(start + 1_000)ms (actual \(publication.map { "\($0.at)ms" } ?? "never"))",
                        publication.map { $0.at - start < 1_000 } == true)
    }
}

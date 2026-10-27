import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct MapConfiguration {
    @Test("#18 E1: absent configuration and an explicit false flag keep all map calls absent")
    func mapIsOptIn() {
        requireCarousel(Scenario.run("map disabled by default and explicitly") { s in
            let f = MapFixture(s, enabled: false)
            for text in [nil, "[experiments]\nmap = false\n"] as [String?] {
                f.tessel.changeConfig(text); s.settle()
                s.expect("absent config and map=false are valid", f.tessel.configuration.error == nil)
                s.expect("map defaults to a 1000 ms hold", f.tessel.configuration.effective.map.duration == 1000)
                s.expect("the experiment is disabled", f.tessel.configuration.effective.experiments["map"] != true)
                for key in ["alt-l", "alt-h", "alt-r", "alt-shift-l", "alt-shift-h", "alt-shift-j", "alt-k", "alt-j", "alt-f", "alt-z", "alt-2", "alt-1"] {
                    f.key(key)
                }
                s.expect("disabled keys never request a map window", f.mac.mapEvents.isEmpty)
                s.expect("the carousel remains enabled", f.tessel.status.enabled && f.tessel.status.layout == "carousel")
            }
        })
    }

    @Test("#18 E2: map duration accepts its integer bounds and rejects invalid edits without replacing valid configuration")
    func durationValidationPreservesLastValidConfiguration() {
        requireCarousel(Scenario.run("map duration parser and reload") { s in
            let f = MapFixture(s, enabled: false)
            for duration in [100, 5000] {
                f.tessel.changeConfig("[map]\nduration = \(duration)\n"); s.settle()
                s.expect("duration \(duration) is accepted", f.tessel.configuration.error == nil && f.tessel.configuration.effective.map.duration == duration)
            }
            let valid = f.tessel.configuration.effective, revision = f.tessel.configuration.revision
            for value in ["99", "5001", "1.5", "\"1000\""] {
                f.tessel.changeConfig("# invalid edit\n[map]\nduration = \(value)\n"); s.settle()
                s.expect("\(value) reports its assignment's line", f.tessel.configuration.error?.line == 3)
                s.expect("\(value) explains the integer bounds", f.tessel.configuration.error?.message == "duration must be a TOML integer from 100 to 5000")
                s.expect("\(value) retains the entire last valid configuration and revision", f.tessel.configuration.effective == valid && f.tessel.configuration.revision == revision)
            }
            f.tessel.changeConfig("[map]\nfade = 1\n"); s.settle()
            s.expect("fade is an unknown key on line two", f.tessel.configuration.error?.line == 2 && f.tessel.configuration.error?.message == "Unknown configuration key")
            s.expect("unknown keys retain the last valid configuration", f.tessel.configuration.effective == valid && f.tessel.configuration.revision == revision)
        })
    }

    @Test("#18 E3: map settings without the flag appear in effective status without showing a map")
    func settingsDoNotEnableTheExperiment() {
        requireCarousel(Scenario.run("map settings without experiment") { s in
            let f = MapFixture(s, enabled: false)
            f.tessel.changeConfig("[map]\nduration = 2500\n"); s.settle()
            let status = AppStatus(permission: "granted", config: f.tessel.configuration, version: "fixture", pid: 100)
            let json = encodedObject(status)
            let config = json["config"] as? [String: Any]
            let effective = config?["effective"] as? [String: Any]
            s.expect("settings load successfully", f.tessel.configuration.error == nil)
            s.expect("effective JSON reports map.duration", (effective?["map"] as? [String: Any])?["duration"] as? Int == 2500)
            s.expect("effective JSON does not enable the flag", (effective?["experiments"] as? [String: Bool])?["map"] != true)
            s.expect("public status has no testMap field", json["testMap"] == nil)
            f.key("alt-l")
            s.expect("settings alone never show a map", f.mac.mapEvents.isEmpty)
        })
    }
}

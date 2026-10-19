import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselConfiguration {
    @Test("#26 E22: carousel replaces rails, duration is bounded, and cycle width defaults can be overridden")
    func configurationValidationPreservesLastValidValue() {
        requireCarousel(Scenario.run("carousel configuration contract") { s in
            let app = s.mac.launch(windows: 1), t = s.startTessel(); s.settle()
            @MainActor func load(_ text: String) { t.changeConfig(text); s.settle() }
            let base = CarouselFixture.config
            load(base)
            s.expect("carousel activates independently of workspaces", t.status.enabled && t.status.layout == "carousel")
            s.expect("default alt-r cycles width", t.status.keys["alt-r"] == "cycle width")
            s.expect("omitted animation defaults to eighty milliseconds", encodedDuration(t.configuration.effective) == 80)
            for value in [0,1,80,400,1000] {
                load(base + "[animation]\nduration = \(value)\n")
                s.expect("duration \(value) is accepted", t.configuration.error == nil && encodedDuration(t.configuration.effective) == value)
            }
            for value in ["+80", "0x50", "0o120", "0b1010000", "8_0"] {
                load(base + "[animation]\nduration = \(value)\n")
                s.expect("integer TOML spelling \(value) is accepted", t.configuration.error == nil && encodedDuration(t.configuration.effective) == 80)
            }
            // Every invalid edit must preserve the *entire* last valid config,
            // registrations and revision, not merely report an error.
            let valid = t.configuration.effective, revision = t.configuration.revision, keys = t.status.keys
            for value in ["-1", "1001", "1.5", "80.0", "true", "\"80\"", "[]", "nan", "1e2", "1_001", "9223372036854775808"] {
                load(base + "[animation]\nduration = \(value)\n")
                s.expect("invalid duration \(value) reports line four", t.configuration.error?.line == 4)
                s.expect("invalid duration retains last config and keys", t.configuration.effective == valid && t.configuration.revision == revision && t.status.keys == keys)
            }
            load("[experiments]\nrails = true\n")
            s.expect("removed rails key reports unknown key on line two", t.configuration.error?.line == 2 && t.configuration.error?.message.lowercased().contains("unknown") == true)
            s.expect("removed rails key preserves last valid config", t.configuration.effective == valid)
            load(base + "[keys]\nalt-r = ''\nalt-a = 'cycle width'\n")
            s.expect("cycle can be disabled and rebound", t.configuration.error == nil && t.status.keys["alt-r"] == "" && t.status.keys["alt-a"] == "cycle width")
            s.expect("fixture survives config validation", t.windows.first?.id == app.windows.first)
        })
    }

    @Test("#26 E23: JSON status reports carousel, effective duration and current rail counts")
    func statusEncodesEffectiveAnimationDuration() {
        requireCarousel(Scenario.run("carousel JSON status") { s in
            let f = CarouselFixture(s)
            @MainActor func check(_ duration: Int, rail: Int, count: Int) {
                let json = encodedObject(f.tessel.status)
                s.expect("JSON layout is carousel", json["layout"] as? String == "carousel")
                s.expect("JSON effective animation duration is \(duration)", json["animationDuration"] as? Int == duration)
                s.expect("JSON current rail and count are present", json["rail"] as? Int == rail && json["railCount"] as? Int == count)
            }
            check(80, rail: 1, count: 1)
            f.select(f.ids[2]); f.press("alt-shift-j"); check(80, rail: 2, count: 2)
            f.mac.setReduceMotion(true); s.settle(); check(0, rail: 2, count: 2)
            f.mac.setReduceMotion(false); s.settle(); f.configure(duration: 400); s.settle(); check(400, rail: 2, count: 2)
        })
    }
}

func encodedObject(_ value: some Encodable) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return result
}
func encodedDuration(_ value: Configuration) -> Int? { (encodedObject(value)["animation"] as? [String: Any])?["duration"] as? Int }

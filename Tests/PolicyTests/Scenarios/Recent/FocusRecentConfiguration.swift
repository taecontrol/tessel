import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FocusRecentConfiguration {
    @Test("#57 E14: with the map experiment, focus recent shows the map only when the selection changes", arguments: [true, false])
    func map(changes: Bool) {
        requireCarousel(Scenario.run("recent map, changes=\(changes)") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 0), a = f.ids[0], b = f.ids[1]
            f.tessel.changeConfig(CarouselFixture.config + "map = true\n[animation]\nduration = 0\n"); s.settle()
            s.expect("the map experiment loads", f.tessel.configuration.error == nil)
            f.focus(a)
            if changes { f.press("focus right"); f.focus(b) }
            f.mac.clearMapHistory()
            Recent.press(f)
            let shows = f.mac.mapEvents.filter { if case .show = $0.kind { true } else { false } }
            if changes {
                f.focus(a)
                s.expect("the map shows once for the new selection, got \(f.mac.mapEvents)", shows.count == 1)
            } else {
                f.focus(a)
                s.expect("no map without a selection change, got \(f.mac.mapEvents)", f.mac.mapEvents.isEmpty)
            }
        })
    }

    @Test("#57 E16: alt-tab focuses recent by default and can be disabled, rebound or rejected")
    func bindings() {
        requireCarousel(Scenario.run("recent bindings") { s in
            let f = CarouselFixture(s, presets: [0.3, 0.3], duration: 0), a = f.ids[0], b = f.ids[1]
            let base = CarouselFixture.config + "[animation]\nduration = 0\n"
            f.focus(a)
            f.press("focus right"); f.focus(b)
            s.expect("alt-tab is bound by default", f.tessel.status.keys["alt-tab"] == "focus recent")
            s.step("alt-tab") { f.tessel.pressKey("alt-tab") }
            s.settle(); f.focus(a)

            f.tessel.changeConfig(base + "[keys]\nalt-tab = \"\"\nctrl-tab = \"focus recent\"\n"); s.settle()
            s.expect("the override loads (\(f.tessel.configuration.error?.message ?? "no error"))", f.tessel.configuration.error == nil)
            s.expect("an empty alt-tab disables the default", (f.tessel.status.keys["alt-tab"] ?? "") == "")
            s.step("disabled alt-tab") { f.tessel.pressKey("alt-tab") }
            s.settle(); f.focus(a)
            s.step("ctrl-tab") { f.tessel.pressKey("ctrl-tab") }
            s.settle(); f.focus(b)

            for (text, needle) in [("[keys]\nalt-space = \"focus recent\"\n", "tab"),
                                   ("[keys]\nalt-tab = \"focus last\"\n", "focus recent")] {
                let revision = f.tessel.configuration.revision
                s.step("reject \(needle)") { f.tessel.changeConfig(base + text) }
                s.settle()
                let error = f.tessel.configuration.error
                s.expect("the error names \(needle) at line 6, got \(String(describing: error))",
                         error?.line == 6 && error?.message.contains(needle) == true)
                s.expect("the last valid configuration stays", f.tessel.configuration.revision == revision
                         && f.tessel.status.keys["ctrl-tab"] == "focus recent")
                s.step("ctrl-tab after the rejected edit") { f.tessel.pressKey("ctrl-tab") }
                s.settle(); f.focus(a)
                s.step("ctrl-tab back") { f.tessel.pressKey("ctrl-tab") }
                s.settle(); f.focus(b)
            }
        })
    }

    @Test("#57 E16: tab is a key, focus recent is a command, and alt-tab is a default binding")
    func parser() throws {
        let chord = try #require(KeyChord("alt-tab"))
        #expect(chord.code == 48 && chord.name == "alt-tab" && chord.modifiers == ["alt"])
        #expect(KeyChord("shift-ctrl-tab")?.name == "shift-ctrl-tab")
        #expect(WorkspaceCommand("focus recent") != nil)
        #expect(WorkspaceCommand("focus  recent") == nil && WorkspaceCommand("recent") == nil)
        #expect(KeyChord.defaults["alt-tab"] == "focus recent")
        let defaults = try ConfigParser.parse(Data())
        #expect(defaults.keys["alt-tab"] == "focus recent")
        let rebound = try ConfigParser.parse(Data("[keys]\nalt-tab = \"\"\nctrl-tab = \"focus recent\"\n".utf8))
        #expect(rebound.keys["alt-tab"] == "" && rebound.keys["ctrl-tab"] == "focus recent")
        do {
            _ = try ConfigParser.parse(Data("[keys]\nalt-space = \"focus recent\"\n".utf8))
            Issue.record("an invalid key must be rejected")
        } catch let error as ConfigError {
            #expect(error.line == 2 && error.message.contains("tab"))
        }
        do {
            _ = try ConfigParser.parse(Data("[keys]\nalt-tab = \"focus last\"\n".utf8))
            Issue.record("an unknown command must be rejected")
        } catch let error as ConfigError {
            #expect(error.line == 2 && error.message.contains("focus recent"))
        }
    }
}

import Testing
@testable import Policy

@Suite @MainActor struct WorkspaceConfiguration {
    @Test("#2 E33: gaps obey TOML number grammar even with the experiment off")
    func numberGrammar() {
        requireScenario(Scenario.run("gap grammar with experiment off") { scenario in
            let tessel = scenario.startTessel()
            scenario.settle()
            for (literal, expected) in [("0x14", 20.0), ("0o24", 20.0), ("0b10100", 20.0), ("1_0.5", 10.5), ("+2e1", 20.0)] {
                let revision = tessel.configuration.revision
                scenario.step("load outer = \(literal)") { tessel.changeConfig("[gaps]\nouter = \(literal)\n") }
                scenario.settle()
                scenario.expect("\(literal) parses as \(expected)", tessel.status.gaps.outer == expected && tessel.configuration.revision > revision)
                scenario.expect("parsing does not enable the experiment", !tessel.status.enabled)
            }
            for literal in [".1", "1.", "01", "1__0", "inf", "nan", "9223372036854775808"] {
                tessel.changeConfig("[gaps]\nouter = 20 # before \(literal)\n")
                scenario.settle()
                let revision = tessel.configuration.revision
                scenario.step("reject outer = \(literal)") { tessel.changeConfig("[gaps]\nouter = \(literal)\n") }
                scenario.settle()
                scenario.expect("\(literal) reports line 2", tessel.configuration.error?.line == 2)
                scenario.expect("invalid number retains the accepted configuration", tessel.configuration.revision == revision && tessel.status.gaps.outer == 20 && !tessel.status.enabled)
            }
        })
    }

    @Test("#2 E33: invalid configuration reports its line and preserves effective bindings", arguments: [false, true])
    func invalidConfiguration(enabled: Bool) {
        let invalid = [
            ("[keys]\nalt-1 = \"workspace 2\"\nalt-1 = \"workspace 3\"\n", 5),
            ("[keys]\nalt-1 = \"unknown\"\n", 4),
            ("[keys]\nalt-1 = \"workspace 11\"\n", 4),
            ("[keys]\ninvalid-1 = \"workspace 1\"\n", 4),
            ("[gaps]\nouter = -1\n", 4),
            ("[keys]\nalt-shift-1 = \"send 2\"\nshift-alt-1 = \"send 3\"\n", 5)
        ]
        requireScenario(Scenario.run("invalid configuration, enabled=\(enabled)") { scenario in
            let tessel: Tessel
            if enabled { tessel = WorkspaceScenarios.split(scenario).1 }
            else { tessel = scenario.startTessel(); scenario.settle() }
            let prefix = "[experiments]\nworkspaces = \(enabled)\n"
            for (text, line) in invalid {
                tessel.changeConfig(prefix + "[keys]\nalt-1 = \"workspace 2\"\n")
                scenario.settle()
                let revision = tessel.configuration.revision
                scenario.step("reject invalid config at line \(line)") { tessel.changeConfig(prefix + text) }
                scenario.settle()
                scenario.expect("the invalid edit reports its exact line", tessel.configuration.error?.line == line)
                scenario.expect("the revision does not change", tessel.configuration.revision == revision)
                scenario.expect("the effective override survives", tessel.status.keys["alt-1"] == "workspace 2")
                if enabled {
                    tessel.pressKey("alt-1")
                    scenario.settle()
                    WorkspaceScenarios.shown(scenario, 2)
                } else { scenario.expect("the experiment stays disabled", !tessel.status.enabled) }
            }
        })
    }
}

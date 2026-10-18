import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FoundationClassification {
    @Test("#1 E1; #1 E2: a standard resizable window tiles without any fullscreen control")
    func standardWithoutFullscreenControl() {
        requireScenario(Scenario.run("standard window with no fullscreen button") { scenario in
            let app = scenario.mac.launch()
            let tessel = scenario.startTessel()
            scenario.settle()
            // WindowSpec's ordinary chrome has no controls, including no fullscreen button.
            let id = app.open()
            scenario.settle()
            FoundationProof.row(id, in: tessel, state: .tiled, reason: "standard window", scenario: scenario)
            scenario.expect("only the standard window is published", tessel.windows.map(\.id) == [id])
        })
    }

    @Test("#1 E3: a standard nonresizable window floats with the fixed-size reason")
    func fixedSize() {
        requireScenario(Scenario.run("fixed-size standard window") { scenario in
            let app = scenario.mac.launch()
            let tessel = scenario.startTessel()
            scenario.settle()
            let id = app.open(WindowSpec(resizable: false))
            scenario.settle()
            FoundationProof.row(id, in: tessel, state: .floats, reason: "fixed size", scenario: scenario)
        })
    }

    enum FloatingKind: String, CaseIterable { case dialog, panel, sheet }

    @Test("#1 E4: dialogs, floating panels and attached sheets float with their subroles", arguments: FloatingKind.allCases)
    func floatingSubrole(_ kind: FloatingKind) {
        requireScenario(Scenario.run("\(kind.rawValue) subrole") { scenario in
            let app = scenario.mac.launch()
            let tessel = scenario.startTessel()
            scenario.settle()
            let parent = kind == .sheet ? app.open() : nil
            let subrole = kind == .panel ? "AXFloatingWindow" : "AXDialog"
            let id = app.open(WindowSpec(subrole: subrole, parent: parent))
            scenario.settle()
            FoundationProof.row(id, in: tessel, state: .floats, reason: subrole, scenario: scenario)
            scenario.expect("each root and sheet is published exactly once", tessel.windows.map(\.id) == [parent, id].compactMap { $0 }.sorted())
            if let parent { FoundationProof.row(parent, in: tessel, state: .tiled, reason: "standard window", scenario: scenario) }
        })
    }

    @Test("#1 E6: minimized and hidden states take precedence and restore every classification", arguments: WriteOrder.allCases)
    func minimizedAndHidden(_ writes: WriteOrder) {
        requireScenario(Scenario.run("minimize, restore, hide and unhide", writes: writes) { scenario in
            let app = scenario.mac.launch()
            let tessel = scenario.startTessel()
            scenario.settle()
            let cases: [(WindowSpec, WindowState, String)] = [
                (WindowSpec(), .tiled, "standard window"),
                (WindowSpec(resizable: false), .floats, "fixed size"),
                (WindowSpec(subrole: "AXDialog"), .floats, "AXDialog"),
                (WindowSpec(subrole: "AXFloatingWindow"), .floats, "AXFloatingWindow"),
            ]
            var expected: [(UInt32, WindowState, String)] = []
            for (spec, state, reason) in cases {
                let id = app.open(spec)
                expected.append((id, state, reason))
                scenario.settle()
                FoundationProof.row(id, in: tessel, state: state, reason: reason, scenario: scenario)
                scenario.step("minimize window \(id)") { app.minimize(id) }
                scenario.settle()
                FoundationProof.row(id, in: tessel, state: .minimized, reason: "minimized", scenario: scenario)
                scenario.step("restore window \(id)") { app.restore(id) }
                scenario.settle()
                FoundationProof.row(id, in: tessel, state: state, reason: reason, scenario: scenario)
            }
            scenario.step("hide app while AXWindows omits its roots") { app.hide(omitWindows: true) }
            scenario.settle()
            scenario.expect("hide retains all windows", tessel.windows.count == expected.count)
            for (id, _, _) in expected { FoundationProof.row(id, in: tessel, state: .hidden, reason: "application hidden", scenario: scenario) }
            scenario.step("unhide app") { app.unhide() }
            scenario.settle()
            for (id, state, reason) in expected { FoundationProof.row(id, in: tessel, state: state, reason: reason, scenario: scenario) }
            let fixed = expected.first { $0.2 == "fixed size" }!.0
            app.minimize(fixed)
            scenario.settle()
            app.hide()
            scenario.settle()
            for (id, _, _) in expected {
                FoundationProof.row(id, in: tessel, state: id == fixed ? .minimized : .hidden,
                                    reason: id == fixed ? "minimized" : "application hidden", scenario: scenario)
            }
            app.unhide()
            app.restore(fixed)
            scenario.settle()
            for (id, state, reason) in expected { FoundationProof.row(id, in: tessel, state: state, reason: reason, scenario: scenario) }
        })
    }
}

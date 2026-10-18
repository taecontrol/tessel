import Testing
@testable import Check

@Suite struct CheckTests {
    @Test("E12: simulator changes require a changed contract or a non-empty evidence line")
    func simulatorEvidence() {
        let bodies = ["", "Simulator-evidence:", "Simulator-evidence: \t\r\n", "Notes\nSimulator-evidence: signed contract passed\n"]
        for simulator in [false, true] {
            for contract in [false, true] {
                for (index, body) in bodies.enumerated() {
                    let paths = (simulator ? ["Tests/Simulator/Desktop.swift"] : ["Sources/Policy/Rails.swift"])
                        + (contract ? ["Tests/Acceptance/ContractsGeometry.swift"] : [])
                    let expected: SimulatorEvidence = !simulator ? .unchanged : contract ? .contractChanged : index == 3 ? .bodyEvidence : .missing
                    #expect(SimulatorEvidence(paths: paths, body: body) == expected)
                }
            }
        }
        for body in ["prefix Simulator-evidence: proof", " Simulator-evidence: proof", "Simulator-evidence-extra: proof"] {
            #expect(SimulatorEvidence(paths: ["Tests/Simulator/New.swift"], body: body) == .missing)
        }
        #expect(SimulatorEvidence(paths: ["Tests/Simulator/New.swift", "Tests/Acceptance/Contracts/Nested.swift"], body: "") == .missing)
    }

    @Test("E2: a replay needs a successful result and exactly one matching trace digest")
    func replayResults() throws {
        let digest = String(repeating: "a", count: 64), changed = String(repeating: "b", count: 64)
        let output = "Tests passed\ntrace digest: \(digest)\n"
        #expect(try CheckDecisions.digest(status: 0, output: output, expected: digest) == digest)
        #expect(throws: CheckFailure.self) { try CheckDecisions.digest(status: 1, output: output) }
        #expect(throws: CheckFailure.self) { try CheckDecisions.digest(status: 0, output: output, expected: changed) }
        for invalid in ["", "trace digest: short", output + output, "prefix trace digest: \(digest)"] {
            #expect(throws: CheckFailure.self) { try CheckDecisions.digest(status: 0, output: invalid) }
        }
    }

    @Test("E1: compilation and discovery both expose an accidental Acceptance target")
    func layers() {
        for output in ["[3/9] Compiling Acceptance Harness.swift", "[4/9] Emitting module Acceptance",
                       "Wrapping AST for Acceptance for debugging", "[175 / 181] Acceptance", "Acceptance.Acceptance.Journeys/enable()",
                       "/copy/.build/arm64-apple-macosx/debug/Acceptance.build/Harness.swift.o"] {
            #expect(!CheckDecisions.acceptanceLeaks(in: output).isEmpty)
        }
        #expect(CheckDecisions.acceptanceLeaks(in: "[3/9] Compiling PolicyTests AcceptanceWaits.swift\nPolicyTests.Integrity/check()").isEmpty)
    }

    @Test("E3/E10/E13: mutants must fail at their intended boundary")
    func mutantResults() {
        let failed = "✘ Test run with 24 tests in 10 suites failed after 2.000 seconds with 2 issues."
        #expect(MutantKind.knownBug.killed(status: 1, output: failed))
        #expect(!MutantKind.knownBug.killed(status: 0, output: failed))
        #expect(!MutantKind.knownBug.killed(status: 1, output: "error: build failed"))
        #expect(MutantKind.simulatorImport.killed(status: 1, output: "module 'Policy' doesn't allow importation from module 'Simulator'"))
        #expect(MutantKind.simulatorImport.killed(status: 1, output: "ForbiddenPolicyImport.swift:1:8 unable to resolve module dependency: 'Policy'"))
        #expect(!MutantKind.simulatorImport.killed(status: 1, output: failed))
        #expect(MutantKind.policyClock.killed(status: 1, output: "ForbiddenClock.swift:2: wall clock\n" + failed))
        #expect(!MutantKind.policyClock.killed(status: 1, output: failed))
        #expect(!MutantKind.policyClock.killed(status: 1, output: "ForbiddenClock.swift:2: wall clock"))
    }

    @Test("commands reject missing or unsafe run counts")
    func arguments() throws {
        #expect(try CheckCommand(["determinism", "--runs", "5"]) == .determinism(5))
        #expect(try CheckCommand(["simulator-evidence", "--base", "origin/main", "--body-file", "body"]) == .simulatorEvidence(base: "origin/main", bodyFile: "body"))
        for invalid in [[], ["mutants", "extra"], ["determinism", "--runs", "0"], ["determinism", "--runs", "-1"],
                        ["determinism", "--runs", "many"], ["simulator-evidence", "--base", "main"]] {
            #expect(throws: CheckFailure.self) { try CheckCommand(invalid) }
        }
    }
}

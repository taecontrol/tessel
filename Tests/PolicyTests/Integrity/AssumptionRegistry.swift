import Foundation
import Assumptions
import Testing

struct AssumptionRegistry {
    struct Findings {
        let missingBehaviors: [String]
        let missingContracts: [String]
        let unknown: [String]
    }
    static func ids(in source: String, call: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: "\\b" + call + #"\s*\(\s*\.([A-Za-z_][A-Za-z_0-9]*)\s*\)"#)
        let code = PolicyPurity.codeOnly(source)
        let text = code as NSString
        return Set(expression.matches(in: code, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) })
    }
    static func check(declared: Set<String>, behaviors: Set<String>, contracts: Set<String>) -> Findings {
        Findings(missingBehaviors: declared.subtracting(behaviors).sorted(), missingContracts: declared.subtracting(contracts).sorted(),
                 unknown: behaviors.union(contracts).subtracting(declared).sorted())
    }
}

@Suite struct AssumptionIntegrity {
    @Test("E11: registry diagnoses missing and extra IDs")
    func checkerNegativeControls() {
        let findings = AssumptionRegistry.check(declared: ["kept", "missing"], behaviors: ["kept", "missing"], contracts: ["kept", "extra"])
        #expect(findings.missingContracts == ["missing"])
        #expect(findings.unknown == ["extra"])
        let missing = AssumptionRegistry.check(declared: ["unused"], behaviors: [], contracts: ["unused"])
        #expect(missing.missingBehaviors == ["unused"])
        #expect(AssumptionRegistry.ids(in: "assume(.axReadDelivery)\ncontract(.axReadDelivery)", call: "assume") == ["axReadDelivery"])
        for call in ["assume", "contract"] {
            for source in ["// \(call)(.axReadDelivery)", "/* \(call)(.axReadDelivery) */",
                           "let text = \"\(call)(.axReadDelivery)\"", "let raw = #\"\(call)(.axReadDelivery)\"#"] {
                #expect(AssumptionRegistry.ids(in: source, call: call).isEmpty, "Non-code registered an assumption: \(source)")
            }
            #expect(AssumptionRegistry.ids(in: "// \(call)(.removed)\n\(call)(.axReadDelivery)", call: call) == ["axReadDelivery"])
        }
    }

    @Test("E11: every simulator assumption has exactly its registered contract ID")
    func registry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func sources(_ directory: String, matching: (String) -> Bool) throws -> String {
            let base = root.appending(path: directory)
            return try FileManager.default.subpathsOfDirectory(atPath: base.path).filter(matching).sorted()
                .map { try String(contentsOf: base.appending(path: $0), encoding: .utf8) }.joined(separator: "\n")
        }
        // Contracts declare IDs as contract(.caseName), including in @Test
        // traits. No example IDs belong to the macOS contract layer.
        let simulator = try sources("Tests/Simulator", matching: { $0.hasSuffix(".swift") })
        let contracts = try sources("Tests/Acceptance", matching: { $0.hasPrefix("Contracts") && $0.hasSuffix(".swift") })
        let declared = Set(Assumption.allCases.map { String(describing: $0) })
        let findings = AssumptionRegistry.check(declared: declared, behaviors: AssumptionRegistry.ids(in: simulator, call: "assume"),
                                              contracts: AssumptionRegistry.ids(in: contracts, call: "contract"))
        #expect(findings.unknown.isEmpty, "Unknown assumption IDs: \(findings.unknown)")
        #expect(findings.missingBehaviors.isEmpty, "Assumptions without behavior: \(findings.missingBehaviors)")
        #expect(findings.missingContracts.isEmpty, "Assumptions without contracts: \(findings.missingContracts)")
        #expect(Set(Assumption.allCases.map(\.rawValue)).count == Assumption.allCases.count)
        #expect(Assumption.allCases.allSatisfy { !$0.statement.isEmpty })
    }
}

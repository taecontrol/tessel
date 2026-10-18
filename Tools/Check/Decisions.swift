import Foundation

enum SimulatorEvidence: Equatable {
    case unchanged, contractChanged, bodyEvidence, missing

    init(paths: [String], body: String) {
        if !paths.contains(where: { $0.hasPrefix("Tests/Simulator/") }) { self = .unchanged }
        else if paths.contains(where: {
            $0.hasPrefix("Tests/Acceptance/Contracts") && $0.hasSuffix(".swift")
                && !$0.dropFirst("Tests/Acceptance/".count).contains("/")
        }) { self = .contractChanged }
        else if body.components(separatedBy: .newlines).contains(where: {
            $0.hasPrefix("Simulator-evidence:") && !$0.dropFirst("Simulator-evidence:".count).trimmingCharacters(in: .whitespaces).isEmpty
        }) { self = .bodyEvidence }
        else { self = .missing }
    }

    var explanation: String {
        switch self {
        case .unchanged: "simulator-evidence: no simulator change"
        case .contractChanged: "simulator-evidence: simulator and contract changed"
        case .bodyEvidence: "simulator-evidence: PR body records Simulator-evidence"
        case .missing: "simulator-evidence: Tests/Simulator changed without a Contracts*.swift change or a non-empty Simulator-evidence: line"
        }
    }
}

enum CheckDecisions {
    static func digest(status: Int32, output: String, expected: String? = nil) throws -> String {
        guard status == 0 else { throw CheckFailure("swift test failed (exit \(status))") }
        let lines = output.components(separatedBy: .newlines).filter { $0.hasPrefix("trace digest:") }
        guard lines.count == 1, lines[0].range(of: #"^trace digest: [0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw CheckFailure("expected exactly one trace digest: line with a SHA-256 digest")
        }
        let digest = String(lines[0].dropFirst("trace digest: ".count))
        if let expected, digest != expected { throw CheckFailure("trace digest changed: expected \(expected), got \(digest)") }
        return digest
    }

    static func acceptanceLeaks(in output: String) -> [String] {
        output.components(separatedBy: .newlines).filter {
            $0.range(of: #"\b(?:Compiling|Emitting module|Wrapping AST for)\s+Acceptance\b|^\[[^\]\n]+\]\s+Acceptance(?:\s|$)|^Acceptance[./]|/Acceptance\.build/"#,
                     options: .regularExpression) != nil
        }
    }
}

enum MutantKind {
    case knownBug, simulatorImport, policyClock

    init(path: String) throws {
        if path == "guards/simulator-import-policy.patch" { self = .simulatorImport }
        else if path == "guards/policy-wall-clock.patch" { self = .policyClock }
        else if !path.hasPrefix("guards/") { self = .knownBug }
        else { throw CheckFailure("unknown guard mutant \(path)") }
    }

    func killed(status: Int32, output: String) -> Bool {
        guard status != 0 else { return false }
        let testsFailed = output.range(of: #"Test run with \d+ tests?[^\n]* failed after "#, options: .regularExpression) != nil
        switch self {
        case .knownBug: return testsFailed
        case .simulatorImport:
            return output.contains("module 'Policy' doesn't allow importation from module 'Simulator'")
                || output.contains("no such module 'Policy'")
                || output.contains("ForbiddenPolicyImport.swift:1:8 unable to resolve module dependency: 'Policy'")
        case .policyClock: return testsFailed && output.contains("ForbiddenClock.swift:2: wall clock")
        }
    }
}

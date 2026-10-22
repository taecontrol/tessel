import Foundation

/// Evidence belongs to one exact source revision. It is only printed by verify
/// after all four real-system suites have succeeded on a clean checkout.
struct VerificationEvidence {
    static let suites: Set<String> = ["contracts", "journeys", "latency", "resources"]
    static let prefixes = ["Sources/", "Tests/Acceptance/", "Tests/Fixture/", "Tools/Build/", "scripts/"]

    static func required(paths: [String]) -> Bool {
        paths.contains { path in prefixes.contains { path.hasPrefix($0) } }
    }

    static func block(head: String) -> String {
        "```tessel-verification\nhead: \(head)\nsuites: contracts journeys latency resources\n```"
    }

    static func accepts(body: String, head: String) -> Bool {
        guard head.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else { return false }
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for index in lines.indices where lines[index] == "```tessel-verification" {
            guard index + 3 < lines.count, lines[index + 1] == "head: " + head,
                  lines[index + 2].hasPrefix("suites: "), lines[index + 3] == "```" else { continue }
            let names = lines[index + 2].dropFirst("suites: ".count).split(separator: " ").map(String.init)
            if names.count == suites.count && Set(names) == suites { return true }
        }
        return false
    }
}

import Foundation
import Testing
@testable import Check

@Suite struct DeliveryChecks {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("#33 E4: retired configuration modes have no production code, scenario or journey")
    func retiredModesAreRemoved() throws {
        for directory in ["Sources", "Tests/PolicyTests/Scenarios", "Tests/Acceptance"] {
            let files = try FileManager.default.subpathsOfDirectory(atPath: root.appending(path: directory).path).filter { $0.hasSuffix(".swift") }
            for file in files {
                let source = try String(contentsOf: root.appending(path: directory + "/" + file), encoding: .utf8)
                for spelling in [".configure(.off)", ".configure(.stack)", "layout = \"stack\"", "disable(reason: \"experiment off\")"] {
                    #expect(!source.contains(spelling), "retired mode in \(directory)/\(file): \(spelling)")
                }
            }
        }
    }

    @Test("#33 E21; #33 E24: CI keeps policy, evidence and permissions without judging product time")
    func ciRunsOnlyTheAcceptedGates() throws {
        let workflows = root.appending(path: ".github/workflows")
        let files = try FileManager.default.contentsOfDirectory(atPath: workflows.path).filter { $0.hasSuffix(".yml") }
        let sources = try files.map { try String(contentsOf: workflows.appending(path: $0), encoding: .utf8) }
        for source in sources {
            #expect(!source.contains("workflow_dispatch:") && !source.contains("schedule:"))
            for line in source.components(separatedBy: .newlines).filter({ $0.contains("timeout-minutes:") }) {
                let value = Int(line.components(separatedBy: ":").last!.trimmingCharacters(in: .whitespaces)) ?? 100
                #expect(value < 10)
            }
            for suite in ["--contracts", "--journeys", "--latency", "--resources", "200 second"] { #expect(!source.contains(suite)) }
        }
        let all = sources.joined(separator: "\n")
        for command in ["swift test", "tessel-check layers", "determinism --runs 3", "signingAndPermission", "--permission"] { #expect(all.contains(command)) }
        #expect(all.contains("name: Permissions"))
        let budget = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Tests/Acceptance/resource-budget.json"))) as! [String: Any]
        #expect(budget["interruptWakeups"] as? Int == 11 && budget["cpuNanoseconds"] as? Int == 100_000_000 && budget["footprintBytes"] as? Int == 30_000_000)
        let latency = try String(contentsOf: root.appending(path: "Tests/Acceptance/Latency.swift"), encoding: .utf8)
        #expect(latency.contains("200"))
    }

    @Test("#33 E22: real changes require the full evidence block for exactly this head")
    func exactHeadEvidence() throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        let head = try repo.commit(path: "Sources/App/Generic.swift", content: "// changed\n")
        for body in ["", "Verification-evidence: \(head)", repo.block(head: String(repeating: "a", count: 40)),
                     repo.block(head: head).replacingOccurrences(of: "resources", with: "other")] {
            #expect(try repo.check(["verification-evidence", "--base", repo.base, "--head", head, "--body-file", repo.body(body)]).status != 0)
        }
        #expect(try repo.check(["verification-evidence", "--base", repo.base, "--head", head, "--body-file", repo.body(repo.block(head: head))]).status == 0)
        let docs = try RepositoryFixture(); defer { docs.remove() }
        let docHead = try docs.commit(path: "docs/guide.md", content: "A guide\n")
        #expect(try docs.check(["verification-evidence", "--base", docs.base, "--head", docHead, "--body-file", docs.body("")]).status == 0)
    }

    @Test("#33 E23: a clean verified head produces evidence, a dirty or changed head cannot")
    func onlyCleanVerifiedHeadsProduceEvidence() throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        let command = ["print-verification-evidence", "--verified-head", repo.base]
        let clean = try repo.check(command)
        #expect(clean.status == 0 && clean.output.contains(repo.block(head: repo.base)))
        try Data("untracked\n".utf8).write(to: repo.directory.appending(path: "dirty"))
        let dirty = try repo.check(command)
        #expect(dirty.status != 0 && !dirty.output.contains("```tessel-verification"))
        _ = try repo.git(["add", "."]); _ = try repo.git(["commit", "-qm", "New head"])
        #expect(try repo.check(command).status != 0)
        let script = try String(contentsOf: root.appending(path: "scripts/verify"), encoding: .utf8)
        #expect(script.contains("print-verification-evidence") && !script.contains("exec swift test"))
    }
}

private struct RepositoryFixture {
    let directory: URL
    let base: String
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "tessel-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try Self.run(["/usr/bin/git", "init", "-q"], at: directory)
        _ = try Self.run(["/usr/bin/git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "Base"], at: directory)
        base = try Self.run(["/usr/bin/git", "rev-parse", "HEAD"], at: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func block(head: String) -> String { "```tessel-verification\nhead: \(head)\nsuites: contracts journeys latency resources\n```" }
    func body(_ text: String) throws -> String {
        let file = directory.appending(path: ".git/pr-body")
        try Data(text.utf8).write(to: file); return file.path
    }
    func commit(path: String, content: String) throws -> String {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
        _ = try git(["add", path]); _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Change"])
        return try git(["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func git(_ arguments: [String]) throws -> (status: Int32, output: String) { try Self.run(["/usr/bin/git"] + arguments, at: directory) }
    func check(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let binary = root.appending(path: ".build/" + configuration + "/tessel-check").path
        return try Self.run([binary] + arguments, at: directory)
    }
    static func run(_ command: [String], at directory: URL) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0]); process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = directory; process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

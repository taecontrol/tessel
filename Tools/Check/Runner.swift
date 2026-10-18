import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    let seconds: Double
}

func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
}

struct CheckRunner {
    let root: URL

    func run(_ command: CheckCommand) throws {
        switch command {
        case .layers:
            // Listing cannot enter Acceptance's suite scopes if the gate breaks.
            let result = try execute(["swift", "test", "list"])
            print(String(format: "layers total time: %.3f s", result.seconds))
            guard result.status == 0 else { throw CheckFailure("swift test list failed\n" + tail(result.output)) }
            let leaks = CheckDecisions.acceptanceLeaks(in: result.output)
            guard leaks.isEmpty else { throw CheckFailure("Acceptance was compiled or listed:\n" + leaks.joined(separator: "\n")) }
            print("layers: bare swift test lists only deterministic tests")
        case .determinism(let count):
            var digest: String?
            for index in 1...count {
                let result = try execute(["swift", "test"])
                print(String(format: "determinism run %d/%d: exit %d (%.3f s)", index, count, result.status, result.seconds))
                do { digest = try CheckDecisions.digest(status: result.status, output: result.output, expected: digest) }
                catch { throw CheckFailure("run \(index): \(error)\n" + tail(result.output)) }
            }
            print("trace digest: \(digest!) (\(count) runs)")
        case .simulatorEvidence(let base, let bodyFile):
            let diff = try execute(["git", "diff", "--no-renames", "--name-only", "-z", base + "...HEAD", "--"])
            guard diff.status == 0 else { throw CheckFailure("cannot diff \(base)...HEAD\n" + tail(diff.output)) }
            let body = try String(contentsOf: URL(fileURLWithPath: bodyFile, relativeTo: root), encoding: .utf8)
            let decision = SimulatorEvidence(paths: diff.output.split(separator: "\0").map(String.init), body: body)
            guard decision != .missing else { throw CheckFailure(decision.explanation) }
            print(decision.explanation)
        case .mutants: try mutants()
        }
    }

    private func mutants() throws {
        let directory = root.appending(path: "Tests/Mutants")
        let patches = try FileManager.default.subpathsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".patch") }.sorted()
        guard patches.contains(where: { !$0.hasPrefix("guards/") }),
              patches.contains("guards/simulator-import-policy.patch"), patches.contains("guards/policy-wall-clock.patch") else {
            throw CheckFailure("mutants requires a known-bug patch and both E10/E13 guard patches")
        }
        let listing = try execute(["git", "ls-files", "--cached", "-z"])
        guard listing.status == 0 else { throw CheckFailure("cannot list tracked files\n" + tail(listing.output)) }
        let files = listing.output.split(separator: "\0").map(String.init)
        var failures: [String] = []
        for patch in patches {
            let start = ContinuousClock.now
            do {
                let kind = try MutantKind(path: patch)
                let copy = FileManager.default.temporaryDirectory.appending(path: "tessel-mutant-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: copy) }
                try copyTracked(files, to: copy)
                let applied = try execute(["git", "apply", "--", directory.appending(path: patch).path], in: copy)
                guard applied.status == 0 else { throw CheckFailure("patch does not apply\n" + tail(applied.output)) }
                let result = try execute(["swift", "test"], in: copy)
                guard kind.killed(status: result.status, output: result.output) else {
                    let reason = result.status == 0 ? "SURVIVED" : "failed for the wrong reason"
                    throw CheckFailure(reason + "\n" + tail(result.output))
                }
                print(String(format: "mutant %@: killed (%.3f s)", patch, elapsed(start)))
            } catch {
                print(String(format: "mutant %@: FAILED (%.3f s) — %@", patch, elapsed(start), String(describing: error)))
                failures.append(patch)
            }
        }
        guard failures.isEmpty else { throw CheckFailure("mutants failed: " + failures.joined(separator: ", ")) }
    }

    private func copyTracked(_ paths: [String], to directory: URL) throws {
        let groups = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
        for parent in groups.keys.sorted() {
            let files = groups[parent]!.filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
            guard !files.isEmpty else { continue }
            let destination = directory.appending(path: parent)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // Spawn once per directory rather than once per small source file.
            let clone = try execute(["/bin/cp", "-c"] + files.map { root.appending(path: $0).path } + [destination.path])
            if clone.status != 0 {
                for path in files {
                    let source = root.appending(path: path), target = directory.appending(path: path)
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
        }
    }

    // Merge stdout and stderr and drain while the child runs; neither stream
    // may block a compiler or a failing scenario with a long diagnostic trace.
    private func execute(_ command: [String], in directory: URL? = nil) throws -> CommandResult {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = directory ?? root
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TESSEL_ACCEPTANCE")
        environment.removeValue(forKey: "TESSEL_PURITY_PATH")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let start = ContinuousClock.now
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), seconds: elapsed(start))
    }

    private func tail(_ output: String) -> String { output.components(separatedBy: .newlines).suffix(24).joined(separator: "\n") }
}

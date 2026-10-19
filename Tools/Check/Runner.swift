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
                // Optimize the snapshot once; every replay still runs the full
                // suite and assertions in a fresh process with its own hash seed.
                var arguments = ["swift", "test", "-c", "release"]
                if index > 1 { arguments.append("--skip-build") }
                let result = try execute(arguments)
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
        }
    }

    // Merge stdout and stderr and drain while the child runs; neither stream
    // may block a compiler or a failing scenario with a long diagnostic trace.
    private func execute(_ command: [String]) throws -> CommandResult {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = root
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

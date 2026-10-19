import Carbon
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct Latency {
        let desktop = Desktop()
        let limit: UInt64 = 200_000_000

        init() throws { try desktop.clear() }

        struct Summary: Encodable {
            let count: Int
            let samplesNanoseconds: [UInt64]
            let p50Nanoseconds: UInt64?
            let p95Nanoseconds: UInt64?
            let maxNanoseconds: UInt64?

            init(_ samples: [UInt64]) {
                count = samples.count
                samplesNanoseconds = samples
                let sorted = samples.sorted()
                // Nearest-rank percentile: the ceil(p * n)-th sorted sample.
                func percentile(_ p: Double) -> UInt64? {
                    guard !sorted.isEmpty else { return nil }
                    return sorted[Int(ceil(p * Double(sorted.count))) - 1]
                }
                p50Nanoseconds = percentile(0.5)
                p95Nanoseconds = percentile(0.95)
                maxNanoseconds = sorted.last
            }
        }

        func measure(_ kind: String, index: Int, post: () throws -> Double,
                     focusedOnly: Bool = false, check: (Observation) -> Bool) throws -> UInt64 {
            let start = try post()
            let deadline = start + margin
            while true {
                let observation = try desktop.observe(focusedOnly: focusedOnly)
                if let sample = observation.sampledAt, sample >= start, sample <= deadline, check(observation) {
                    return UInt64((sample - start) * 1e9)
                }
                if monotonicSeconds() >= deadline {
                    throw HarnessError("\(kind) sample \(index + 1)/100 did not complete within the final-state margin")
                }
                sleep(seconds: 0.015)
            }
        }

        func printSummary(_ kind: String, _ samples: [UInt64]) {
            let summary = Summary(samples)
            print(String(format: "%@: %d samples, p50 %.3f ms, p95 %.3f ms, max %.3f ms (p95 limit <= 200 ms)",
                         kind, summary.count, Double(summary.p50Nanoseconds ?? 0) / 1e6,
                         Double(summary.p95Nanoseconds ?? 0) / 1e6, Double(summary.maxNanoseconds ?? 0) / 1e6))
        }

        @Test("#2 U-switch-budget: 100 workspace switches and 100 rail moves")
        func workspaceSwitchesAndRailMoves() throws {
            struct Artifact: Encodable {
                let schemaVersion: Int
                let measuredAt: String
                let sourceRun: String
                let commit: String
                let workingTreeDirty: Bool
                let operatingSystem: String
                let appVersion: String
                let clock: String
                let percentile: String
                let p95LimitNanoseconds: UInt64
                let requestedSamplesPerKind: Int
                let workspace: Summary
                let rails: Summary
                let railScrollCount: Int
                let railElevatorCount: Int
                let failure: String?
            }
            let measuredAt = ISO8601DateFormatter().string(from: Date())
            let commit = try run(["git", "-C", root.path, "rev-parse", "HEAD"], timeout: margin, check: true).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let dirty = try !run(["git", "-C", root.path, "status", "--porcelain"], timeout: margin, check: true).output.isEmpty
            let version = try desktop.harness.status().version
            var switches: [UInt64] = [], moves: [UInt64] = []
            var scrolls = 0, elevators = 0
            func writeArtifact(failure: String? = nil) throws {
                let artifact = Artifact(schemaVersion: 1, measuredAt: measuredAt,
                    sourceRun: ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? "local", commit: commit, workingTreeDirty: dirty,
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: version,
                    clock: "CLOCK_MONOTONIC_RAW: fixture postedAt to independent observer sampledAt",
                    percentile: "nearest-rank", p95LimitNanoseconds: limit, requestedSamplesPerKind: 100,
                    workspace: Summary(switches), rails: Summary(moves), railScrollCount: scrolls,
                    railElevatorCount: elevators, failure: failure)
                let path = root.appending(path: ".work/latency.json")
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(artifact).write(to: path, options: .atomic)
            }
            do {
                let (a, b) = try desktop.split()
                for index in 0..<100 {
                    let destination = index.isMultiple(of: 2) ? 2 : 1
                    let target = destination == 2 ? b : a, hidden = destination == 2 ? a : b
                    switches.append(try measure("Workspace switch", index: index,
                        post: { try desktop.key(destination) }, focusedOnly: true) { observation in
                            desktop.shown(target, in: observation) && !observation.visibleIDs.contains(hidden)
                        })
                }
                printSummary("Workspace switches", switches)
                try desktop.clear()
                let elevatorApp = try FixtureSession(directory: desktop.harness.directory, number: 1)
                desktop.harness.otherFixtures.append(elevatorApp)
                let ids = try desktop.railSetup(firstIn: elevatorApp)
                try desktop.post(kVK_ANSI_J, shift: true)
                try desktop.expectFocus(ids[0])
                try requireFinalState("the latency setup's second rail") { try desktop.harness.row(ids[0])?.rail == 2 }
                try desktop.post(kVK_ANSI_K)
                try desktop.expectFocus(ids[4])
                try desktop.post(kVK_ANSI_L)
                try desktop.expectFocus(ids[1])
                try desktop.post(kVK_ANSI_L)
                try desktop.expectFocus(ids[2])
                try desktop.post(kVK_ANSI_J)
                try desktop.expectFocus(ids[0])
                let area = try desktop.observe().area
                let width = try #require(try desktop.window(ids[0])).frame[2]
                let step = width + 10, right = area[0] + area[2] - 10 - 56 - width
                for index in 0..<100 {
                    let phase = index % 4
                    let elevator = phase == 0 || phase == 3
                    let slot = (1 + (index / 4) * 2 + (elevator ? 0 : phase)) % 4
                    let target = phase == 3 ? ids[0] : ids[slot + 1]
                    let sample = try measure(elevator ? "Rail elevator" : "Rail scroll", index: index,
                        post: { try desktop.post(phase == 0 ? kVK_ANSI_K : phase == 3 ? kVK_ANSI_J : kVK_ANSI_L) }) { observation in
                            guard desktop.focused(target, in: observation) else { return false }
                            if phase == 3 {
                                return observation.windows.contains {
                                    $0.id == ids[0] && desktop.near($0.frame, [area[0] + 10, area[1] + 10, width, area[3] - 20])
                                } && Set(ids.dropFirst()).isDisjoint(with: observation.visibleIDs)
                            }
                            // Worked four-window ring: focus at the reveal edge, then its
                            // next, opposite and previous neighbors.
                            let offsets = [0.0, step, -2 * step, -step]
                            return ids.dropFirst().enumerated().allSatisfy { position, id in
                                let x = right + offsets[(position - slot + 4) % 4]
                                let visible = x + width > area[0] && x < area[0] + area[2]
                                guard observation.visibleIDs.contains(id) == visible else { return false }
                                guard visible else { return true }
                                return observation.windows.contains {
                                    $0.id == id && desktop.near($0.frame, [x, area[1] + 10, width, area[3] - 20])
                                }
                            } && !observation.visibleIDs.contains(ids[0])
                        }
                    moves.append(sample)
                    if elevator { elevators += 1 } else { scrolls += 1 }
                }
                printSummary("Rail moves (50 scrolls, 50 cross-app elevator trips)", moves)
            } catch {
                try writeArtifact(failure: String(describing: error))
                throw error
            }
            try writeArtifact()
            try #require(switches.count == 100 && moves.count == 100 && scrolls == 50 && elevators == 50)
            #expect(Summary(switches).p95Nanoseconds! <= limit, "workspace switch p95 exceeds 200 ms")
            #expect(Summary(moves).p95Nanoseconds! <= limit, "rail move p95 exceeds 200 ms")
        }
    }
}

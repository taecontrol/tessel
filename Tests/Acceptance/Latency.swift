import Carbon
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct Latency {
        let desktop = Desktop()
        let limit: UInt64 = 200_000_000
        // Measure processing/observation latency against the existing CI budget.
        // E16/E17 prove intentional animation timing with the virtual clock.
        let animationDuration = 0

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
                     focusedOnly: Bool = false, read: (() throws -> Observation)? = nil, check: (Observation) -> Bool) throws -> UInt64 {
            let start = try post()
            let deadline = start + margin
            while true {
                let observation: Observation
                if let read { observation = try read() }
                else { observation = try desktop.observe(focusedOnly: focusedOnly) }
                if let sample = observation.sampledAt, sample >= start, sample <= deadline, check(observation) {
                    return UInt64((sample - start) * 1e9)
                }
                if monotonicSeconds() >= deadline {
                    throw HarnessError("\(kind) sample \(index + 1)/100 did not complete within the final-state margin")
                }
                sleep(seconds: 0.015)
            }
        }

        func printSummary(_ kind: String, _ samples: [UInt64], budget: UInt64? = nil) {
            let summary = Summary(samples)
            print(String(format: "%@: %d samples, p50 %.3f ms, p95 %.3f ms, max %.3f ms (p95 limit <= %.0f ms)",
                         kind, summary.count, Double(summary.p50Nanoseconds ?? 0) / 1e6,
                         Double(summary.p95Nanoseconds ?? 0) / 1e6, Double(summary.maxNanoseconds ?? 0) / 1e6, Double(budget ?? limit) / 1e6))
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
                let workspaceP95LimitNanoseconds: UInt64
                let railP95LimitNanoseconds: UInt64
                let requestedSamplesPerKind: Int
                let railAnimationDurationMilliseconds: Int
                let completion: String
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
                let artifact = Artifact(schemaVersion: 2, measuredAt: measuredAt,
                    sourceRun: ProcessInfo.processInfo.environment["GITHUB_RUN_ID"] ?? "local", commit: commit, workingTreeDirty: dirty,
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: version,
                    clock: "CLOCK_MONOTONIC_RAW: fixture postedAt to independent observer sampledAt",
                    percentile: "nearest-rank", workspaceP95LimitNanoseconds: limit, railP95LimitNanoseconds: limit, requestedSamplesPerKind: 100,
                    railAnimationDurationMilliseconds: animationDuration, completion: "final WindowServer frames, AX main/focus and CG visibility",
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
                let area = try desktop.observe().area
                let width = (area[2] - 30) / 2
                // Settle the default motion before changing to the measured
                // duration below; that write must be a real config revision.
                let ids = try desktop.railSetup(Array(repeating: width / (area[2] - 20), count: 5),
                    firstIn: elevatorApp)
                let top = Array(ids.dropFirst())
                func landed(pair: Int?, focus: UInt32, in observation: Observation, frames: [UInt32: [Double]]? = nil) -> Bool {
                    guard desktop.focused(focus, in: observation) else { return false }
                    let shown = pair.map { [top[$0], top[$0 + 1]] } ?? [ids[0]]
                    return ids.allSatisfy { id in
                        guard let slot = shown.firstIndex(of: id) else { return !observation.visibleIDs.contains(id) }
                        let frame = [area[0] + 10 + Double(slot) * (width + 10), area[1] + 10,
                                     width, area[3] - 20]
                        guard observation.visibleIDs.contains(id) else { return false }
                        if let frames { return frames[id].map { desktop.near($0, frame) } == true }
                        return observation.windows.contains { $0.id == id && $0.visible && desktop.near($0.frame, frame) }
                    }
                }
                try desktop.post(kVK_ANSI_J, shift: true)
                try requireFinalState("the latency setup's settled singleton second rail") {
                    try desktop.harness.row(ids[0])?.rail == 2
                        && landed(pair: nil, focus: ids[0], in: desktop.observe())
                }
                try desktop.post(kVK_ANSI_K)
                try desktop.activate(key: "w1")
                try desktop.post(kVK_ANSI_L)
                try requireFinalState("the latency setup's first complete half-width pair") {
                    try landed(pair: 0, focus: top[1], in: desktop.observe())
                }
                try desktop.post(kVK_ANSI_J)
                try requireFinalState("the latency setup returns to its second rail") {
                    try landed(pair: nil, focus: ids[0], in: desktop.observe())
                }
                try desktop.configure(desktop.carousel + "[animation]\nduration = \(animationDuration)\n", layout: "carousel")
                var pair = 0
                var topFocus = top[1]
                for index in 0..<100 {
                    let phase = index % 4
                    let direction = (index / 4).isMultiple(of: 2) ? 1 : -1
                    let elevator = phase == 0 || phase == 3
                    let horizontal = direction > 0 ? kVK_ANSI_L : kVK_ANSI_H
                    if phase == 1 {
                        // Cross the already complete pair outside measurement.
                        // Both measured horizontal commands then advance a stop.
                        topFocus = top[pair + (direction > 0 ? 1 : 0)]
                        if try !desktop.focused(topFocus, in: desktop.observe()) {
                            try desktop.post(horizontal)
                            try requireFinalState("the outward complete tile selected without scrolling") {
                                try landed(pair: pair, focus: topFocus, in: desktop.observe())
                            }
                        }
                    }
                    if !elevator {
                        pair += direction
                        topFocus = top[pair + (direction > 0 ? 1 : 0)]
                    }
                    let target = phase == 3 ? ids[0] : topFocus
                    let expectedPair: Int? = phase == 3 ? nil : pair
                    var measuredFrames: [UInt32: [Double]] = [:]
                    let sample = try measure(elevator ? "Carousel elevator" : "Carousel scroll", index: index,
                        post: { try desktop.post(phase == 0 ? kVK_ANSI_K : phase == 3 ? kVK_ANSI_J : horizontal) }, read: {
                            // The signed geometry contract pins these bounds to
                            // accepted AX frames, even when the app is busy.
                            // Read native main/focus and CG visibility last;
                            // sampledAt then dates the latest actual input.
                            measuredFrames.removeAll(keepingCapacity: true)
                            for session in [desktop.fixture, elevatorApp] {
                                let reply = try desktop.harness.observer.command("contract", ["operation": "cgFrames", "pid": session.pid])
                                for (key, frame) in reply.contract?.cgFrames ?? [:] {
                                    if let id = UInt32(key) { measuredFrames[id] = frame }
                                }
                            }
                            return try desktop.observe(focusedOnly: true)
                        }) { landed(pair: expectedPair, focus: target, in: $0, frames: measuredFrames) }
                    moves.append(sample)
                    if elevator { elevators += 1 } else { scrolls += 1 }
                }
                printSummary("Rail moves (50 scrolls, 50 cross-app elevator trips)", moves, budget: limit)
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

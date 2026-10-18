import Darwin
import Synchronization
import Simulator
import Testing

final class ScenarioDigests: Sendable {
    private struct Entry: Sendable {
        let name: String
        let digest: String
    }
    static let shared: ScenarioDigests = {
        let collector = ScenarioDigests()
        // Swift Testing has no process-wide suite teardown. Exit runs after
        // every suite, including when their execution order changes.
        atexit { print("trace digest: \(ScenarioDigests.shared.digest)") }
        return collector
    }()
    private let entries = Mutex<[Entry]>([])

    func record(_ result: ScenarioResult) {
        let entry = Entry(name: result.schedule.joined(separator: " → "), digest: result.digest)
        entries.withLock { $0.append(entry) }
    }

    var digest: String {
        let sorted = entries.withLock { $0 }.sorted { ($0.name, $0.digest) < ($1.name, $1.digest) }
        let text = sorted.map { $0.name + "\n" + $0.digest }.joined(separator: "\n")
        return BatonScheduler.digest(text)
    }
}

@Suite @MainActor struct DigestFramework {
    @Test("E2: the aggregate includes every run and changed trace, preserves duplicates, and ignores execution order")
    func aggregateMembership() {
        let first = ScenarioResult(failures: [], schedule: ["first"], trace: ["first trace"])
        let second = ScenarioResult(failures: [], schedule: ["second"], trace: ["second trace"])
        let changed = ScenarioResult(failures: [], schedule: first.schedule, trace: ["changed trace"])
        let forward = ScenarioDigests(), reverse = ScenarioDigests(), different = ScenarioDigests()
        let empty = forward.digest
        forward.record(first)
        #expect(forward.digest != empty)
        let one = forward.digest
        forward.record(second)
        #expect(forward.digest != one)
        reverse.record(second); reverse.record(first)
        #expect(forward.digest == reverse.digest)
        different.record(changed); different.record(second)
        #expect(forward.digest != different.digest)
        let two = forward.digest
        forward.record(first)
        #expect(forward.digest != two)

        let before = ScenarioDigests.shared.digest
        requireScenario(Scenario.run("aggregate recorder smoke") { $0.settle() })
        #expect(ScenarioDigests.shared.digest != before)
    }
}

import Foundation
import Simulator
import Testing

@Suite @MainActor struct TraceDeterminism {
    private func catalog() -> [ScenarioResult] {
        var results: [ScenarioResult] = []
        for layout in [Layout.rails, .stack] {
            for order in EnablingScenarios.schedules { results.append(EnablingScenarios.run(order, layout: layout)) }
        }
        results.append(Scenario.run("omitted handles and subscription removal") { scenario in
            let app = scenario.mac.launch(windows: 4)
            _ = scenario.startTessel()
            scenario.settle()
            app.publishNextWindowLists([.omitting([1, 2, 3, 4])])
            scenario.settle()
            app.close(1); app.close(2); app.close(3)
            scenario.settle()
        })
        return results
    }

    @Test("E2: fixed catalog and enumerated schedules replay with identical trace digests")
    func replayCatalog() {
        let start = ContinuousClock.now
        let first = catalog()
        let second = catalog()
        for result in first + second { requireScenario(result) }
        for (index, pair) in zip(first, second).enumerated() where pair.0.digest != pair.1.digest {
            let difference = zip(pair.0.trace, pair.1.trace).first { $0 != $1 }
            print("Replay \(index) diverged: \(difference.map { $0.0 + " | " + $0.1 } ?? "different trace lengths")")
        }
        #expect(first.map(\.digest) == second.map(\.digest))
        #expect(first.allSatisfy { $0.digest.count == 64 })
        let aggregate = BatonScheduler.digest(first.map(\.digest).joined(separator: "\n"))
        print("trace digest: \(aggregate)")
        print("deterministic catalog total time: \(start.duration(to: .now)) (\(first.count * 2) replays)")
    }
}

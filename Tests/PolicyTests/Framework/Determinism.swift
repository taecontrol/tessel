import Foundation
import Simulator
import Testing

@Suite @MainActor struct TraceDeterminism {
    private func omittedHandles() -> ScenarioResult {
        Scenario.run("omitted handles and subscription removal") { scenario in
            let app = scenario.mac.launch(windows: 4)
            _ = scenario.startTessel()
            scenario.settle()
            app.publishNextWindowLists([.omitting([1, 2, 3, 4])])
            scenario.settle()
            app.close(1); app.close(2); app.close(3)
            scenario.settle()
        }
    }

    @Test("E2: omitted handles and subscription removal replay with identical trace digests")
    func replayOmittedHandles() {
        // This small replay exercises AX reads, omissions, native events and
        // subscription removal. Enabling's full enumeration already runs once.
        let first = omittedHandles(), second = omittedHandles()
        for result in [first, second] { requireScenario(result) }
        let firstDigest = first.digest, secondDigest = second.digest
        if firstDigest != secondDigest {
            let difference = zip(first.trace, second.trace).first { $0 != $1 }
            print("Replay diverged: \(difference.map { $0.0 + " | " + $0.1 } ?? "different trace lengths")")
        }
        #expect(firstDigest == secondDigest)
        #expect(firstDigest.count == 64)
    }
}

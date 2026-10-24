import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct ListingGateBudget {
    @Test("#40 E11: coinciding and overlapping deadlines release independently without extra rechecks", arguments: WriteOrder.allCases, [0, 1, 7])
    func overlappingWaitsPreserveCadenceAndBudgets(_ writes: WriteOrder, _ spacing: Int) {
        requireCarousel(Scenario.run("ten missing listings, acceptance spacing \(spacing)ms", writes: writes) { s in
            let mac = s.mac, app = mac.launch(windows: 10), ids = app.windows.sorted()
            let windows = Set(ids), start = mac.scheduler.now
            mac.omitListings(of: windows)
            let gate = ListingGate(order: mac.windowOrder, scheduler: mac.scheduler)
            var released: [UInt32: Int] = [:]
            var initialReads = Set<Int>()
            @MainActor func recheck() {
                for id in gate.settled(windows, onScreen: true) where released[id] == nil { released[id] = mac.scheduler.now }
                gate.scheduleRecheck(recheck)
            }
            @MainActor func accept(_ accepted: Set<UInt32>) {
                gate.track(Dictionary(uniqueKeysWithValues: accepted.map { ($0, mac.frame($0)!) }))
                let first = mac.listingReads.count
                _ = gate.settled(accepted, onScreen: true)
                initialReads.formUnion(first..<mac.listingReads.count)
                gate.scheduleRecheck(recheck)
            }
            if spacing == 0 { accept(windows) }
            else {
                accept([ids[0]])
                for (index, id) in ids.enumerated().dropFirst() {
                    s.after(milliseconds: index * spacing, "AX accepts window \(id)") { accept([id]) }
                }
            }
            s.settle()
            for (index, id) in ids.enumerated() {
                s.expect("window \(id) releases at its own 100 ms deadline", released[id] == start + index * spacing + 100)
            }
            let reads = mac.listingReads
            let counts = ids.map { id in reads.filter { $0.windows.contains(id) }.count }
            s.expect("every wait gets at most 26 listing reads: \(counts)", counts.allSatisfy { $0 > 0 && $0 <= 26 })
            let rechecks = reads.enumerated().filter { !initialReads.contains($0.offset) }.map(\.element)
            s.expect("rechecks stay at least 4 ms apart: \(rechecks.map(\.at))", zip(rechecks, rechecks.dropFirst()).allSatisfy { $1.at - $0.at >= 4 })
            let lastDeadline = start + (ids.count - 1) * spacing + 100
            s.expect("expiries preserve the shared 4 ms cadence", rechecks.map(\.at) == Array(stride(from: start + 4, to: lastDeadline, by: 4)))
            s.expect("every query asks only for unexpired waits", reads.allSatisfy { read in
                !read.windows.isEmpty && read.windows.allSatisfy { id in released[id].map { read.at < $0 } == true }
            })
            s.expect("resolved waits leave no listing timer", mac.scheduler.pendingMainDelays.isEmpty)
            let idle = mac.scheduler.trace.count
            s.settle()
            s.expect("a resolved gate does no work at rest", mac.scheduler.trace.count == idle && mac.listingReads.count == reads.count)
            gate.cancel()
        })
    }
}

import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailStaleChrome {
    @Test("#51 E1: stale chrome preserves every publication, rail order and nominal width, then stops retrying",
          arguments: WriteOrder.allCases, [false, true])
    func retainedMembership(_ writes: WriteOrder, parked: Bool) {
        for persistent in [false, true] {
            requireScenario(Scenario.run("stale chrome parked=\(parked) persistent=\(persistent)", writes: writes) { s in
                let f = RailFixture(s, widths: Array(repeating: 0.22, count: 6)), ids = f.ids, target = ids[2]
                f.select(target); f.press("cycle width", focus: target)
                let nominal = (f.area.width + 10) / 3 - 10
                f.near(f.frame(target).width, nominal, "setup: target has a nominal third")
                f.press("move down", focus: target)
                f.select(ids[3]); f.press("move down", focus: ids[3])
                f.select(target); f.press("move right", focus: target)
                f.select(ids[4]); f.press("move down", focus: ids[4]); f.press("move down", focus: ids[4])
                f.select(target)
                f.order([ids[0], ids[1], ids[5]]); f.order([ids[3], target], rail: 2); f.order([ids[4]], rail: 3)
                if parked {
                    f.select(ids[0])
                    f.app.moveFromApplication(target, to: CGPoint(x: -2_000, y: f.frame(target).minY))
                    s.settle()
                    s.expect("setup: the target is parked outside the display", f.mac.isInCloset(target) && f.frame(target).maxX < 0)
                }
                let expected = locations(f.tessel.windows), start = f.mac.scheduler.now
                let publications = f.tessel.windowPublications.count
                let traceStart = f.mac.scheduler.trace.count
                f.app.replaceChromeDescendant(in: target, forReads: persistent ? .max : 1)
                s.settle()
                if persistent {
                    let backoffs = f.mac.scheduler.trace.dropFirst(traceStart).filter {
                        $0.contains("tessel.ax.\(f.app.pid) SchedulingPort.after +")
                    }.compactMap { line -> Int? in
                        guard let plus = line.lastIndex(of: "+"), let delay = Int(line[line.index(after: plus)...].dropLast(2)), delay >= 100 else { return nil }
                        return delay
                    }
                    s.expect("incomplete reads use the existing bounded backoff, actual \(backoffs)", backoffs == [100, 200, 400, 800])
                    s.expect("persistently incomplete reads publish no partial rows", f.tessel.windowPublications.count == publications)
                    let trace = f.mac.scheduler.trace.count
                    s.after(milliseconds: 2_000, "observe idle after the bounded retries") {}
                    s.settle()
                    s.expect("exhausted retries do no more AX work until another event", !f.mac.scheduler.trace.dropFirst(trace).contains { $0.contains("AccessibilityPort.") })
                    let recoveredAt = f.mac.scheduler.now
                    f.app.replaceChromeDescendant(in: target, forReads: 0)
                    s.settle()
                    FoundationProof.publication(f.tessel, pid: f.app.pid, since: recoveredAt, within: 500, scenario: s) {
                        locations($0) == expected
                    }
                } else {
                    FoundationProof.publication(f.tessel, pid: f.app.pid, since: start, within: 500, scenario: s) {
                        locations($0) == expected
                    }
                }
                let published = f.tessel.windowPublications.dropFirst(publications).filter { $0.pid == f.app.pid }
                s.expect("every publication retains the live target", !published.isEmpty && published.allSatisfy { $0.windows?.contains { $0.id == target } == true })
                s.expect("every publication keeps workspace, rail, slot and rail order", published.allSatisfy { locations($0.windows ?? []) == expected })
                s.expect("the target keeps its original membership", f.tessel.windows.first { $0.id == target }.map { $0.state == .tiled && $0.workspace == 1 && $0.rail == 2 && $0.slot == 2 } == true)
                f.select(target)
                f.near(f.frame(target).width, nominal, "recovery retains the nominal width")
                f.press("cycle width", focus: target)
                f.near(f.frame(target).width, (f.area.width + 10) / 2 - 10, "the retained preset advances from a third to half")
            })
        }
    }

    @Test("#51 E2: real closes retire roots within 500 virtual ms, including retained handles and a close during chrome",
          arguments: WriteOrder.allCases, [false, true])
    func realClose(_ writes: WriteOrder, duringWalk: Bool) {
        for stillListed in [false, true] {
            requireScenario(Scenario.run("real close duringWalk=\(duringWalk) retained=\(stillListed)", writes: writes) { s in
                let f = RailFixture(s, widths: [0.3, 0.3]), target = f.ids[1]
                if duringWalk {
                    f.app.replaceChromeDescendant(in: target)
                    let held = f.mac.pause(after: .call("AccessibilityPort.copy AXRole chrome(0) window \(target) \(f.app.alias)"))
                    if case .paused = held {} else { s.expect("the descendant read is outstanding: \(held)", false) }
                }
                if stillListed { f.app.publishNextWindowLists(Array(repeating: .includingClosed([target]), count: 20)) }
                let closedAt = f.mac.scheduler.now
                f.app.close(target)
                s.settle()
                FoundationProof.publication(f.tessel, pid: f.app.pid, since: closedAt, within: 500, scenario: s) { !$0.contains { $0.id == target } }
                s.expect("the real close leaves only the live root", f.tessel.windows.map(\.id) == [f.ids[0]])
            })
        }
    }

    @Test("#51 E4: a sheet closed at its own root cannot skip its parent, sibling sheets or other windows", arguments: WriteOrder.allCases)
    func closedSheet(_ writes: WriteOrder) {
        requireScenario(Scenario.run("sheet closes after chrome discovers it", writes: writes) { s in
            let f = RailFixture(s, widths: [0.3, 0.3]), parent = f.ids[0]
            let closed = f.app.open(WindowSpec(subrole: "AXDialog", parent: parent), background: true)
            s.settle()
            let publications = f.tessel.windowPublications.count
            // This sibling is discovered in the same walk, with no cached handle
            // to rescue it if the closed sheet aborts the parent's inspection.
            let sibling = f.app.open(WindowSpec(subrole: "AXDialog", parent: parent), background: true)
            let held = f.mac.pause(after: .call("AccessibilityPort.windowID window \(closed) \(f.app.alias)"))
            if case .paused = held {} else { s.expect("the sheet's root read is outstanding: \(held)", false) }
            let closedAt = f.mac.scheduler.now
            f.app.close(closed)
            s.settle()
            let survivors = Set(f.ids + [sibling])
            let published = f.tessel.windowPublications.dropFirst(publications).filter { $0.pid == f.app.pid }
            s.expect("every publication keeps the parent, sibling sheet and unrelated window", !published.isEmpty && published.allSatisfy { Set(($0.windows ?? []).map(\.id)) == survivors })
            FoundationProof.publication(f.tessel, pid: f.app.pid, since: closedAt, within: 500, scenario: s) { Set($0.map(\.id)) == survivors }
        })
    }

    @Test("#51 E5: stale chrome inside a sheet preserves the complete parent and sibling snapshot", arguments: WriteOrder.allCases)
    func staleSheet(_ writes: WriteOrder) {
        requireScenario(Scenario.run("sheet descendant replacement", writes: writes) { s in
            let f = RailFixture(s, widths: [0.3, 0.3]), parent = f.ids[0]
            let sheet = f.app.open(WindowSpec(subrole: "AXDialog", parent: parent), background: true)
            let sibling = f.app.open(WindowSpec(subrole: "AXDialog", parent: parent), background: true)
            s.settle()
            let expected = locations(f.tessel.windows), publications = f.tessel.windowPublications.count
            s.expect("setup: both sheets are published", Set(f.tessel.windows.map(\.id)) == Set(f.ids + [sheet, sibling]))
            let start = f.mac.scheduler.now
            f.app.replaceChromeDescendant(in: sheet)
            s.settle()
            let published = f.tessel.windowPublications.dropFirst(publications).filter { $0.pid == f.app.pid }
            s.expect("no partial parent or sibling snapshot is published", !published.isEmpty && published.allSatisfy { locations($0.windows ?? []) == expected })
            FoundationProof.publication(f.tessel, pid: f.app.pid, since: start, within: 500, scenario: s) { locations($0) == expected }
        })
    }

    private func locations(_ rows: [WindowRecord]) -> [String] {
        rows.sorted { $0.id < $1.id }.map { "\($0.id):\($0.workspace ?? 0):\($0.rail ?? 0):\($0.slot ?? 0)" }
    }
}

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

    @Test("#51 E5: stale chrome inside a sheet preserves the complete snapshot and sibling destruction subscription",
          arguments: WriteOrder.allCases, [false, true])
    func staleSheet(_ writes: WriteOrder, persistent: Bool) {
        requireScenario(Scenario.run("sheet descendant replacement persistent=\(persistent)", writes: writes) { s in
            let f = RailFixture(s, widths: [0.3, 0.3]), parent = f.ids[0]
            let sheet = f.app.open(WindowSpec(subrole: "AXDialog", parent: parent), background: true)
            let sibling = f.app.open(WindowSpec(subrole: "AXDialog", parent: parent), background: true)
            s.settle()
            let expected = locations(f.tessel.windows), publications = f.tessel.windowPublications.count
            s.expect("setup: both sheets are published", Set(f.tessel.windows.map(\.id)) == Set(f.ids + [sheet, sibling]))
            let start = f.mac.scheduler.now
            f.app.replaceChromeDescendant(in: sheet, forReads: persistent ? 5 : 1)
            s.settle()
            let published = f.tessel.windowPublications.dropFirst(publications).filter { $0.pid == f.app.pid }
            s.expect("no partial parent or sibling snapshot is published", published.allSatisfy { locations($0.windows ?? []) == expected })
            if persistent {
                s.expect("all five incomplete attempts retain the complete snapshot", published.isEmpty)
                let closedAt = f.mac.scheduler.now
                f.app.close(sibling)
                s.settle()
                let survivors = Set(f.ids + [sheet])
                s.expect("the unvisited sibling's destruction is still observed after retries stop", Set(f.tessel.windows.map(\.id)) == survivors)
                FoundationProof.publication(f.tessel, pid: f.app.pid, since: closedAt, within: 500, scenario: s) { Set($0.map(\.id)) == survivors }
            } else {
                FoundationProof.publication(f.tessel, pid: f.app.pid, since: start, within: 500, scenario: s) { locations($0) == expected }
            }
        })
    }

    @Test("#51 E7: an omitted parent does not reinspect its already-read focused sheet", arguments: WriteOrder.allCases)
    func omittedParent(_ writes: WriteOrder) {
        requireScenario(Scenario.run("focused sheet before its omitted parent", writes: writes) { s in
            let f = RailFixture(s, widths: [0.3, 0.3]), parent = f.ids[0]
            let sheet = f.app.open(WindowSpec(subrole: "AXDialog", parent: parent))
            s.settle()
            f.app.publishNextWindowLists(Array(repeating: .omitting([parent]), count: 20))
            f.app.select(sheet)
            let windowList = "AccessibilityPort.copy AXWindows \(f.app.alias) pid=\(f.app.pid)"
            let first = f.mac.pause(after: .call(windowList))
            if case .paused = first {} else { s.expect("the first window list read is outstanding: \(first)", false) }
            let trace = f.mac.scheduler.trace.count
            f.mac.scheduler.resume()
            let confirmation = f.mac.pause(after: .call(windowList))
            if case .paused = confirmation {} else { s.expect("the confirmation follows one complete inspection: \(confirmation)", false) }
            let inspections = f.mac.scheduler.trace.dropFirst(trace).filter { $0.contains("AccessibilityPort.copy AXMinimized window \(sheet) ") }
            s.expect("the focused sheet is inspected only once in the snapshot, actual \(inspections.count)", inspections.count == 1)
            s.settle()
            s.expect("the omitted parent and focused sheet both remain published", Set(f.tessel.windows.map(\.id)) == Set(f.ids + [sheet]))
        })
    }

    @Test("incomplete chrome reads keep native bar subscriptions without AX removal and registration churn")
    func retainedBarSubscriptions() {
        requireScenario(Scenario.run("incomplete root before an already subscribed native bar") { s in
            let app = s.mac.launch(windows: 3)
            app.groupTabs([2, 3], selected: 2)
            let tessel = s.startTessel()
            s.settle()
            s.expect("setup: the native group is published", tessel.windows.first { $0.id == 2 }?.tabs == 2)
            let trace = s.mac.scheduler.trace.count
            app.replaceChromeDescendant(in: 1, forReads: 5)
            s.settle()
            app.replaceChromeDescendant(in: 1, forReads: 0)
            s.settle()
            let registrations = s.mac.scheduler.trace.dropFirst(trace).filter {
                $0.contains("AXObservation.remove") || $0.contains("AXObservation.add")
            }
            s.expect("incomplete reads and recovery preserve existing subscriptions without extra AX calls", registrations.isEmpty)
            let reads = s.mac.scheduler.trace.dropFirst(trace).filter {
                $0.contains("tessel.ax.\(app.pid) AccessibilityPort.copy")
            }
            let staleReplies = reads.indices.filter { reads[$0].contains("invalidUIElement") }
            s.expect("each stale child ends the read without a root probe or immediate chrome rewalk", staleReplies.count == 5 && staleReplies.allSatisfy {
                let next = reads.index(after: $0)
                return next < reads.endIndex && reads[next].contains("AccessibilityPort.copy AXWindows \(app.alias)")
            })
            s.expect("the group remains published after recovery", tessel.windows.first { $0.id == 2 }?.tabs == 2)
        })
    }

    @Test("a confirmed root closure during chrome does not schedule an incomplete-read retry")
    func closedRootDuringChrome() {
        requireScenario(Scenario.run("retained root closes after its chrome role reply") { s in
            let f = RailFixture(s, widths: [0.3, 0.3]), target = f.ids[1]
            f.app.publishNextWindowLists(Array(repeating: .includingClosed([target]), count: 20))
            f.app.replaceChromeDescendant(in: target)
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXRole window \(target) \(f.app.alias)"))
            if case .paused = held {} else { s.expect("the root's chrome role read is outstanding: \(held)", false) }
            let trace = f.mac.scheduler.trace.count, closedAt = f.mac.scheduler.now
            f.app.close(target)
            s.settle()
            FoundationProof.publication(f.tessel, pid: f.app.pid, since: closedAt, within: 500, scenario: s) {
                $0.map(\.id) == [f.ids[0]]
            }
            s.expect("a dead root is omitted without an incomplete-read backoff", !f.mac.scheduler.trace.dropFirst(trace).contains {
                $0.contains("tessel.ax.\(f.app.pid) SchedulingPort.after +100ms")
            })
        })
    }

    private func locations(_ rows: [WindowRecord]) -> [String] {
        rows.sorted { $0.id < $1.id }.map { "\($0.id):\($0.workspace ?? 0):\($0.rail ?? 0):\($0.slot ?? 0)" }
    }
}

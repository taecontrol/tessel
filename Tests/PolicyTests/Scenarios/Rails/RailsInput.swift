import Foundation
import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RailInput {
    @Test("#17 E7; #17 E16: cross-app elevator travel and external activation preserve the destination selection", arguments: WriteOrder.allCases)
    func crossAppElevator(order: WriteOrder) {
        requireScenario(Scenario.run("cross-app elevator", writes: order) { s in
            let f = RailFixture(s, widths: [0.25, 0.08, 0.08, 0.08]), a = f.ids[0]
            let other = f.mac.launch(), b = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 250, height: 400)))
            s.settle(); f.focus(b); f.order([a, b] + Array(f.ids.dropFirst()))
            f.press("move down", focus: b)
            let sizes = f.frames(f.ids + [b]).map(\.size)
            for _ in 0..<3 {
                f.press("focus up", focus: a)
                s.expect("the other app's rail is hidden", !f.mac.isVisible(b))
                f.press("focus down", focus: b)
                s.expect("every source window is hidden", f.ids.allSatisfy { !f.mac.isVisible($0) })
                f.invariants(f.ids + [b], sizes: sizes)
            }
            f.press("focus up", focus: a); f.select(b)
            s.expect("external activation follows the hidden rail", f.tessel.status.rail == 2)
            f.press("focus up", focus: a)
        })
    }

    @Test("#17 E7: an accepted but unconfirmed activation is rechecked after 50 virtual milliseconds")
    func deferredActivation() {
        requireScenario(Scenario.run("unconfirmed cross-app activation", writes: .readsFirst) { s in
            let f = RailFixture(s, widths: [0.25]), a = f.ids[0]
            let other = f.mac.launch(), b = other.open(WindowSpec())
            s.settle(); f.press("move down", focus: b); f.press("focus up", focus: a)
            other.deferNextActivation(completion: .nextRequest)
            let start = f.mac.scheduler.trace.count
            f.tessel.press("focus down"); s.settle(); f.focus(b)
            let trace = Array(f.mac.scheduler.trace.dropFirst(start)), lane = "tessel.ax.\(other.pid)"
            let requests = trace.filter { $0.contains("\(lane) AccessibilityPort.set AXFrontmost=true ") }
            s.expect("only the unconfirmed activation is retried", requests.count == 2)
            guard requests.count == 2 else { return }
            func time(_ line: String) -> Int { Int(line.dropFirst().prefix { $0.isNumber })! }
            let check = trace.first { $0.contains("\(lane) SchedulingPort.after +50ms") }
            s.expect("an activation recheck is scheduled", check != nil)
            if let check {
                let recheckTime = time(check) + 50
                let reads = trace.filter { $0.contains("\(lane) AccessibilityPort.copy AXHidden \(other.alias) ") }.map(time)
                s.expect("the activation recheck starts at its exact virtual deadline", reads.contains(recheckTime))
            }
        })
    }

    @Test("#17 E16: external same-app focus uses the 50 ms virtual decision window")
    func externalFocusDelay() {
        requireScenario(Scenario.run("bounded external focus decision", writes: .readsFirst) { s in
            let f = RailFixture(s, widths: [0.25, 0.25]), a = f.ids[0], b = f.ids[1]
            f.press("move down", focus: a)
            f.app.select(b)
            let captured = f.mac.pause(after: .read(f.app))
            if case .paused = captured {} else { s.expect("external focus read is captured: \(captured)", false) }
            let delivered = f.mac.deliver(f.app)
            if case .paused = delivered {} else { s.expect("external focus read is published: \(delivered)", false) }
            var before = false, after = false
            f.mac.scheduler.main.after(milliseconds: 49) { before = f.tessel.status.rail == 2 }
            f.mac.scheduler.main.after(milliseconds: 51) { after = f.tessel.status.rail == 1 }
            s.settle(); f.focus(b)
            s.expect("the destruction grace window remains open at 49 ms", before)
            s.expect("the external selection is followed by 51 ms", after)
        })
    }

    @Test("#17 E16: external focus reveals off-screen and hidden-rail windows, and follows workspaces")
    func externalFocus() {
        requireScenario(Scenario.run("external rail/workspace selection") { s in
            let f = RailFixture(s, widths: Array(repeating: 0.45, count: 4)), ids = f.ids
            f.press("move down", focus: ids[0]); f.order([ids[0]], rail: 2)
            f.select(ids[2]); s.expect("external focus selects the hidden rail", f.tessel.status.rail == 1)
            let remembered = f.frames(Array(ids.dropFirst()))
            f.select(ids[0]); s.expect("external focus returns to rail 2", f.tessel.status.rail == 2)
            f.press("focus up", focus: ids[2]); f.unchanged(Array(ids.dropFirst()), remembered)
            f.press("focus right", focus: ids[3]); f.press("focus down", focus: ids[0])
            f.press("send 3", focus: ids[0]); f.press("workspace 1", focus: ids[3])
            f.select(ids[0]); s.expect("external focus follows its original workspace", f.tessel.status.active == 3)
        })
    }

    enum ActivationStep: String, CaseIterable { case activate, read, deliver, down }

    @Test("#17 E7; #17 E16: an activation queued before an elevator command cannot undo its newer rail selection")
    func staleActivation() {
        let enumeration = SimulatedMac()
        let orders = enumeration.orders(of: ActivationStep.allCases, requiring: [
            .init(.activate, before: .read), .init(.read, before: .deliver), .init(.activate, before: .down),
        ])
        enumeration.shutdown()
        for order in orders {
            requireScenario(Scenario.run("queued activation versus elevator", writes: order.writes) { s in
                let f = RailFixture(s, widths: [0.25, 0.08, 0.08, 0.08]), a = f.ids[0]
                let destination = f.mac.launch(), b = destination.open(WindowSpec())
                s.settle(); f.press("move down", focus: b); f.press("focus up", focus: a)
                let third = f.mac.launch(), c = third.open(WindowSpec())
                s.settle(); f.press("send 3", focus: c); f.press("workspace 1", focus: a)
                for step in order.steps {
                    s.step(step.rawValue) {
                        switch step {
                        case .activate: third.select(c); f.app.select(a)
                        case .read:
                            let result = f.mac.pause(after: .read(f.app))
                            if case .paused = result {} else { s.expect("captured source activation: \(result)", false) }
                        case .deliver:
                            let result = f.mac.deliver(f.app)
                            if case .paused = result {} else { s.expect("delivered source activation: \(result)", false) }
                        case .down: f.tessel.press("focus down")
                        }
                    }
                }
                s.settle(); f.focus(b)
                s.expect("the newer elevator intent owns rail 2", f.tessel.status.active == 1 && f.tessel.status.rail == 2)
                s.expect("the entire source rail stays hidden", f.ids.allSatisfy { !f.mac.isVisible($0) })
                third.select(c); s.settle(); f.focus(c)
                s.expect("a subsequent external activation still works", f.tessel.status.active == 3)
            })
        }
    }

    @Test("#17 E22: a hung app cannot block healthy scrolling, elevator travel or cached publication", arguments: [false, true])
    func hungApp(beforeObserved: Bool) {
        requireScenario(Scenario.run("hung app beforeObserved=\(beforeObserved)") { s in
            let f = RailFixture(s, widths: [0.45, 0.45, 0.45]), ids = f.ids
            let other = f.mac.launch(), h = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 400, height: 400)))
            if beforeObserved {
                other.hang(); f.app.select(ids[0])
                let held = f.mac.pause(after: .call("AccessibilityPort.copy AXWindows \(other.alias) pid=\(other.pid)"))
                if case .paused = held {} else { s.expect("the initial hung read remains outstanding: \(held)", false) }
                f.tessel.press("focus right"); f.tessel.press("focus right")
                let independent = f.mac.scheduler.run()
                if case .paused = independent {} else { s.expect("healthy traversal finishes while the hung lane is held: \(independent)", false) }
                f.focus(ids[2])
                s.settle()
            } else {
                s.settle(); f.focus(h)
                f.press("focus right", focus: ids[1]); f.press("focus right", focus: ids[2])
                f.press("move down", focus: ids[2]); other.hang()
                f.tessel.press("focus up")
                let held = f.mac.pause(after: .call("AccessibilityPort.copy AXHidden \(other.alias) pid=\(other.pid)"))
                if case .paused = held {} else { s.expect("the hung rail write remains outstanding: \(held)", false) }
                s.step("traverse the hung neighbor and continue to a healthy window") { f.tessel.press("focus left"); f.tessel.press("focus left") }
                let independent = f.mac.scheduler.run()
                if case .paused = independent {} else { s.expect("healthy focus completes without the hung lane: \(independent)", false) }
                f.focus(ids[0])
                s.expect("cached publication needs no hung AX reply", f.tessel.status.enabled && f.tessel.windows.contains { $0.id == h })
                s.settle()
                f.press("focus down", focus: ids[2])
            }
            s.expect("cached workspace state remains readable", f.tessel.status.enabled && f.tessel.status.layout == "rails")
            s.expect("healthy window rows remain published", Set(ids).isSubset(of: Set(f.tessel.windows.map(\.id))))
        })
    }

    @Test("#17 E22: burst input retains the latest focus and finishes every pending position", arguments: [false, true])
    func burst(layout: Bool) {
        requireScenario(Scenario.run("burst layout=\(layout)") { s in
            let fraction = 0.3
            let f = RailFixture(s, widths: Array(repeating: fraction, count: 3))
            let other = f.mac.launch(), b = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: floor(f.area.width * fraction), height: 400)))
            s.settle()
            let ids = [f.ids[0], b, f.ids[1], f.ids[2]], c = ids[2], d = ids[3]
            f.order(ids); f.select(layout ? c : ids[0])
            other.busy(forMilliseconds: 300)
            s.step("two commands while app-B is busy") {
                f.tessel.press("focus right")
                f.tessel.press(layout ? "focus left" : "focus right")
            }
            s.settle(); f.focus(c)
            let width = f.frame(c).width, step = width + 10
            let offset = layout ? 3 * step - (f.area.width - 56 - width) : 0
            for (index, id) in ids.enumerated() {
                var x = f.area.minX + Double(index) * step - offset
                if index == 0 && layout && x + width < 56 { x += 4 * step }
                f.near(f.frame(id).minX, x, "pending position for window \(id) completes")
                f.near(f.frame(id).width, width, "burst preserves width")
                s.expect("worked burst keeps window \(id) on screen", f.mac.isVisible(id))
            }
            s.expect("the last right/left command is still selected", f.mac.focusedWindow == c && f.mac.focusedWindow != d)
        })
    }

    @Test("#17 E22: rail write retries use 100/200/400/800 ms virtual delays and stop until another render")
    func retryDelays() {
        requireScenario(Scenario.run("bounded rail write retries", writes: .readsFirst) { s in
            let f = RailFixture(s, widths: [0.3, 0.3, 0.3])
            let other = f.mac.launch(), b = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 301, height: 400)))
            s.settle()
            let ids = [f.ids[0], b, f.ids[1], f.ids[2]], c = ids[2], d = ids[3]
            f.select(c)
            let before = f.frame(b), start = f.mac.scheduler.trace.count
            other.hang()
            f.tessel.press("focus right"); f.tessel.press("focus left")
            var publishedDuringTimeout = false
            f.mac.scheduler.main.after(milliseconds: 10) {
                publishedDuringTimeout = f.tessel.status.enabled && f.tessel.windows.contains { $0.id == b }
            }
            s.settle(); f.focus(c)
            let trace = Array(f.mac.scheduler.trace.dropFirst(start)), lane = "tessel.ax.\(other.pid)"
            let delays = trace.filter { $0.contains("\(lane) SchedulingPort.after +") }.compactMap { line -> Int? in
                guard let plus = line.lastIndex(of: "+") else { return nil }
                return Int(line[line.index(after: plus)...].dropLast(2))
            }
            s.expect("rail retries back off exactly four times, actual \(delays)", delays == [100, 200, 400, 800])
            let attempts = trace.filter { $0.contains("\(lane) AccessibilityPort.copy AXHidden \(other.alias) ") }.compactMap { line in
                Int(line.dropFirst().prefix { $0.isNumber })
            }
            let intervals = zip(attempts.dropFirst(), attempts).map(-)
            s.expect("each retry waits its delay after the 50 ms AX timeout, actual \(intervals)", intervals == [150, 250, 450, 850])
            s.expect("the main lane publishes while AX is outstanding", publishedDuringTimeout)
            f.unchanged([b], [before])
            other.resume(); s.settle(); f.unchanged([b], [before])
            f.press("focus right", focus: d)
            let expected = f.area.maxX - 56 - f.frame(d).width - 2 * (f.frame(d).width + 10)
            f.near(f.frame(b).minX, expected, "a subsequent render retries the stale pending position")
        })
    }

    @Test("#17 E22: a newer workspace render cancels an outstanding rail write retry")
    func supersededRetry() {
        requireScenario(Scenario.run("cancel superseded rail retry", writes: .readsFirst) { s in
            let f = RailFixture(s, widths: [0.3, 0.3, 0.3])
            let other = f.mac.launch(), b = other.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: 301, height: 400)))
            s.settle(); f.select(f.ids[1]); other.hang()
            let start = f.mac.scheduler.trace.count
            f.tessel.press("focus right")
            let result = f.mac.pause(after: .call("SchedulingPort.after +100ms"))
            if case .paused = result {} else { s.expect("first rail retry is pending: \(result)", false) }
            f.tessel.press("workspace 2"); s.settle()
            let attempts = f.mac.scheduler.trace.dropFirst(start).filter { $0.contains("tessel.ax.\(other.pid) AccessibilityPort.copy AXHidden \(other.alias) ") }
            s.expect("the superseded retry never reaches AX again", attempts.count == 1)
            other.resume(); s.settle()
            s.expect("the newer empty workspace retains desktop focus", f.tessel.status.active == 2 && f.mac.frontmostApp == f.mac.finder.pid)
            s.expect("the superseded window stays hidden", !f.mac.isVisible(b) && f.mac.isInCloset(b))
        })
    }

    @Test("#17 E23: commands, defaults, overrides, aliases and invalid-line recovery retain effective bindings")
    func configuration() {
        requireScenario(Scenario.run("rail key configuration") { s in
            let f = RailFixture(s), ids = f.ids
            let keys = f.tessel.status.keys
            for (key, direction) in [("h", "left"), ("j", "down"), ("k", "up"), ("l", "right")] {
                s.expect("default alt-\(key) focuses \(direction)", keys["alt-" + key] == "focus " + direction)
                s.expect("default alt-shift-\(key) moves \(direction)", keys["alt-shift-" + key] == "move " + direction)
            }
            for number in 1...10 {
                let digit = number == 10 ? 0 : number
                s.expect("workspace \(number) keeps its numeric key", keys["alt-\(digit)"] == "workspace \(number)")
                s.expect("send \(number) keeps its numeric key", keys["alt-shift-\(digit)"] == "send \(number)")
            }
            s.expect("rail aliases have no default binding", !keys.values.contains("focus next") && !keys.values.contains("focus previous"))
            f.tessel.changeConfig("[experiments]\nrails = true\n[keys]\nalt-a = 'focus next'\nalt-b = 'focus previous'\nalt-c = 'move down'\nalt-l = 'focus left'\n")
            s.settle()
            let effective = f.tessel.status.keys
            s.expect("overrides merge with unchanged numeric defaults", effective["alt-l"] == "focus left" && effective["alt-1"] == "workspace 1")
            s.expect("aliases and new commands are accepted", effective["alt-a"] == "focus next" && effective["alt-b"] == "focus previous" && effective["alt-c"] == "move down")
            f.press("focus left", focus: ids[2]); f.press("focus next", focus: ids[0])
            f.press("focus next", focus: ids[1]); f.press("focus previous", focus: ids[0]); f.press("move down", focus: ids[0])
            f.tessel.changeConfig("[experiments]\nrails = true\n[keys]\nalt-a = 'move sideways'\n")
            s.settle()
            s.expect("invalid commands report their line", f.tessel.configuration.error?.line == 4)
            let message = f.tessel.configuration.error?.message ?? ""
            s.expect("error lists every directional command", message.contains("focus next|previous|left|right|up|down") && message.contains("move left|right|up|down"))
            s.expect("invalid edits keep all effective bindings", f.tessel.status.keys == effective)
            f.press("focus up", focus: ids[2])
            f.tessel.changeConfig("[experiments]\nworkspaces = true\n[keys]\nalt-a = 'move right'\n")
            s.settle()
            s.expect("rails-off keeps workspace focus defaults and still validates directional overrides", f.tessel.status.keys["alt-j"] == "focus next" && f.tessel.status.keys["alt-k"] == "focus previous" && f.tessel.configuration.error == nil)
        })
    }
}

import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselInstantReplacement {
    @Test("#33 E18: a departing window stays visible while its replacement's unpublished placement is elsewhere", arguments: WriteOrder.allCases)
    func departingWindowStaysVisibleUntilReplacementPlacementIsPublished(_ writes: WriteOrder) {
        let result = Scenario.run("reverse before a fractional replacement placement publishes", writes: writes) { s in
            let f = CarouselFixture(s, duration: 0, minimumFractions: [1: 849.5 / 1708], appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.apps[1].resize(b, to: CGSize(width: 849.5, height: f.area.height)); s.settle()
            f.select(a)
            let before = f.snapshot(), sharedPoint = CGPoint(x: 1000, y: 100)
            s.expect("the replacement has an accepted half-point size mismatch", f.frame(b).width == f.width(0.5) + 0.5)
            s.expect("the replacement initially covers the shared point", f.mac.isVisible(b) && f.frame(b).contains(sharedPoint))
            f.press("focus right")
            f.tessel.press("focus right")
            // The real window has moved, but its new position has not reached
            // Policy. Reverse while that app's AX lane remains held.
            let held = f.mac.pause(after: .call("AccessibilityPort.copy AXPosition window \(b) \(f.apps[1].alias)"))
            if case .paused = held {} else { s.expect("the replacement's position read is held: \(held)", false) }
            s.expect("the unpublished placement moved the replacement to the left edge", f.frame(b).minX == f.area.minX && before[b]!.minX != f.area.minX)
            f.tessel.press("focus left")
            f.tessel.press("focus left")
            let pending = f.mac.scheduler.run()
            if case .paused = pending {} else { s.expect("the replacement's lane remains held: \(pending)", false) }
            s.expect("the replacement is still away from the shared point", f.frame(b).minX == f.area.minX && !f.frame(b).contains(sharedPoint))
            s.expect("the departing window stays visible while its replacement is elsewhere", f.mac.isVisible(c))
            s.expect("shared tile coverage never exposes desktop", f.ids.contains { f.mac.isVisible($0) && f.frame($0).contains(sharedPoint) })
            s.settle()
            f.focus(a)
            f.near(f.frame(b).minX, before[b]!.minX, "the replacement eventually returns")
            s.expect("the replacement covers the shared point after the departure hides", f.mac.isVisible(b) && f.frame(b).contains(sharedPoint) && !f.mac.isVisible(c))
        }
        requireCarousel(result)
    }

    @Test("#33 E18: a transient focus-only timeout finishes the visibility handoff without replaying geometry")
    func focusTimeoutRetriesTheVisibilityHandoff() {
        requireCarousel(Scenario.run("focus timeout after hidden geometry lands") { s in
            let f = CarouselFixture(s, duration: 0), a = f.ids[0], c = f.ids[2]
            f.select(c); f.press("alt-shift-j"); f.press("alt-k"); f.select(a)
            f.mac.clearMotionHistory()
            f.tessel.press("focus down")
            let held = f.mac.pause(after: .call("AccessibilityPort.set AXFrontmost=true \(f.app.alias) pid=\(f.app.pid)"))
            if case .paused = held {} else { s.expect("the focus-only activation is about to run: \(held)", false) }
            s.expect("the destination is already visible before focus", f.mac.isVisible(c))
            f.app.busy(forMilliseconds: 1); s.settle()
            f.focus(c)
            s.expect("the outgoing rail retires after focus recovers", f.ids.filter { $0 != c }.allSatisfy { !f.mac.isVisible($0) })
            for attribute in [AXAttribute.size, .position] {
                s.expect("focus recovery does not replay geometry", f.mac.geometryWrites.filter { $0.window == c && $0.attribute == attribute }.count <= 1)
            }
        })
    }

    @Test("#33 E18: a hung earlier neighbor cannot delay an independent responsive placement", arguments: WriteOrder.allCases)
    func hungNeighborDoesNotDelayIndependentPlacement(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("independent placement beside a hung neighbor", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.5], duration: 0)
            let responsive = f.mac.launch()
            let id = responsive.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: f.width(0.5), height: f.area.height), positionAcceptance: .screenEdges))
            s.settle()
            f.app.hang(); f.mac.clearMotionHistory()
            f.tessel.changeConfig("[animation]\nduration = 0\n[gaps]\nouter = 20\n")
            s.after(milliseconds: 200, "responsive placement must land before the hung neighbor's retries") {
                f.near(f.frame(id).minY, f.area.minY + 10, "responsive tile has the new top gap promptly")
                f.near(f.frame(id).height, f.area.height - 20, "responsive tile has its final height promptly")
                s.expect("the hung tile has not accepted geometry", f.mac.geometryWrites.allSatisfy { $0.window != f.ids[0] })
            }
            s.settle()
            s.expect("responsive placement is not replayed by unrelated retries", f.mac.geometryWrites.filter { $0.window == id && $0.attribute == .size }.count == 1)
        })
    }

    @Test("#33 E18: prepare once while hidden and preserve pointwise old-or-final ownership",
          arguments: ["workspace", "rail", "width", "width-right", "width-shrink", "stop", "stop-mixed", "stop-left", "open", "close", "send", "layer-show", "layer-hide", "gaps"], WriteOrder.allCases)
    func instantOperationsHaveAnOrderedHandoff(_ operation: String, _ writes: WriteOrder) {
        for replies in HandoffReplies.allCases {
            requireCarousel(Scenario.run("instant \(operation) handoff \(replies)", writes: writes) { s in
                let presets = operation == "stop-mixed" ? [0.5, 739.0 / 1718.0, 0.5] : [0.5, 0.5, 0.5]
                let f = CarouselFixture(s, presets: presets, duration: 0, appCount: replies == .singleApp ? 1 : 2)
                f.tessel.changeConfig("[experiments]\nlayer = true\n[animation]\nduration = 0\n"); s.settle()
                let t = f.tessel, a = f.ids[0], b = f.ids[1], c = f.ids[2]
                var ids = Set(f.ids)
                switch operation {
                case "workspace", "send":
                    f.select(c); f.press("send 2"); f.press("workspace 1")
                case "rail": f.select(c); f.press("move down"); f.press("focus up")
                case "layer-show", "layer-hide":
                    _ = f.app.open(WindowSpec(subrole: "AXDialog")); s.settle()
                    if operation == "layer-show" { f.press("toggle layer") }
                case "width-shrink":
                    f.select(a); f.press("cycle width"); f.press("cycle width")
                case "stop-left": f.select(c); f.select(b)
                default: break
                }
                if operation == "width" { f.select(a) }
                if operation == "width-right" || operation == "stop" || operation == "stop-mixed" { f.select(b) }
                ids.formUnion(t.windows.map(\.id))
                var startCGOrder = f.mac.visibleOrder
                var before = Dictionary(uniqueKeysWithValues: ids.filter { f.mac.isVisible($0) }.map { ($0, f.frame($0)) })
                var owners = Dictionary(uniqueKeysWithValues: f.apps.flatMap { app in app.windows.map { ($0, app.pid) } })
                if replies == .delayedFirst { f.apps[0].delayAXReplies(milliseconds: 7) }
                if replies == .delayedSecond { f.apps[1].delayAXReplies(milliseconds: 17) }
                f.mac.clearMotionHistory(); f.mac.beginPresentationTrace()
                let traceStart = f.mac.scheduler.trace.count
                switch operation {
                case "workspace": t.press("workspace 2")
                case "rail": t.press("focus down")
                case "width", "width-right", "width-shrink": t.press("cycle width")
                case "stop", "stop-mixed": t.press("focus right")
                case "stop-left": t.press("focus left")
                case "open":
                    let opened = f.app.open(WindowSpec(frame: CGRect(x: 80, y: 80, width: 600, height: 400), positionAcceptance: .screenEdges))
                    ids.insert(opened); before[opened] = f.frame(opened); startCGOrder = f.mac.visibleOrder
                    owners[opened] = f.app.pid
                case "close":
                    f.app.close(a, selecting: c)
                    // The app has destroyed this window before policy can react.
                    before[a] = nil
                case "send": t.press("send 2")
                case "layer-show", "layer-hide": t.press("toggle layer")
                case "gaps": t.changeConfig("[animation]\nduration = 0\n[gaps]\nouter = 20\n")
                default: break
                }
                s.settle()
                let final = Dictionary(uniqueKeysWithValues: ids.filter { f.mac.isVisible($0) }.map { ($0, f.frame($0)) })
                let incoming = Set(final.keys).subtracting(before.keys).intersection(t.windows.map(\.id)).subtracting(operation == "open" ? [ids.max()!] : [])
                let departing = Set(before.keys).subtracting(final.keys).intersection(t.windows.map(\.id))
                let states = f.mac.presentationStates
                if operation == "gaps", replies == .delayedFirst || replies == .delayedSecond {
                    let firstApp = f.mac.geometryWrites.last { $0.window == a }?.traceIndex
                    let secondApp = f.mac.geometryWrites.last { $0.window == b }?.traceIndex
                    s.expect("both apps complete geometry in the delayed-reply scene", firstApp != nil && secondApp != nil)
                    if let firstApp, let secondApp {
                        s.expect("the responsive app overtakes the delayed app's replies", replies == .delayedFirst ? secondApp < firstApp : firstApp < secondApp)
                    }
                }
                for id in ids {
                    for attribute in [AXAttribute.size, .position] {
                        s.expect("\(operation): window \(id) receives at most one \(attribute.rawValue)", f.mac.geometryWrites.filter { $0.window == id && $0.attribute == attribute }.count <= 1)
                    }
                }
                for id in incoming {
                    let showing = states.first { $0.operation == "show" && $0.frames[id] != nil }
                    s.expect("\(operation): returning window \(id) is final when first shown", showing?.frames[id] == final[id])
                    s.expect("\(operation): all returning geometry writes are hidden", f.mac.geometryWrites.filter { $0.window == id }.allSatisfy(\.hidden))
                }
                // AX clamps size at the current origin. Each app serializes its
                // own bursts; independent apps can have bursts in flight together.
                let grouped = Dictionary(grouping: f.mac.geometryWrites, by: \.window)
                let bursts = Dictionary(uniqueKeysWithValues: grouped.keys.sorted().compactMap { id -> (UInt32, Range<Int>)? in
                    let writes = grouped[id]!
                    guard let first = writes.first, let last = writes.last, first.traceIndex < last.traceIndex else { return nil }
                    let burst = first.traceIndex..<last.traceIndex
                    s.expect("\(operation): geometry bursts never interleave another window's writes within one app",
                             f.mac.geometryWrites.filter { burst.contains($0.traceIndex) }.allSatisfy { $0.window == id || owners[$0.window] != owners[id] })
                    s.expect("\(operation): geometry bursts never interleave closet operations",
                             !states.contains { burst.contains($0.traceIndex) && ($0.operation == "show" || $0.operation == "hide") })
                    return (id, burst)
                })
                let oracle = InstantHandoffOracle(area: f.area, ids: ids, before: before, startOrder: startCGOrder, final: final, endOrder: f.mac.visibleOrder)
                var previousVisible = Set(before.keys)
                for state in states {
                    let inProgress = Set(bursts.filter { $0.value.contains(state.traceIndex) }.keys)
                    let visible = Set(state.frames.keys)
                    let showing = state.operation == "show" ? visible.subtracting(previousVisible) : []
                    for failure in oracle.violations(frames: state.frames, order: state.order, inProgress: inProgress, showing: showing) {
                        s.expect("\(operation): \(state.operation): \(failure)", false)
                    }
                    previousVisible = visible
                    if state.operation == "hide" {
                        for id in departing where state.frames[id] == nil {
                            guard let old = before[id] else { continue }
                            for (replacement, target) in final where replacement != id && old.intersects(target) {
                                s.expect("\(operation): every replacement is in place before departure \(id) hides", state.frames[replacement] == target)
                            }
                        }
                    }
                }
                s.expect("focus is requested only after its destination is visible", f.mac.focusRequests.allSatisfy { !$0.hidden })
                s.expect("instant operations make no stage", f.mac.stageEvents.isEmpty)
                s.expect("the operation exercised real ports", f.mac.scheduler.trace.count > traceStart)
            })
        }
    }
}

private enum HandoffReplies: CaseIterable { case singleApp, twoApps, delayedFirst, delayedSecond }

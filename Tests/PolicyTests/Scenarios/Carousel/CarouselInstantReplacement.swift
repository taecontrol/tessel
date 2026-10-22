import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselInstantReplacement {
    @Test("#33 E18: prepare once while hidden and preserve pointwise old-or-final ownership",
          arguments: ["workspace", "rail", "width", "width-right", "width-shrink", "stop", "stop-mixed", "stop-left", "open", "close", "send", "layer-show", "layer-hide"], WriteOrder.allCases)
    func instantOperationsHaveAnOrderedHandoff(_ operation: String, _ writes: WriteOrder) {
        requireCarousel(Scenario.run("instant \(operation) handoff", writes: writes) { s in
            let presets = operation == "stop-mixed" ? [0.5, 739.0 / 1718.0, 0.5] : [0.5, 0.5, 0.5]
            let f = CarouselFixture(s, presets: presets, duration: 0)
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
            case "close":
                f.app.close(a, selecting: c)
                // The app has destroyed this window before policy can react.
                before[a] = nil
            case "send": t.press("send 2")
            case "layer-show", "layer-hide": t.press("toggle layer")
            default: break
            }
            s.settle()
            let final = Dictionary(uniqueKeysWithValues: ids.filter { f.mac.isVisible($0) }.map { ($0, f.frame($0)) })
            let incoming = Set(final.keys).subtracting(before.keys).intersection(t.windows.map(\.id)).subtracting(operation == "open" ? [ids.max()!] : [])
            let departing = Set(before.keys).subtracting(final.keys).intersection(t.windows.map(\.id))
            let states = f.mac.presentationStates
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
            // AX clamps size at the current origin. A growing right tile must
            // move before resizing (849@869 -> 1135@582.7), so ownership is
            // checked once that window's uninterrupted geometry burst lands.
            let bursts = Dictionary(grouping: f.mac.geometryWrites, by: \.window).values.compactMap { writes -> Range<Int>? in
                guard let first = writes.first, let last = writes.last, first.traceIndex < last.traceIndex else { return nil }
                let burst = first.traceIndex..<last.traceIndex
                s.expect("\(operation): geometry bursts never interleave another window's writes",
                         f.mac.geometryWrites.filter { burst.contains($0.traceIndex) }.allSatisfy { $0.window == first.window })
                s.expect("\(operation): geometry bursts never interleave closet operations",
                         !states.contains { burst.contains($0.traceIndex) && ($0.operation == "show" || $0.operation == "hide") })
                return burst
            }
            // Sample every cell formed by all old, final and intermediate edges.
            // Within a cell both ownership and coverage are constant.
            let allFrames = Array(before.values) + Array(final.values) + states.flatMap { $0.frames.values }
            let xs = Set(([f.area.minX, f.area.maxX] + allFrames.flatMap { [$0.minX, $0.maxX] }).map { min(f.area.maxX, max(f.area.minX, $0)) }).sorted()
            let ys = Set(([f.area.minY, f.area.maxY] + allFrames.flatMap { [$0.minY, $0.maxY] }).map { min(f.area.maxY, max(f.area.minY, $0)) }).sorted()
            func owner(_ frames: [UInt32: CGRect], _ order: [UInt32], at point: CGPoint) -> UInt32? {
                order.first { id in ids.contains(id) && frames[id]?.contains(point) == true }
            }
            let startOrder = startCGOrder
            let endOrder = f.mac.visibleOrder
            for state in states {
                if !bursts.contains(where: { $0.contains(state.traceIndex) }) {
                    for (x0, x1) in zip(xs, xs.dropFirst()) where x1 > x0 {
                        for (y0, y1) in zip(ys, ys.dropFirst()) where y1 > y0 {
                            let point = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                            let old = owner(before, startOrder, at: point), new = owner(final, endOrder, at: point)
                            let current = owner(state.frames, state.order, at: point)
                            s.expect("\(operation): \(state.operation) at \(point) shows \(String(describing: current)), expected old \(String(describing: old)) or final \(String(describing: new))",
                                     current == nil || current == old || current == new)
                            if old != nil && new != nil { s.expect("\(operation): shared tile coverage never exposes desktop at \(point)", current != nil) }
                        }
                    }
                }
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

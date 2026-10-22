import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselInstantReplacement {
    @Test("#33 E18: prepare once while hidden and hand off visibility with consecutive closet calls",
          arguments: ["workspace", "rail", "width", "stop", "open", "close", "send", "layer"], WriteOrder.allCases)
    func instantOperationsHaveAnOrderedHandoff(_ operation: String, _ writes: WriteOrder) {
        requireCarousel(Scenario.run("instant \(operation) handoff", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5, 0.5], duration: 0)
            f.tessel.changeConfig("[experiments]\nlayer = true\n[animation]\nduration = 0\n"); s.settle()
            let t = f.tessel, a = f.ids[0], b = f.ids[1], c = f.ids[2]
            var ids = Set(f.ids)
            switch operation {
            case "workspace", "send":
                f.select(c); f.press("send 2"); f.press("workspace 1")
            case "rail": f.select(c); f.press("move down"); f.press("focus up")
            case "layer":
                _ = f.app.open(WindowSpec(subrole: "AXDialog")); s.settle()
                f.press("toggle layer")
            default: break
            }
            if operation == "width" { f.select(a) }
            if operation == "stop" { f.select(b) }
            let before = Dictionary(uniqueKeysWithValues: ids.filter { f.mac.isVisible($0) }.map { ($0, f.frame($0)) })
            f.mac.clearMotionHistory()
            let traceStart = f.mac.scheduler.trace.count
            switch operation {
            case "workspace": t.press("workspace 2")
            case "rail": t.press("focus down")
            case "width": t.press("cycle width")
            case "stop": t.press("focus right")
            case "open": ids.insert(f.app.open(WindowSpec(frame: CGRect(x: 80, y: 80, width: 600, height: 400), positionAcceptance: .screenEdges)))
            case "close": f.app.close(a, selecting: c)
            case "send": t.press("send 2")
            case "layer": t.press("toggle layer")
            default: break
            }
            s.settle()
            let final = Dictionary(uniqueKeysWithValues: ids.filter { f.mac.isVisible($0) }.map { ($0, f.frame($0)) })
            let incoming = Set(final.keys).subtracting(before.keys), departing = Set(before.keys).subtracting(final.keys)
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
            for (index, state) in states.enumerated() {
                let visible = state.order.filter { ids.contains($0) }
                for (i, upper) in visible.enumerated() {
                    for lower in visible.dropFirst(i + 1) {
                        guard let top = state.frames[upper], let bottom = state.frames[lower] else { continue }
                        let overlap = top.intersection(bottom).intersection(f.area)
                        guard !overlap.isNull && overlap.width > 1 && overlap.height > 1 else { continue }
                        // Amended E18: overlap exists only in the show/hide handoff,
                        // with the replacement above the departing tile at its final frame.
                        let next = states.dropFirst(index + 1).first
                        let inHandoff = state.operation == "show" && next?.operation == "hide"
                        s.expect("\(operation): overlap is only replacement-over-departure in the handoff", inHandoff && departing.contains(lower) && final[upper] == top)
                    }
                }
            }
            if !incoming.isEmpty && !departing.isEmpty {
                let show = states.first { $0.operation == "show" && incoming.isSubset(of: Set($0.frames.keys)) }
                let hide = states.first { $0.operation == "hide" && departing.isDisjoint(with: Set($0.frames.keys)) }
                s.expect("\(operation): show precedes hide", show != nil && hide != nil && show!.traceIndex < hide!.traceIndex)
                if let show, let hide, show.traceIndex < hide.traceIndex {
                    let between = f.mac.scheduler.trace[show.traceIndex..<hide.traceIndex].filter { $0.contains("Port.") }
                    s.expect("\(operation): no port call separates show and hide: \(between)", between.count == 1 && between[0].contains("ClosetPort.hide"))
                }
            }
            s.expect("instant operations make no stage", f.mac.stageEvents.isEmpty)
            s.expect("the operation exercised real ports", f.mac.scheduler.trace.count > traceStart)
        })
    }
}

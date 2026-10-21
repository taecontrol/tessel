import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerStage {
    @Test("#19 E10: pinned stand-ins keep their at-rest CG order above background tiles and below the frontmost tile", arguments: WriteOrder.allCases, [0, 1])
    func pinnedStandInsMatchRestingOrder(_ writes: WriteOrder, _ owner: Int) {
        requireLayer(Scenario.run("honest pinned stage / \(writes) / app \(owner)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 250)
            f.press("pin layer")
            if owner == 1 { f.press("focus right"); f.press("focus right") }
            f.mac.clearMotionHistory()
            f.press("cycle width")
            let rest = f.mac.windowOrder.onScreenOrder()
            let orders = f.mac.stageEvents.compactMap { event -> [UInt32]? in
                if case .order(let ids) = event.kind { return ids }; return nil
            }
            s.expect("a width change stages the pinned windows", !orders.isEmpty && f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            for order in orders {
                s.expect("every visible pinned float has an ordered stand-in", f.floats.allSatisfy { order.contains($0) })
                for float in f.floats {
                    for tile in f.tiles where order.contains(tile) && rest.contains(tile) {
                        s.expect("stand-ins \(order) agree with at-rest CG \(rest) for float \(float) and tile \(tile)",
                                 (order.firstIndex(of: float)! < order.firstIndex(of: tile)!) == (rest.firstIndex(of: float)! < rest.firstIndex(of: tile)!))
                    }
                }
            }
        })
    }

    @Test("#19 E10: rail motion captures each visible pinned float once, excludes it from background, and captures no hidden float", arguments: [false, true])
    func pinnedFloatCaptureRequests(pinned: Bool) {
        requireLayer(Scenario.run("rail motion with pinned=\(pinned)") { s in
            let f = LayerFixture(s, floatSpecs: (0..<3).map { _ in WindowSpec(subrole: "AXFloatingWindow") }, duration: 250)
            f.press("toggle layer"); f.press("focus left"); f.press("send 3"); f.press("workspace 1")
            let remote = f.floats[2], local = Array(f.floats.prefix(2))
            if pinned { f.press("pin layer") }
            f.select(f.tiles[1])
            let before = f.frames(local)
            f.mac.clearMotionHistory()
            f.press("focus right"); f.focus(f.tiles[2])
            let expected = Set(f.tiles + (pinned ? local : []))
            s.expect("motion captures exactly its tiles and visible pinned floats: expected \(expected.sorted()), requested \(f.captures)", Set(f.captures) == expected && f.captures.count == expected.count)
            s.expect("the hidden workspace float is never captured", !f.captures.contains(remote))
            let exclusions = f.captureRequests.compactMap(\.backgroundExcluding)
            s.expect("motion requests exactly one background capture", exclusions.count == 1)
            // A tile first sized after returning from the closet can refresh
            // its stand-in. Pinned floats retain their frame and capture.
            let floatCaptures = f.captureRequests.flatMap { $0.windows.sorted() }.filter { f.floats.contains($0) }
            s.expect("each visible pinned float requests exactly one capture, including refreshes", Set(floatCaptures) == Set(pinned ? local : []) && floatCaptures.count == (pinned ? local.count : 0))
            let orders = f.mac.stageEvents.compactMap { event -> [UInt32]? in
                if case .order(let ids) = event.kind { return ids }; return nil
            }
            s.expect("stage orders \(orders) never elevate pinned floats over their frontmost app's focused tile \(f.tiles[2])", !orders.isEmpty && orders.allSatisfy { order in
                local.filter { order.contains($0) }.allSatisfy { order.firstIndex(of: f.tiles[2])! < order.firstIndex(of: $0)! }
            })
            if pinned {
                s.expect("pinned floats are excluded from every background request", !exclusions.isEmpty && exclusions.allSatisfy { Set(local).isSubset(of: $0) })
                let frames = f.mac.stageEvents.flatMap { event -> [[UInt32: CGRect]] in
                    switch event.kind { case .show(let rects), .move(let rects, _): [rects]; default: [] }
                }
                s.expect("each staged frame retains both pinned floats at their fixed rects", !frames.isEmpty && frames.allSatisfy { rects in local.allSatisfy { rects[$0] == before[$0] } })
            }
            f.unchanged(before)
        })
    }
}

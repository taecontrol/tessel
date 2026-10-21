import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerStage {
    @Test("#19 E10: a failed background raise keeps the pinned stand-in below every tile that still covers it", arguments: WriteOrder.allCases)
    func failedRaiseKeepsObservedOrder(_ writes: WriteOrder) {
        requireLayer(Scenario.run("honest failed raise / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 250)
            f.press("pin layer"); f.press("focus right"); f.press("focus right")
            f.apps[2].hang()
            f.press("focus left")
            f.mac.clearMotionHistory()
            f.press("cycle width")
            let order = f.mac.windowOrder.onScreenOrder(), float = f.floats[2], tile = f.tiles[2]
            s.expect("the failed raise really leaves a float covered by a background tile", order.firstIndex(of: tile)! < order.firstIndex(of: float)!)
            let orders = f.mac.stageEvents.compactMap { event -> [UInt32]? in
                if case .order(let ids) = event.kind { return ids }; return nil
            }
            s.expect("the stage draws the failed raise honestly throughout motion", !orders.isEmpty && orders.allSatisfy {
                $0.firstIndex(of: tile)! < $0.firstIndex(of: float)!
            })
        })
    }

    @Test("#19 E10: the final stage order observes delayed native activation instead of replaying raises", arguments: WriteOrder.allCases)
    func delayedActivationOrderBeforeReveal(_ writes: WriteOrder) {
        requireLayer(Scenario.run("honest delayed CG activation / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 250)
            f.press("pin layer")
            f.press("move down"); f.press("focus up"); f.press("move down"); f.press("focus up")
            s.expect("the source rail focuses the other app's tile", f.mac.focusedWindow == f.tiles[2])
            // ax-frontmost-activation explicitly allows CG order to lag AX.
            // 200 virtual ms places that completion between stage placement
            // and settling; it is an input, never a real-system deadline.
            f.apps[0].delayNextActivationOrder(milliseconds: 200)
            f.mac.clearMotionHistory()
            f.press("focus down")
            let rest = f.mac.windowOrder.onScreenOrder()
            let orders = f.mac.stageEvents.compactMap { event -> [UInt32]? in
                if case .order(let ids) = event.kind { return ids }; return nil
            }
            s.expect("the rail change reaches reveal", f.mac.stageEvents.contains { if case .revealed = $0.kind { true } else { false } })
            s.expect("both frontmost tiles are visible at rest", f.tiles.prefix(2).allSatisfy { rest.contains($0) })
            if let last = orders.last {
                for float in f.floats {
                    for tile in f.tiles where rest.contains(tile) {
                        s.expect("final stand-ins \(last) match delayed CG \(rest) for float \(float), tile \(tile)",
                                 (last.firstIndex(of: float)! < last.firstIndex(of: tile)!) == (rest.firstIndex(of: float)! < rest.firstIndex(of: tile)!))
                    }
                }
            } else { s.expect("the stage supplies an order", false) }
        })
    }

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
            let rest = f.mac.windowOrder.onScreenOrder()
            s.expect("stage orders \(orders) preserve at-rest CG \(rest) for the pinned floats and focused tile", (!pinned || !orders.isEmpty) && orders.allSatisfy { order in
                local.filter { order.contains($0) }.allSatisfy { float in
                    guard let tileIndex = order.firstIndex(of: f.tiles[2]), let floatIndex = order.firstIndex(of: float),
                          let nativeTile = rest.firstIndex(of: f.tiles[2]), let nativeFloat = rest.firstIndex(of: float) else { return false }
                    return (tileIndex < floatIndex) == (nativeTile < nativeFloat)
                }
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

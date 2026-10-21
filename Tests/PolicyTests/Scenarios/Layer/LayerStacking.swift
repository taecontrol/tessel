import CoreGraphics
import Simulator
import Testing
@testable import Policy

/// Three regular apps, with normal-level floats so native panel levels cannot
/// accidentally satisfy the ordering oracle. All three tiles fit on one rail.
@MainActor struct LayerStackingFixture {
    let s: Scenario
    let apps: [SimulatedApp]
    let tiles: [UInt32]
    let floats: [UInt32]
    let tessel: Tessel
    var mac: SimulatedMac { s.mac }

    init(_ s: Scenario, duration: Int = 0) {
        self.s = s
        let a = s.mac.launch(), b = s.mac.launch(), c = s.mac.launch()
        apps = [a, b, c]
        let width = (s.mac.screens.primaryScreen!.visibleFrame.width - 40) / 3
        let tile = WindowSpec(frame: CGRect(x: 40, y: 60, width: width, height: 400))
        tiles = [a.open(tile), a.open(tile), b.open(tile)]
        floats = [a, b, c].map { $0.open(WindowSpec(subrole: "AXDialog"), background: true) }
        a.select(tiles[0])
        tessel = s.startTessel(text: LayerFixture.config + "[animation]\nduration = \(duration)\n")
        s.settle()
        s.expect("all three tiles are CG-visible", Set(tiles).isSubset(of: Set(mac.windowOrder.onScreenOrder())))
    }

    func press(_ command: String) { s.step(command) { tessel.press(command) }; s.settle() }

    func stacking(focus: UInt32, owner: Int32) {
        // cg-on-screen-order is front to back. CLI visible only means membership.
        let order = mac.windowOrder.onScreenOrder()
        s.expect("frontmost app stays \(owner)", mac.frontmostApp == owner)
        s.expect("keyboard focus stays \(focus)", mac.focusedWindow == focus)
        let owners = Dictionary(uniqueKeysWithValues: tessel.windows.map { ($0.id, $0.bundleId) })
        let front = tessel.windows.first { $0.id == focus }?.bundleId
        let backgroundTiles = tiles.filter { order.contains($0) && owners[$0] != front }
        s.expect("the oracle includes a visible background tile", !backgroundTiles.isEmpty)
        for float in floats where order.contains(float) && owners[float] != front {
            for tile in backgroundTiles {
                s.expect("CG order \(order): background float \(float) is above background tile \(tile)",
                         order.firstIndex(of: float)! < order.firstIndex(of: tile)!)
            }
        }
    }

    func raises(since start: Int) -> [UInt32] {
        mac.scheduler.trace.dropFirst(start).compactMap { line in
            guard line.contains("AccessibilityPort.perform AXRaise window "), !line.contains(" reply ") else { return nil }
            return UInt32(line.components(separatedBy: "window ").last!.split(separator: " ")[0])
        }
    }
}

@Suite @MainActor struct LayerStacking {
    @Test("#19 E9: spec gap — pinned tile placements raise background floats in CG order without changing focus", arguments: WriteOrder.allCases, [0, 250])
    func pinnedCGStacking(_ writes: WriteOrder, _ duration: Int) {
        requireLayer(Scenario.run("pinned CG stacking / \(writes) / \(duration)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: duration)
            var start = f.mac.scheduler.trace.count
            f.press("pin layer")
            f.stacking(focus: f.tiles[0], owner: f.apps[0].pid)
            s.expect("pinning never raises the frontmost app's float", !f.raises(since: start).contains(f.floats[0]))
            // Make B the MRU and C the next most recent float, then return to A.
            f.press("toggle layer"); f.press("focus left"); f.press("focus left"); f.press("toggle layer")
            f.stacking(focus: f.tiles[0], owner: f.apps[0].pid)
            let floatOrder = f.mac.windowOrder.onScreenOrder().filter { f.floats.dropFirst().contains($0) }
            s.expect("the MRU background float is on top", floatOrder == [f.floats[1], f.floats[2]])
            for (command, index, owner) in [("focus right", 1, 0), ("focus right", 2, 1), ("cycle width", 2, 1)] {
                start = f.mac.scheduler.trace.count
                f.mac.clearMotionHistory()
                f.press(command)
                f.stacking(focus: f.tiles[index], owner: f.apps[owner].pid)
                s.expect("tile placement never raises a frontmost-app float", !f.raises(since: start).contains(f.floats[owner]))
                s.expect("extra raises never select a float", f.mac.focusEffects.allSatisfy { effect in
                    effect.window.map { !f.floats.contains($0) } ?? true
                })
            }
        })
    }

    @Test("#19 E7: spec gap — shown layer transitions raise background floats without selecting a same-app sibling", arguments: WriteOrder.allCases)
    func shownCGStacking(_ writes: WriteOrder) {
        requireLayer(Scenario.run("shown CG stacking / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("toggle layer")
            f.stacking(focus: f.floats[0], owner: f.apps[0].pid)
            f.press("focus right")
            f.stacking(focus: f.floats[1], owner: f.apps[1].pid)
            f.press("focus right")
            f.stacking(focus: f.floats[2], owner: f.apps[2].pid)
            f.press("pin layer"); f.press("pin layer")
            f.stacking(focus: f.floats[2], owner: f.apps[2].pid)
        })
    }
}

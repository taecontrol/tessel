import Simulator
import Testing
@testable import Policy

/// A fixed-seed generator, so every run replays the same command sequences.
private struct SplitMix {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

extension LayerStackingFixture {
    /// The resting rule, from CG order, the native frontmost app and published
    /// membership only: while the active layer is pinned or shown, every
    /// visible float of a background app is above every background tile.
    /// Returns whether the rule had a background float and tile to compare.
    @discardableResult func restingOrder(_ label: String) -> Bool {
        guard let state = tessel.status.layer?.state, state == "pinned" || state == "shown",
              let front = mac.frontmostApp else { return false }
        var owners: [UInt32: Int32] = [:]
        for (index, id) in tiles.enumerated() { owners[id] = apps[index < 2 ? 0 : 1].pid }
        for (index, id) in floats.enumerated() { owners[id] = apps[index].pid }
        let order = mac.windowOrder.onScreenOrder()
        let rows = tessel.windows.filter { $0.workspace == tessel.status.active && order.contains($0.id) && owners[$0.id] != front }
        let backgroundFloats = rows.filter { $0.state == .floats && $0.rail == nil }.map(\.id)
        let backgroundTiles = rows.filter { $0.state == .tiled }.map(\.id)
        for float in backgroundFloats {
            for tile in backgroundTiles {
                s.expect("\(label): CG order \(order) puts background float \(float) above background tile \(tile) (front \(front))",
                         order.firstIndex(of: float)! < order.firstIndex(of: tile)!)
            }
        }
        return !backgroundFloats.isEmpty && !backgroundTiles.isEmpty
    }

    func lastActivationRequest(since start: Int) -> Int32? {
        mac.scheduler.trace.dropFirst(start).last { $0.contains("AccessibilityPort.set AXFrontmost=true ") && !$0.contains(" reply ") }
            .flatMap { line in line.components(separatedBy: "pid=").last.flatMap { Int32($0.split(separator: " ")[0]) } }
    }
}

@Suite @MainActor struct LayerStackingSweep {
    /// Weighted toward the rail and layer of workspace 1, where the rule has
    /// windows to compare; every listed command still occurs.
    static let commands = ["toggle layer", "toggle layer", "pin layer", "pin layer", "focus right", "focus right",
                           "focus right", "focus left", "focus left", "focus left", "cycle width", "toggle float",
                           "workspace 2", "workspace 1", "workspace 1", "send 2"]
    static let retargets = ["cycle width", "focus right", "focus left", "pin layer"]

    @Test("#19 E9: spec gap — command sequences under deferred activation and stage retargets rest in the background-float order",
          arguments: WriteOrder.allCases)
    func restingOrderSweep(_ writes: WriteOrder) {
        var compared = 0
        for seed in UInt64(1)...40 {
            requireLayer(Scenario.run("resting order sweep \(seed) / \(writes)", writes: writes) { s in
                var random = SplitMix(state: seed)
                // Instant placements, a warm stage, or a cold one: six windows,
                // the backdrop and one frame take 232 virtual ms before show.
                let stage = random.next(3)
                let f = LayerStackingFixture(s, duration: stage == 0 ? 0 : 250)
                if stage == 2 { f.mac.setStageCaptureCost(milliseconds: 24) }
                for step in 0..<10 {
                    // deferred-ax-activation: completion on a main/raise write,
                    // asynchronously, or on another activation request.
                    for app in f.apps where random.next(3) == 0 {
                        app.deferNextActivation(completion: DeferredActivationCompletion.allCases[random.next(3)])
                    }
                    let command = Self.commands[random.next(Self.commands.count)]
                    if random.next(2) == 0 {
                        let retarget = Self.retargets[random.next(Self.retargets.count)]
                        s.after(milliseconds: 10 + 20 * random.next(6), "\(step): retarget with \(retarget)") { f.tessel.press(retarget) }
                    }
                    let start = f.mac.scheduler.trace.count
                    s.step("\(step): \(command)") { f.tessel.press(command) }
                    s.settle()
                    // A request superseded before its retry can leave the app
                    // waiting for another activation. The user then selects
                    // that app's key window, as with Cmd-Tab.
                    if let requested = f.lastActivationRequest(since: start), requested != f.mac.frontmostApp,
                       let app = f.apps.first(where: { $0.pid == requested }), let key = app.focusedWindow {
                        s.step("\(step): select stuck app \(app.pid)'s key window \(key)") { app.select(key) }
                        s.settle()
                    }
                    if f.restingOrder("seed \(seed) step \(step) after \(command)") { compared += 1 }
                }
            })
        }
        #expect(compared >= 100, "the sweep compares background floats with background tiles at rest")
    }
}

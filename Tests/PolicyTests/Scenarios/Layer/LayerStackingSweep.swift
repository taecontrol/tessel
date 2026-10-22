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

    /// A float raise is passive when its app's lane wrote no AXMain on that
    /// float since the lane's previous focus write or frontmost check (the
    /// check a background raise makes first). It must not move keyboard
    /// focus into the float's app, as completing an activation left pending
    /// there would (deferred-ax-activation). The simulator keeps one completion
    /// trigger per app, so deferring an app again with another trigger also
    /// changes the trigger of a request still pending there; floats of such
    /// apps in `excluded` are not checked. Returns how many raises it checked.
    func passiveRaisesKeepFocus(since start: Int, effects first: Int, excluding excluded: Set<Int32>, _ label: String) -> Int {
        var owners: [UInt32: Int32] = [:]
        for (index, id) in tiles.enumerated() { owners[id] = apps[index < 2 ? 0 : 1].pid }
        for (index, id) in floats.enumerated() { owners[id] = apps[index].pid }
        let trace = mac.scheduler.trace
        // Lines read "[time ms] lane call", in time order.
        func time(_ index: Int) -> Int { Int(trace[index].dropFirst().prefix { $0 != "m" }) ?? 0 }
        var checked = 0, searched = start
        for effect in mac.focusEffects.dropFirst(first) {
            guard let id = effect.raisedWindow, floats.contains(id), let owner = owners[id], !excluded.contains(owner) else { continue }
            var low = searched, high = trace.count
            while low < high { let mid = (low + high) / 2; if time(mid) < effect.at { low = mid + 1 } else { high = mid } }
            let call = "AccessibilityPort.perform AXRaise window \(id) "
            guard let raise = trace[low...].firstIndex(where: { $0.contains(call) }) else {
                s.expect("\(label): the raise of float \(id) at \(effect.at) ms is in the trace", false); continue
            }
            searched = raise + 1
            let lane = " " + trace[raise].split(separator: " ")[1] + " "
            let main = "AccessibilityPort.set AXMain=true window \(id) "
            let previous = trace[start..<raise].last { line in
                line.contains(lane) && !line.contains(" reply ") && (line.contains("AccessibilityPort.set AXMain=true ")
                    || line.contains("AccessibilityPort.perform AXRaise ") || line.contains(" AXFrontmost"))
            }
            guard previous?.contains(main) != true else { continue }
            s.expect("\(label): passive raise of float \(id) at \(effect.at) ms keeps keyboard focus out of its app (focus \(effect.window.map(String.init) ?? "none"))",
                     effect.window.flatMap { owners[$0] } != owner)
            checked += 1
        }
        return checked
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
        var compared = 0, passive = 0
        for seed in UInt64(1)...40 {
            requireLayer(Scenario.run("resting order sweep \(seed) / \(writes)", writes: writes) { s in
                var random = SplitMix(state: seed)
                // Instant placements, a warm stage, or a cold one: six windows,
                // the backdrop and one frame take 232 virtual ms before show.
                let stage = random.next(3)
                let f = LayerStackingFixture(s, duration: stage == 0 ? 0 : 250)
                if stage == 2 { f.mac.setStageCaptureCost(milliseconds: 24) }
                var completions: [Int32: DeferredActivationCompletion] = [:], retriggered = Set<Int32>()
                for step in 0..<10 {
                    // deferred-ax-activation: completion on a main/raise write,
                    // asynchronously, or on another activation request.
                    for app in f.apps where random.next(3) == 0 {
                        let completion = DeferredActivationCompletion.allCases[random.next(3)]
                        if completions.updateValue(completion, forKey: app.pid).map({ $0 != completion }) == true { retriggered.insert(app.pid) }
                        app.deferNextActivation(completion: completion)
                    }
                    let command = Self.commands[random.next(Self.commands.count)]
                    if random.next(2) == 0 {
                        let retarget = Self.retargets[random.next(Self.retargets.count)]
                        s.after(milliseconds: 10 + 20 * random.next(6), "\(step): retarget with \(retarget)") { f.tessel.press(retarget) }
                    }
                    let start = f.mac.scheduler.trace.count, effects = f.mac.focusEffects.count
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
                    passive += f.passiveRaisesKeepFocus(since: start, effects: effects, excluding: retriggered, "seed \(seed) step \(step) after \(command)")
                }
            })
        }
        #expect(compared >= 100, "the sweep compares background floats with background tiles at rest")
        #expect(passive >= 100, "the sweep checks keyboard focus after passive float raises: \(passive)")
    }

    @Test("#19 E26: superseded activations, native detours and geometry-only relayouts never let a passive raise move focus",
          arguments: WriteOrder.allCases)
    func passiveRaiseSweep(_ writes: WriteOrder) {
        var passive = 0
        // These seeds include schedules where a superseded request, a native
        // detour to its app and a geometry-only relayout occur in that order.
        for seed in UInt64(51)...56 {
            requireLayer(Scenario.run("passive raise sweep \(seed) / \(writes)", writes: writes) { s in
                var random = SplitMix(state: seed)
                let f = LayerStackingFixture(s)
                f.press("pin layer")
                // One completion trigger per app, so a later deferral never
                // changes the trigger of a request already pending. A passive
                // raise can only complete one waiting for a focus write.
                let triggers: [DeferredActivationCompletion] = [.focusWrite, .focusWrite, .nativeEvent, .nextRequest]
                let completions = f.apps.map { _ in triggers[random.next(triggers.count)] }
                // The rail is A's two tiles, then B's. At rest tessel's
                // selection is the natively focused tile.
                var gap = 0
                func owner(_ index: Int) -> SimulatedApp { f.apps[index < 2 ? 0 : 1] }
                func direction(from index: Int) -> Int { index == 0 ? 1 : index == 2 ? -1 : random.next(2) == 0 ? -1 : 1 }
                func command(_ direction: Int) -> String { direction > 0 ? "focus right" : "focus left" }
                for step in 0..<10 {
                    let start = f.mac.scheduler.trace.count, effects = f.mac.focusEffects.count
                    let selected = f.mac.focusedWindow.flatMap { f.tiles.firstIndex(of: $0) }
                    switch random.next(4) {
                    case 0:
                        guard let selected else { continue }
                        f.press(command(direction(from: selected)))
                    case 1:
                        guard let selected else { continue }
                        let move = direction(from: selected), target = selected + move, app = target < 2 ? 0 : 1
                        // Only across apps: no contract shows whether an app
                        // that is already frontmost can keep a request pending.
                        guard f.apps[app].pid != f.mac.frontmostApp else { continue }
                        f.apps[app].deferNextActivation(completion: completions[app])
                        s.step("\(step): supersede \(f.apps[app].alias)'s activation") {
                            f.supersedeActivation(of: f.apps[app], requesting: command(move), with: command(direction(from: target)))
                        }
                        s.settle()
                    case 2:
                        let index = random.next(3)
                        s.step("\(step): the user selects tile \(f.tiles[index])") { owner(index).select(f.tiles[index]) }
                        s.settle()
                    default:
                        gap = 20 - gap
                        s.step("\(step): reload the config with outer gap \(gap)") {
                            f.tessel.changeConfig(LayerFixture.config + "[animation]\nduration = 0\n[gaps]\nouter = \(gap)\n")
                        }
                        s.settle()
                    }
                    passive += f.passiveRaisesKeepFocus(since: start, effects: effects, excluding: [], "seed \(seed) step \(step)")
                }
            })
        }
        #expect(passive >= 50, "the sweep checks keyboard focus after passive float raises: \(passive)")
    }
}

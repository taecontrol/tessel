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
        tessel = s.startTessel()
        s.settle()
        tessel.changeConfig(LayerFixture.config + "[animation]\nduration = \(duration)\n")
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

    /// Holds `app`'s accepted AXFrontmost call before its effect and reply,
    /// then presses `newer`, so the post-call token check rejects the focus
    /// writes that would have followed it.
    func supersedeActivation(of app: SimulatedApp, requesting command: String, with newer: String) {
        tessel.press(command)
        let held = mac.pause(after: .call("AccessibilityPort.set AXFrontmost=true \(app.alias) pid=\(app.pid)"))
        if case .paused = held {} else { s.expect("\(app.alias)'s activation call is held: \(held)", false) }
        tessel.press(newer)
    }

    func raises(since start: Int) -> [UInt32] {
        mac.scheduler.trace.dropFirst(start).compactMap { line in
            guard line.contains("AccessibilityPort.perform AXRaise window "), !line.contains(" reply ") else { return nil }
            return UInt32(line.components(separatedBy: "window ").last!.split(separator: " ")[0])
        }
    }
}

@Suite @MainActor struct LayerStacking {
    @Test("#19 E9: spec gap — a frontmost change that needs no placement still restacks the pinned layer", arguments: WriteOrder.allCases)
    func unmanagedFrontmostRestacks(_ writes: WriteOrder) {
        requireLayer(Scenario.run("pinned layer under an unmanaged frontmost app / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            // A launcher whose only window is above the normal level: tessel
            // ignores it, so activating it selects nothing to place.
            let launcher = f.mac.launch()
            let panel = launcher.open(WindowSpec(subrole: "AXSystemDialog", cgLayer: 8), background: true)
            s.settle()
            f.press("pin layer"); f.press("focus right")
            f.stacking(focus: f.tiles[1], owner: f.apps[0].pid)
            var start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            s.step("select the launcher") { launcher.select(panel) }
            s.settle()
            s.expect("the launcher owns keyboard focus", f.mac.frontmostApp == launcher.pid && f.mac.focusedWindow == panel)
            s.expect("every managed app is in the background, so every float is compared", f.restingOrder("launcher frontmost"))
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("one pass raises every visible float, least recently used first: \(raised)",
                     raised == [f.floats[2], f.floats[1], f.floats[0]])
            s.expect("background raises keep the launcher's keyboard focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == panel })
            start = f.mac.scheduler.trace.count
            s.step("select A's tile again") { f.apps[0].select(f.tiles[1]) }
            s.settle()
            f.stacking(focus: f.tiles[1], owner: f.apps[0].pid)
            let returned = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("returning to A raises only the other apps' floats: \(returned)", returned == [f.floats[2], f.floats[1]])
        })
    }

    @Test("#19 E9: spec gap — pinning before a deferred layer entry activates still restacks once B is frontmost", arguments: WriteOrder.allCases)
    func pinDuringDeferredEntry(_ writes: WriteOrder) {
        requireLayer(Scenario.run("pin during deferred layer entry / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            // B is the MRU float, while A's second tile covers A's float.
            f.press("toggle layer"); f.press("focus right"); f.press("toggle layer"); f.press("focus right")
            f.apps[1].deferNextActivation(completion: .nextRequest)
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.tessel.press("toggle layer")
            let held = f.mac.pause(after: .read(f.apps[1]))
            if case .paused = held {} else { s.expect("B's unconfirmed focus read is held: \(held)", false) }
            s.expect("A still owns keyboard focus when pinning", f.mac.frontmostApp == f.apps[0].pid)
            // Pinning keeps the same logical selection without requesting
            // focus again, and cancels the presenter's activation retry.
            f.tessel.press("pin layer")
            s.settle()
            s.expect("no background float is raised while A is still frontmost: \(f.raises(since: start))",
                     f.raises(since: start).allSatisfy { ![f.floats[0], f.floats[2]].contains($0) })
            f.apps[1].select(f.floats[1])
            s.settle()
            f.stacking(focus: f.floats[1], owner: f.apps[1].pid)
            let raised = f.raises(since: start).filter { f.floats.contains($0) && $0 != f.floats[1] }
            s.expect("one pass after B's activation raises C, then A: \(raised)", raised == [f.floats[2], f.floats[0]])
            s.expect("each background raise preserves B's float focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { [f.floats[0], f.floats[2]].contains($0) } ?? false
            }.allSatisfy { $0.window == f.floats[1] })
        })
    }

    @Test("#19 E26: a background float raise never completes a superseded activation", arguments: WriteOrder.allCases)
    func supersededActivationKeepsFocus(_ writes: WriteOrder) {
        requireLayer(Scenario.run("superseded activation under a pinned layer / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("pin layer")
            f.press("focus right") // A's second tile
            f.apps[1].deferNextActivation(completion: .focusWrite)
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.supersedeActivation(of: f.apps[1], requesting: "focus right", with: "focus left")
            s.settle()
            let trace = Array(f.mac.scheduler.trace.dropFirst(start))
            s.expect("the superseded presentation never selects B's tile", !trace.contains {
                $0.contains("AXMain=true window \(f.tiles[2]) ") || $0.contains("AXRaise window \(f.tiles[2]) ")
            })
            s.expect("A retains native keyboard focus", f.mac.frontmostApp == f.apps[0].pid && f.mac.focusedWindow == f.tiles[1])
            s.expect("every background-float raise preserves A's keyboard focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == f.tiles[1] })
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("the pass raises C's float and holds back B's: \(raised)", raised == [f.floats[2]])
        })
    }

    @Test("#19 E26: an activation superseded before its focus writes stays unresolved across a native detour", arguments: WriteOrder.allCases)
    func supersededActivationSurvivesNativeDetour(_ writes: WriteOrder) {
        requireLayer(Scenario.run("superseded activation across a native detour / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("pin layer")
            f.press("focus right")
            f.apps[1].deferNextActivation(completion: .focusWrite)
            f.supersedeActivation(of: f.apps[1], requesting: "focus right", with: "focus left")
            s.settle()
            // Nothing contracted says another activation consumes the pending
            // one, so B being frontmost for a while does not resolve it.
            s.step("the user selects B's tile") { f.apps[1].select(f.tiles[2]) }
            s.settle()
            f.mac.clearMotionHistory()
            s.step("the user selects A's tile again") { f.apps[0].select(f.tiles[1]) }
            s.settle()
            s.expect("A retains native keyboard focus", f.mac.frontmostApp == f.apps[0].pid && f.mac.focusedWindow == f.tiles[1])
            s.expect("every background-float raise preserves A's keyboard focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == f.tiles[1] })
        })
    }

    @Test("#19 E26: a presentation that requests no activation leaves an older superseded one unresolved", arguments: WriteOrder.allCases)
    func supersededActivationSurvivesGeometryRelayout(_ writes: WriteOrder) {
        requireLayer(Scenario.run("superseded activation across a geometry-only relayout / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("pin layer")
            f.press("focus right")
            f.apps[1].deferNextActivation(completion: .focusWrite)
            f.supersedeActivation(of: f.apps[1], requesting: "focus right", with: "focus left")
            s.settle()
            s.step("the user selects B's tile") { f.apps[1].select(f.tiles[2]) }
            s.settle()
            // While B is frontmost, a new outer gap moves B's tile without
            // requesting focus. Its read finds B frontmost, but it issued no
            // request, so that read says nothing about the pending one.
            let start = f.mac.scheduler.trace.count
            s.step("reload the config with another outer gap") {
                f.tessel.changeConfig(LayerFixture.config + "[animation]\nduration = 0\n[gaps]\nouter = 20\n")
            }
            s.settle()
            let trace = f.mac.scheduler.trace.dropFirst(start).filter { $0.contains("AccessibilityPort.") && !$0.contains(" reply ") }
            s.expect("the relayout moves B's tile", trace.contains {
                ($0.contains("AXPosition") || $0.contains("AXSize")) && $0.contains("window \(f.tiles[2]) ")
            })
            s.expect("the relayout neither activates nor selects anything in B", !trace.contains {
                $0.contains("AXFrontmost=true \(f.apps[1].alias) ") || ($0.contains(f.apps[1].alias) && ($0.contains("AXMain=true") || $0.contains("AXRaise")))
            })
            f.mac.clearMotionHistory()
            s.step("the user selects A's tile again") { f.apps[0].select(f.tiles[1]) }
            s.settle()
            s.expect("A retains native keyboard focus", f.mac.frontmostApp == f.apps[0].pid && f.mac.focusedWindow == f.tiles[1])
            s.expect("every background-float raise preserves A's keyboard focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == f.tiles[1] })
        })
    }

    @Test("#19 E9: an abandoned activation request that finds its app already frontmost holds nothing back", arguments: WriteOrder.allCases)
    func abandonedRequestToFrontmostApp(_ writes: WriteOrder) {
        requireLayer(Scenario.run("abandoned request to the frontmost app / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("pin layer")
            let start = f.mac.scheduler.trace.count
            // A's second tile, then B's before A's focus writes are issued.
            f.supersedeActivation(of: f.apps[0], requesting: "focus right", with: "focus right")
            s.settle()
            f.stacking(focus: f.tiles[2], owner: f.apps[1].pid)
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("the pass raises C's float, then A's: \(raised)", raised == [f.floats[2], f.floats[0]])
        })
    }

    @Test("#19 E9: floats held back by a superseded activation restack once tessel activates their app again", arguments: WriteOrder.allCases)
    func deferredFloatsRestackAfterActivation(_ writes: WriteOrder) {
        requireLayer(Scenario.run("restack after a superseded activation resolves / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("pin layer")
            f.press("focus right")
            f.apps[1].deferNextActivation(completion: .focusWrite)
            f.supersedeActivation(of: f.apps[1], requesting: "focus right", with: "focus left")
            s.settle()
            // tessel's next activation request and focus writes for B
            // complete any earlier pending one (deferred-ax-activation).
            f.press("focus right")
            f.stacking(focus: f.tiles[2], owner: f.apps[1].pid)
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.press("focus left")
            f.stacking(focus: f.tiles[1], owner: f.apps[0].pid)
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("returning to A raises C's float, then B's: \(raised)", raised == [f.floats[2], f.floats[1]])
            s.expect("those raises preserve A's keyboard focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == f.tiles[1] })
        })
    }

    @Test("#19 E9: a float held back for a pending activation restacks once its app is read frontmost", arguments: WriteOrder.allCases)
    func heldFloatRestacksAfterActivationRead(_ writes: WriteOrder) {
        requireLayer(Scenario.run("held float after a confirmed activation read / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.press("pin layer")
            f.press("focus right")
            // B's focus writes follow its request, which stays pending; the
            // newer selection then cancels the presenter's retry.
            f.apps[1].deferNextActivation(completion: .nextRequest)
            let selection = f.mac.scheduler.trace.count
            f.tessel.press("focus right")
            let raise = f.mac.pause(after: .call("AccessibilityPort.perform AXRaise window \(f.tiles[2]) \(f.apps[1].alias)"))
            if case .paused = raise {} else { s.expect("B's tile raise is held: \(raise)", false) }
            f.tessel.press("focus left")
            s.settle()
            let held = f.raises(since: selection).filter { f.floats.contains($0) }
            s.expect("the pass raises C's float and holds back B's: \(held)", held == [f.floats[2]])
            let start = f.mac.scheduler.trace.count
            s.step("the user selects B's tile") { f.apps[1].select(f.tiles[2]) }
            // B's publication carries the frontmost read that resolves it,
            // but only reaches tessel after A is frontmost again.
            let read = f.mac.pause(after: .read(f.apps[1]))
            if case .paused = read {} else { s.expect("B's frontmost read is held: \(read)", false) }
            s.step("the user selects A's tile again") { f.apps[0].select(f.tiles[1]) }
            s.settle()
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("B's resolution owes a pass that raises C's float, then B's: \(raised)", raised == [f.floats[2], f.floats[1]])
            f.stacking(focus: f.tiles[1], owner: f.apps[0].pid)
        })
    }

    @Test("#19 E9: a cold stage retarget retains restacking until the selected tile's native activation", arguments: WriteOrder.allCases)
    func retargetRetainsDeferredActivation(_ writes: WriteOrder) {
        requireLayer(Scenario.run("cold pinned retarget during activation / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 400)
            f.press("pin layer"); f.press("focus right")
            // The instant selection, the stage's early focus and its bounded
            // retry are all accepted before native activation finishes.
            for _ in 0..<3 { f.apps[1].deferNextActivation(completion: .nextRequest) }
            // Six windows plus the backdrop's three capture units and one
            // display frame show the stage after 232 virtual ms (ADR-0006).
            f.mac.setStageCaptureCost(milliseconds: 24)
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            f.tessel.press("focus right")
            s.after(milliseconds: 10, "retarget the pending selection onto the stage") { f.tessel.press("cycle width") }
            s.after(milliseconds: 500, "native activation finishes on the selected tile") {
                s.expect("the background pass still waits for native focus", f.raises(since: start).allSatisfy { !f.floats.contains($0) })
                f.apps[1].select(f.tiles[2])
            }
            s.settle()
            f.stacking(focus: f.tiles[2], owner: f.apps[1].pid)
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("one confirmed pass raises A and C, never the frontmost B float: \(raised)",
                     raised == [f.floats[2], f.floats[0]])
            s.expect("each background raise preserves the selected tile's native focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == f.tiles[2] })
            s.expect("the final stage clears", f.mac.stageEvents.last?.kind == .clear)
        })
    }

    @Test("#19 E9: spec gap — pinned floats restack once after deferred tile activation", arguments: WriteOrder.allCases, DeferredActivationCompletion.allCases)
    func pinnedDeferredActivation(_ writes: WriteOrder, _ completion: DeferredActivationCompletion) {
        for duration in [0, 250] {
            requireLayer(Scenario.run("deferred pinned activation / \(writes) / \(completion) / \(duration)", writes: writes) { s in
                let f = LayerStackingFixture(s, duration: duration)
                f.press("pin layer"); f.press("focus right")
                f.apps[1].deferNextActivation(completion: completion)
                let start = f.mac.scheduler.trace.count
                f.mac.clearMotionHistory()
                f.press("focus right")
                f.stacking(focus: f.tiles[2], owner: f.apps[1].pid)
                let raised = f.raises(since: start).filter { f.floats.contains($0) }
                s.expect("one confirmed pass raises A and C, never the frontmost B float: \(raised)",
                         raised.count == 2 && Set(raised) == Set([f.floats[0], f.floats[2]]))
                s.expect("each background raise preserves the confirmed tile focus", f.mac.focusEffects.filter {
                    $0.raisedWindow.map { f.floats.contains($0) } ?? false
                }.allSatisfy { $0.window == f.tiles[2] })
            })
        }
    }

    @Test("#19 E7: spec gap — a shown layer restacks once after deferred float activation", arguments: WriteOrder.allCases, DeferredActivationCompletion.allCases)
    func shownDeferredActivation(_ writes: WriteOrder, _ completion: DeferredActivationCompletion) {
        requireLayer(Scenario.run("deferred shown activation / \(writes) / \(completion)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            // B is the MRU float, while A's second tile covers A's float.
            f.press("toggle layer"); f.press("focus right"); f.press("toggle layer"); f.press("focus right")
            f.apps[1].deferNextActivation(completion: completion)
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.press("toggle layer")
            f.stacking(focus: f.floats[1], owner: f.apps[1].pid)
            let raised = f.raises(since: start).filter { f.floats.contains($0) && $0 != f.floats[1] }
            s.expect("one confirmed pass raises both background floats: \(raised)",
                     raised.count == 2 && Set(raised) == Set([f.floats[0], f.floats[2]]))
            s.expect("each background raise preserves the confirmed float focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { [f.floats[0], f.floats[2]].contains($0) } ?? false
            }.allSatisfy { $0.window == f.floats[1] })
        })
    }

    @Test("#19 E9: spec gap — an interrupted stage retains restacking until its deferred activation arrives", arguments: WriteOrder.allCases)
    func interruptedDeferredActivation(_ writes: WriteOrder) {
        requireLayer(Scenario.run("interrupted deferred pinned activation / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 250)
            f.press("pin layer"); f.press("cycle width"); f.press("focus right")
            f.apps[1].deferNextActivation(completion: .nextRequest)
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.tessel.press("focus right")
            let held = f.mac.pause(after: .read(f.apps[1]))
            if case .paused = held {} else { s.expect("the unconfirmed focus publication is held: \(held)", false) }
            s.expect("A still owns keyboard focus before the interruption", f.mac.focusedWindow == f.tiles[1] && f.mac.frontmostApp == f.apps[0].pid)
            f.apps[0].drag(f.tiles[0], to: f.mac.frame(f.tiles[0])!.origin)
            // Cancellation stops the presenter's retry. A later native
            // selection of that same tile must still finish restacking.
            f.apps[1].select(f.tiles[2])
            s.settle()
            f.stacking(focus: f.tiles[2], owner: f.apps[1].pid)
            s.expect("the cancelled stage never draws", !f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("the replacement pass runs once against the confirmed frontmost app: \(raised)",
                     raised.count == 2 && Set(raised) == Set([f.floats[0], f.floats[2]]))
            s.expect("each background raise preserves the confirmed tile focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == f.tiles[2] })
        })
    }

    @Test("#19 E9: spec gap — interrupting the stage after tile focus still raises visible background floats", arguments: WriteOrder.allCases)
    func interruptedStageRestacksAfterTileFocus(_ writes: WriteOrder) {
        requireLayer(Scenario.run("interrupted pinned tile focus / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 250)
            f.press("pin layer"); f.press("cycle width"); f.press("focus right")
            f.mac.clearMotionHistory()
            f.tessel.press("focus right")
            let held = f.mac.pause(after: .read(f.apps[1]))
            if case .paused = held {} else { s.expect("the focused destination's publication is held: \(held)", false) }
            s.expect("the new app already owns keyboard focus", f.mac.focusedWindow == f.tiles[2] && f.mac.frontmostApp == f.apps[1].pid)
            s.expect("the stage has not drawn before the pointer press", !f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            // A pointer press interrupts without having to change focus. Use
            // the existing drag action at the same point: no geometry changes.
            f.apps[0].drag(f.tiles[0], to: f.mac.frame(f.tiles[0])!.origin)
            s.settle()
            s.expect("the cancelled stage never draws", !f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            f.stacking(focus: f.tiles[2], owner: f.apps[1].pid)
            s.expect("every extra float raise keeps the new tile's keyboard focus", f.mac.focusEffects.filter {
                $0.raisedWindow.map { f.floats.contains($0) } ?? false
            }.allSatisfy { $0.window == f.tiles[2] })
        })
    }

    @Test("#19 E27: a pinned cross-app tile focus under motion raises each visible background float once", arguments: WriteOrder.allCases)
    func animatedRaiseBudget(_ writes: WriteOrder) {
        requireLayer(Scenario.run("animated pinned raise budget / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 250)
            f.press("pin layer"); f.press("cycle width"); f.press("focus right")
            let start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            // The stage focuses B's tile early; native focus confirms during
            // the motion, before the real windows are placed under it.
            f.press("focus right")
            s.expect("the change runs on the stage", f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            f.stacking(focus: f.tiles[2], owner: f.apps[1].pid)
            let raised = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("one pass after placement raises C, then A: \(raised)", raised == [f.floats[2], f.floats[0]])
        })
    }

    @Test("#19 E27: entry raises at most N floats and a pinned tile placement raises each visible background float once", arguments: WriteOrder.allCases)
    func backgroundRaiseBudget(_ writes: WriteOrder) {
        requireLayer(Scenario.run("layer raise budget / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s)
            f.mac.clearMotionHistory()
            var start = f.mac.scheduler.trace.count
            f.press("toggle layer")
            let exits = f.mac.visibilityChanges.filter(\.showing).flatMap(\.windows)
            s.expect("entry makes N closet exits", exits.count == f.floats.count && Set(exits) == Set(f.floats))
            s.expect("entry raises at most N floats, including its focused float", f.raises(since: start).count <= f.floats.count)
            let entryWrites = LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start)))
            s.expect("entry makes no AX writes to tiles", entryWrites.allSatisfy { write in !f.tiles.contains { write.contains("window \($0) ") } })
            let background = Array(f.floats.dropFirst())
            s.expect("background floats receive AXRaise only, never AXMain or geometry writes", entryWrites.filter { write in
                background.contains { write.contains("window \($0) ") }
            }.allSatisfy { $0.contains("perform AXRaise") })
            s.expect("raising never activates a background app", entryWrites.allSatisfy { write in
                !write.contains("AXFrontmost") || !f.apps.dropFirst().contains { write.contains("pid=\($0.pid)") }
            })
            s.expect("entry captures nothing", f.mac.stageCaptureRequests.isEmpty)
            f.press("pin layer"); f.press("toggle layer")
            start = f.mac.scheduler.trace.count
            f.mac.clearMotionHistory()
            f.press("focus right")
            let raisedFloats = f.raises(since: start).filter { f.floats.contains($0) }
            s.expect("one raise per visible background-app float and none to a frontmost-app float", raisedFloats.count == 2 && Set(raisedFloats) == Set(f.floats.dropFirst()))
            f.stacking(focus: f.tiles[1], owner: f.apps[0].pid)
        })
    }

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
                s.expect("extra raises never change keyboard focus", f.mac.focusEffects.filter { effect in
                    effect.raisedWindow.map { f.floats.contains($0) } ?? false
                }.allSatisfy { $0.window == f.tiles[index] })
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

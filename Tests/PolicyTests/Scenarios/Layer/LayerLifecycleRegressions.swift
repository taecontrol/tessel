import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerLifecycleRegressions {
    @Test("unpinning after a native selection never closets keyboard focus before its catalog notification", arguments: WriteOrder.allCases)
    func unpinBeforeFocusPublication(_ order: WriteOrder) {
        requireLayer(Scenario.run("unpin with unpublished float focus \(order.rawValue)", writes: order) { s in
            let f = LayerFixture(s)
            f.enter(.pinnedRails)
            f.mac.clearMotionHistory()
            f.app.select(f.floats[0])
            f.tessel.press("pin layer")
            s.settle()
            s.expect("every hide transfers keyboard focus first", f.mac.visibilityChanges.allSatisfy { change in
                change.showing || (change.focusedWindow.map { !change.windows.contains($0) } ?? true)
            })
            if let focus = f.mac.focusedWindow {
                s.expect("the final native focus remains outside the closet", !f.mac.isInCloset(focus))
            }
        })
    }

    @Test("a native tab replacement completes the pending layer exit", arguments: WriteOrder.allCases)
    func tabReplacementDuringLayerExit(_ order: WriteOrder) {
        requireLayer(Scenario.run("layer exit to a replaced native tab \(order.rawValue)", writes: order) { s in
            let f = LayerFixture(s)
            let first = f.tiles[0], next = f.tiles[1]
            f.app.groupTabs([first, next], selected: first)
            s.settle()
            f.press("toggle layer")
            f.state("shown", focused: true)
            f.tessel.press("toggle layer")
            f.app.selectTab(next)
            s.settle()
            f.focus(next)
            f.state("hidden", focused: false)
            f.visible(f.floats, false)
        })
    }

    @Test("a failed focus handoff leaves an unpublished native float selection visible", arguments: WriteOrder.allCases)
    func failedFocusHandoffKeepsFloatVisible(_ order: WriteOrder) {
        requireLayer(Scenario.run("failed focus handoff with unpublished float focus \(order.rawValue)", writes: order) { s in
            let f = LayerFixture(s)
            f.enter(.pinnedRails)
            f.mac.clearMotionHistory()
            f.app.select(f.floats[0])
            f.app.hang()
            f.tessel.press("pin layer")
            s.settle()
            f.focus(f.floats[0])
            s.expect("a failed focus request never hides the native selection", f.mac.visibilityChanges.allSatisfy { change in
                change.showing || (change.focusedWindow.map { !change.windows.contains($0) } ?? true)
            })
            // A later native selection supplies the confirmation the failed
            // request could not provide; the ordinary event path finishes it.
            f.app.resume()
            f.app.select(f.tiles[0])
            s.settle()
            f.focus(f.tiles[0])
            f.state("hidden", focused: false)
            f.visible(f.floats, false)
        })
    }

    @Test("a focus handoff while parking a rail tile preserves the running stage")
    func handoffPreservesRailMotion() {
        requireLayer(Scenario.run("rail motion while a front-app tile enters the closet") { s in
            let f = LayerFixture(s, duration: 250)
            f.select(f.tiles[1])
            f.mac.clearMotionHistory()
            f.press("focus right")
            f.focus(f.tiles[2])
            s.expect("the outgoing tile is parked", f.mac.isInCloset(f.tiles[0]))
            let events = f.mac.stageEvents
            let settled = events.firstIndex { $0.kind == .settled }
            let cleared = events.firstIndex { $0.kind == .clear }
            s.expect("the stage survives until motion settles", settled != nil && cleared != nil && settled! < cleared!)
            s.expect("the completed stage reveals its placed windows", events.contains { $0.kind == .revealed })
        })
    }
}

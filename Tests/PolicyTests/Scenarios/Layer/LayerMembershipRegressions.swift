import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerMembershipRegressions {
    @Test("#19 E8: successive transfers append arrivals even when original tile order is reversed")
    func repeatedTransfersAppendEachArrival() {
        requireLayer(Scenario.run("two transfers in reverse original arrival order") { s in
            let f = LayerFixture(s)
            f.select(f.tiles[1]); f.press("toggle float")
            f.press("toggle layer"); f.select(f.tiles[0]); f.press("toggle float")
            f.press("focus right"); f.focus(f.floats[0])
        })
    }

    @Test("#19 E23: manual floating classification respects minimization and resumes on restore")
    func manualFloatCanBeMinimizedAndRestored() {
        requireLayer(Scenario.run("manual float minimization") { s in
            let f = LayerFixture(s), id = f.tiles[0]
            f.press("toggle float")
            f.app.minimize(id, selecting: f.tiles[1]); s.settle()
            s.expect("manual placement never overrides native minimization", f.row(id)?.state == .minimized)
            f.app.restore(id); s.settle()
            f.classification(id, "floats", "moved to the layer"); f.focus(id)
            f.state("shown", focused: true)
        })
    }

    @Test("#19 E16: restoring a minimized float from hidden enters the entire layer")
    func restoreFloatEntersLayer() {
        requireLayer(Scenario.run("restore float into hidden layer") { s in
            let f = LayerFixture(s), id = f.floats[0]
            f.press("toggle layer")
            f.app.minimize(id, selecting: f.tiles[0]); s.settle()
            f.press("toggle layer")
            f.state("hidden", focused: false)
            f.app.restore(id); s.settle()
            f.state("shown", focused: true); f.focus(id); f.visible(f.floats, true)
        })
    }
}

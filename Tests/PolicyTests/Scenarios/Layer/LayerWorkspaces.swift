import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerWorkspaces {
    @Test("#19 E17: each workspace retains its pin, entered state and remembered float without leaking visibility", arguments: LayerMode.allCases)
    func workspaceStateReturns(_ mode: LayerMode) {
        requireLayer(Scenario.run("workspace layer memory \(mode.rawValue)") { s in
            let f = LayerFixture(s)
            let selected = f.enter(mode), extra = mode == .single ? selected.map { [$0] } ?? [] : []
            let focus = f.mac.focusedWindow
            f.press("workspace 3"); f.state("hidden", focused: false); f.visible(f.floats + extra, false)
            let tile3 = f.open(WindowSpec())
            f.focus(tile3)
            let float3 = f.open()
            f.press("pin layer"); f.state("pinned", focused: true)
            f.press("workspace 1")
            s.expect("workspace one restores its exact focus", f.mac.focusedWindow == focus)
            f.state(mode == .pinnedLayer || mode == .pinnedRails ? "pinned" : mode.rawValue,
                    focused: mode != .hidden && mode != .pinnedRails)
            f.visible(f.floats, mode == .shown || mode == .pinnedRails || mode == .pinnedLayer)
            if !extra.isEmpty { f.visible(extra, true) }
            s.expect("workspace three never leaks its float into workspace one", !f.mac.isVisible(float3) && f.mac.isInCloset(float3))
            f.press("workspace 3"); f.state("pinned", focused: true); f.focus(float3)
            f.visible(f.floats + extra, false)
        })
    }

    @Test("#19 E18: sending from any focused layer state follows the float into the destination layer", arguments: [LayerMode.single, .shown, .pinnedLayer])
    func sendFollowsFloat(_ mode: LayerMode) {
        requireLayer(Scenario.run("send layer member from \(mode.rawValue)") { s in
            let f = LayerFixture(s)
            let selected = f.enter(mode) ?? f.floats[0]
            let before = f.frame(selected)
            f.key("alt-shift-3")
            s.expect("send follows workspace three", f.tessel.status.active == 3)
            s.expect("the float has destination membership without a rail", f.row(selected)?.workspace == 3 && f.row(selected)?.rail == nil)
            f.state("shown", focused: true); f.focus(selected); f.visible([selected], true)
            f.visible(f.floats.filter { $0 != selected }, false)
            s.expect("sending a float keeps its frame", f.frame(selected) == before)
            f.press("workspace 1")
            s.expect("the sent float remains in workspace three", f.row(selected)?.workspace == 3 && f.mac.isInCloset(selected))
        })
    }
}

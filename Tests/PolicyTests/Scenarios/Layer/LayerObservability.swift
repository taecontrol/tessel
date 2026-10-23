import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerObservability {
    @Test("#19 E25: status JSON reports layer state and focus, and windows JSON reports visibility and exact reasons")
    func publishedJSONContract() {
        requireLayer(Scenario.run("published layer and window JSON") { s in
            let f = LayerFixture(s)
            @MainActor func status(_ state: String, _ focused: Bool) {
                let reply = AppStatus(permission: "granted", config: f.tessel.configuration, version: "test", pid: 1, workspaces: f.tessel.status)
                let workspaces = encodedObject(reply)["workspaces"] as? [String: Any]
                let layer = workspaces?["layer"] as? [String: Any]
                s.expect("status --json workspaces.layer.state=\(state)", layer?["state"] as? String == state)
                s.expect("status --json workspaces.layer.focused=\(focused)", layer?["focused"] as? Bool == focused)
            }
            @MainActor func row(_ id: UInt32, state: String, reason: String, visible: Bool? = nil) {
                let json = f.row(id).map(encodedObject) ?? [:]
                s.expect("windows --json window \(id) state and reason", json["state"] as? String == state && json["reason"] as? String == reason)
                if let visible { s.expect("windows --json window \(id) visible=\(visible)", json["visible"] as? Bool == visible) }
            }
            status("hidden", false)
            for id in f.floats { row(id, state: "floats", reason: id == f.floats[0] ? "AXFloatingWindow" : "AXDialog", visible: false) }
            let unknown = f.open(WindowSpec(subrole: "AXUnknown", popupParent: f.tiles[0]), background: true)
            let high = f.open(WindowSpec(subrole: "AXSystemDialog", cgLayer: 21), background: true)
            row(unknown, state: "ignored", reason: "AXUnknown")
            row(high, state: "ignored", reason: "window level 21")
            for id in [unknown, high] {
                let json = f.row(id).map(encodedObject) ?? [:]
                s.expect("ignored JSON has explicit null membership", json["workspace"] is NSNull && json["rail"] is NSNull && json["slot"] is NSNull)
            }
            status("hidden", false)
            let single = f.open(); status("single", true)
            row(single, state: "floats", reason: "AXDialog", visible: true)
            f.press("toggle layer"); status("hidden", false)
            row(single, state: "floats", reason: "AXDialog", visible: false)
            f.press("toggle layer"); status("shown", true)
            f.press("toggle layer"); status("hidden", false)
            f.press("toggle float"); status("shown", true)
            row(f.tiles[0], state: "floats", reason: "moved to the layer", visible: true)
            f.press("toggle float"); status("hidden", false)
            row(f.tiles[0], state: "tiled", reason: "moved to a rail", visible: true)
        })
    }

    @Test("#19 E26: no transition hides keyboard focus or focuses an ignored or hidden float outside entry", arguments: LayerMode.allCases)
    func focusSafetyAcrossTransitions(_ mode: LayerMode) {
        requireLayer(Scenario.run("focus and closet invariants in \(mode.rawValue)") { s in
            let f = LayerFixture(s)
            var ignored: [UInt32] = []
            @MainActor func safe(_ label: String, entering: Bool, action: @MainActor () -> Void) {
                f.mac.clearMotionHistory()
                action(); s.settle()
                if let focus = f.mac.focusedWindow {
                    s.expect("\(label): keyboard focus is outside the closet", !f.mac.isInCloset(focus))
                }
                s.expect("\(label): native focus is transferred before every hide", f.mac.visibilityChanges.allSatisfy { change in
                    change.showing || (change.focusedWindow.map { !change.windows.contains($0) } ?? true)
                })
                s.expect("\(label): every tessel focus effect leaves keyboard focus outside the closet", f.mac.focusEffects.allSatisfy { !$0.hidden })
                s.expect("\(label): tessel never selects an ignored window", f.mac.focusRequests.allSatisfy { !ignored.contains($0.window) })
                // Entering may request a hidden destination. Actual keyboard
                // focus must still be outside the closet after every effect.
                if !entering {
                    s.expect("\(label): no focus request targets a hidden float", f.mac.focusRequests.allSatisfy { !$0.hidden || f.row($0.window)?.state.rawValue != "floats" })
                }
            }
            safe("ignored windows arrive", entering: false) {
                ignored.append(f.app.open(WindowSpec(subrole: "AXUnknown", popupParent: f.tiles[0]), background: true))
                ignored.append(f.app.open(WindowSpec(subrole: "AXSystemDialog", cgLayer: 21), background: true))
            }
            safe("enter \(mode.rawValue)", entering: mode == .shown) { f.enter(mode) }
            // Toggling enters from rails and exits from every focused layer row.
            safe("toggle from \(mode.rawValue)", entering: mode == .hidden) { f.tessel.press("toggle layer") }
            safe("toggle back", entering: mode != .hidden) { f.tessel.press("toggle layer") }
            safe("external tile selection", entering: false) { f.app.select(f.tiles[0]) }
            safe("external hidden float selection", entering: true) { f.app.select(f.floats[0]) }
            safe("hide a focused modal layer", entering: false) { f.tessel.press("toggle layer") }
            safe("new float", entering: false) { _ = f.app.open(WindowSpec(subrole: "AXDialog")) }
            if let single = f.mac.focusedWindow, !ignored.contains(single), !f.tiles.contains(single) {
                safe("focused float closes", entering: false) { f.app.close(single) }
            }
        })
    }

    @Test("#19 E27: entering and leaving move each float once with at most N float raises, no tile AX writes or captures; a new single moves none")
    func layerOperationCounts() {
        requireLayer(Scenario.run("layer operation count budget") { s in
            let specs = (0..<4).map { _ in WindowSpec(subrole: "AXFloatingWindow") }
            let f = LayerFixture(s, floatSpecs: specs, duration: 250)
            f.visible(f.floats, false)
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            f.press("toggle layer")
            s.expect("entry makes exactly N closet exits", f.closetMoves(showing: true).count == f.floats.count && Set(f.closetMoves(showing: true)) == Set(f.floats))
            s.expect("entry makes no closet entries", f.closetMoves(showing: false).isEmpty)
            let writes = LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start)))
            s.expect("entry makes zero AX writes to tiles", writes.allSatisfy { write in !f.tiles.contains { write.contains("window \($0) ") } })
            s.expect("entry makes at most N AXRaise calls to floats", writes.filter { $0.contains("perform AXRaise") }.count <= f.floats.count)
            s.expect("entry requests zero window, background or refresh captures", f.captureRequests.isEmpty)
            f.mac.clearMotionHistory()
            f.press("toggle layer")
            s.expect("exit makes exactly N closet entries", f.closetMoves(showing: false).count == f.floats.count && Set(f.closetMoves(showing: false)) == Set(f.floats))
            s.expect("exit makes no closet exits", f.closetMoves(showing: true).isEmpty)
            s.expect("exit requests zero window, background or refresh captures", f.captureRequests.isEmpty)
            f.mac.clearMotionHistory()
            let single = f.open()
            f.focus(single); f.state("single", focused: true)
            s.expect("a naturally visible new single needs zero closet moves", f.mac.visibilityChanges.flatMap(\.windows).isEmpty)
            s.expect("a new single requests no window, background or refresh capture", f.captureRequests.isEmpty)
        })
    }
}

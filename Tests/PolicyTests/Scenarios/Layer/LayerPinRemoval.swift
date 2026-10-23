import Foundation
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerPinRemoval {
    @Test("#38 E1: the former layer shortcut is unregistered and inert without a config", arguments: ["hidden", "single", "shown"], WriteOrder.allCases)
    func formerShortcutLeavesLayerFocusAndClosetUnchanged(_ state: String, _ writes: WriteOrder) {
        requireLayer(Scenario.run("unbound layer shortcut / \(state) / \(writes)", writes: writes) { s in
            let mac = s.mac, app = mac.launch()
            let tile = app.open()
            _ = app.open(WindowSpec(subrole: "AXDialog"), background: true)
            app.select(tile)
            let tessel = s.startTessel()
            s.settle()
            if state == "single" { _ = app.open(WindowSpec(subrole: "AXDialog")); s.settle() }
            if state == "shown" { tessel.pressKey("alt-z"); s.settle() }
            s.expect("the Given reaches \(state)", tessel.status.layer?.state == state)
            s.expect("the former shortcut has no registration", tessel.status.keys["alt-shift-z"] == nil)
            let layerKeys = tessel.status.keys.filter { $0.value.contains("layer") || $0.value == "toggle float" }
            s.expect("only entry and transfer are layer defaults", layerKeys == ["alt-z": "toggle layer", "alt-f": "toggle float"])
            let status = tessel.status, rows = tessel.windows, focus = mac.focusedWindow, front = mac.frontmostApp
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let publishedRows = try! encoder.encode(rows)
            let frames = rows.map { mac.frame($0.id) }, closet = rows.map { mac.isInCloset($0.id) }
            mac.clearMotionHistory()
            let start = mac.scheduler.trace.count
            s.step("press the unbound shortcut") { tessel.pressKey("alt-shift-z") }
            s.settle()
            s.expect("the key leaves layer state and membership unchanged", tessel.status == status && (try! encoder.encode(tessel.windows)) == publishedRows)
            s.expect("the key leaves native focus unchanged", mac.focusedWindow == focus && mac.frontmostApp == front)
            s.expect("the key leaves every frame and closet membership unchanged", rows.map { mac.frame($0.id) } == frames && rows.map { mac.isInCloset($0.id) } == closet)
            s.expect("the key makes no AX writes", LayerFixture.axWrites(in: Array(mac.scheduler.trace.dropFirst(start))).isEmpty)
            s.expect("the key makes no closet or stage requests", mac.visibilityChanges.isEmpty && mac.stageEvents.isEmpty && mac.stageCaptureRequests.isEmpty)
        })
    }

    @Test("#38 E2: a removed command is rejected with its line and the remaining valid commands")
    func removedCommandIsALineNumberedConfigError() {
        requireLayer(Scenario.run("removed command in a config") { s in
            let tessel = s.startTessel(text: "[keys]\nalt-x = 'pin layer'\n")
            s.settle()
            s.expect("the removed command is rejected at line 2", tessel.configuration.error?.line == 2)
            s.expect("the diagnostic lists exactly the surviving commands", tessel.configuration.error?.message == "Unknown command; use workspace 1…10, send 1…10, focus next|previous|left|right|up|down, move left|right|up|down, cycle width, toggle layer, or toggle float")
            s.expect("a rejected config keeps the default layer bindings", tessel.status.keys["alt-z"] == "toggle layer" && tessel.status.keys["alt-f"] == "toggle float" && tessel.status.keys["alt-x"] == nil)
        })
    }

    @Test("#38 E3: status JSON only publishes the three remaining layer states across transitions", arguments: LayerMode.allCases)
    func statusOnlyReportsRemainingLayerStates(_ mode: LayerMode) {
        requireLayer(Scenario.run("remaining layer JSON / \(mode.rawValue)") { s in
            let f = LayerFixture(s)
            f.enter(mode)
            @MainActor func check() {
                let reply = AppStatus(permission: "granted", config: f.tessel.configuration, version: "test", pid: 1, workspaces: f.tessel.status)
                let workspaces = encodedObject(reply)["workspaces"] as? [String: Any]
                let layer = workspaces?["layer"] as? [String: Any]
                s.expect("status --json stays within the remaining states", ["hidden", "single", "shown"].contains(layer?["state"] as? String ?? "missing"))
            }
            check()
            f.key("alt-shift-z"); check()
            for command in ["toggle layer", "focus right", "toggle float", "workspace 2", "workspace 1"] {
                f.press(command); check()
            }
        })
    }

    @Test("#38 E5: closing a background tile under a shown layer captures rail motion and raises before reveal", arguments: WriteOrder.allCases)
    func shownLayerRailMotionRaisesBeforeReveal(_ writes: WriteOrder) {
        requireLayer(Scenario.run("shown layer over a closing rail gap / \(writes)", writes: writes) { s in
            let f = LayerStackingFixture(s, duration: 250)
            f.press("toggle layer")
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            s.step("close the unfocused middle tile") { f.apps[0].close(f.tiles[1]) }
            s.settle()
            s.expect("the layer stays shown and focused", f.tessel.status.layer?.state == "shown" && f.mac.focusedWindow == f.floats[0])
            let requests = f.mac.stageCaptureRequests.filter { !$0.refreshing }
            s.expect("rail motion captures each surviving tile once", requests.flatMap { $0.windows.sorted() }.sorted() == [f.tiles[0], f.tiles[2]].sorted())
            s.expect("rail motion captures one background excluding its rail", requests.compactMap(\.backgroundExcluding) == [Set(f.tiles)])
            s.expect("rail motion reaches the shown stage and its reveal", f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } } && f.mac.stageEvents.contains { $0.kind == .revealed })
            let trace = Array(f.mac.scheduler.trace.dropFirst(start))
            let raises = trace.indices.filter { i in
                f.floats.dropFirst().contains { trace[i].contains("AccessibilityPort.perform AXRaise window \($0) ") && !trace[i].contains(" reply ") }
            }
            let reveal = trace.firstIndex { $0.contains("MotionStagePort.reveal") }
            s.expect("a nonempty serial background raise pass completes before reveal", raises.count == 2 && reveal != nil && raises.allSatisfy { $0 < reveal! })
            s.expect("the stage receives no ordering request", !trace.contains { $0.contains("MotionStagePort.order") })
            s.expect("the stage clears after revealing the placement", f.mac.stageEvents.last?.kind == .clear)
        })
    }
}

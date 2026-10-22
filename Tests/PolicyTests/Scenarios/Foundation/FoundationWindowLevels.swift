import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FoundationWindowLevels {
    @Test("#19 E1: only normal and floating CG levels are managed; other layers cannot affect membership, movement or focus", arguments: [Layout.carousel])
    func managedAndIgnoredWindowLevels(_ layout: Layout) {
        requireLayer(Scenario.run("native levels without the layer flag, layout=\(layout.rawValue)") { s in
            let app = s.mac.launch(windows: 1), t = s.startTessel(layout); s.settle()
            let tile = app.windows[0]
            let cases = [(8, "AXSystemDialog"), (21, "AXSystemDialog"), (24, "AXDialog"), (-2_147_483_601, "AXUnknown")]
            for (level, subrole) in cases {
                let start = s.mac.scheduler.trace.count
                s.mac.clearMotionHistory()
                let id = app.open(WindowSpec(subrole: subrole, cgLayer: level), background: true)
                let frame = s.mac.frame(id)
                s.settle()
                s.expect("CG reports the supplied native layer", s.mac.windowOrder.windowLevels([id])[id] == level)
                let row = t.windows.first { $0.id == id }
                s.expect("level \(level) is ignored with its exact reason", row?.state.rawValue == "ignored" && row?.reason == "window level \(level)")
                s.expect("ignored windows have no workspace, rail or slot", row?.workspace == nil && row?.rail == nil && row?.slot == nil)
                if layout == .carousel {
                    for command in ["workspace 2", "workspace 1"] { t.press(command); s.settle() }
                }
                s.expect("the tile retains focus", s.mac.focusedWindow == tile)
                s.expect("ignored windows are never placed or focused", !LayerFixture.axWrites(in: Array(s.mac.scheduler.trace.dropFirst(start))).contains { $0.contains("window \(id) ") })
                s.expect("ignored windows never enter or leave the closet", !s.mac.visibilityChanges.flatMap(\.windows).contains(id))
                s.expect("the native window stays visible and unmoved", s.mac.isVisible(id) && !s.mac.isInCloset(id) && s.mac.frame(id) == frame)
            }
            let panel = app.open(WindowSpec(subrole: "AXFloatingWindow"), background: true)
            s.settle()
            s.expect("a floating panel uses CG layer 3", s.mac.windowOrder.windowLevels([panel])[panel] == 3)
            FoundationProof.row(panel, in: t, state: .floats, reason: "AXFloatingWindow", scenario: s)
            let row = t.windows.first { $0.id == panel }
            s.expect("a managed panel has no rail or slot", row?.rail == nil && row?.slot == nil)
            if layout == .carousel { s.expect("a floating panel joins the active workspace", row?.workspace == 1) }
        })
    }

    @Test("#19 E2: an AXUnknown layer-zero root cannot change remembered focus or layout", arguments: [Layout.carousel], [false, true])
    func unknownRootCannotChangeFocusOrLayout(_ layout: Layout, withdraw: Bool) {
        requireLayer(Scenario.run("unknown native root churn, layout=\(layout.rawValue), withdraw=\(withdraw)") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 0)
            f.press("alt-l")
            if layout == .carousel { f.tessel.configure(.carousel); s.settle() }
            let before = f.snapshot(), focused = f.mac.focusedWindow, rail = f.tessel.status.rail
            @MainActor func membership() -> [String] {
                f.tessel.windows.filter { f.ids.contains($0.id) }.map { "\($0.id):\($0.workspace ?? 0):\($0.rail ?? 0):\($0.slot ?? 0)" }
            }
            let members = membership()
            @MainActor func unchanged(_ phase: String) {
                f.unchanged(before)
                s.expect("\(phase) leaves tile membership unchanged", membership() == members)
                s.expect("\(phase) leaves native focus and rail unchanged", f.mac.focusedWindow == focused && f.tessel.status.rail == rail)
            }
            f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count
            let popup = f.app.open(WindowSpec(subrole: "AXUnknown", resizable: false, popupParent: f.ids[1]), background: true)
            s.settle()
            let row = f.tessel.windows.first { $0.id == popup }
            s.expect("the unknown subrole is the ignored reason", row?.state.rawValue == "ignored" && row?.reason == "AXUnknown")
            s.expect("the root has no managed membership", row?.workspace == nil && row?.rail == nil && row?.slot == nil)
            unchanged("creation")
            if withdraw {
                f.app.close(popup); s.settle()
                unchanged("withdrawal")
            }
            s.expect("popup churn never writes tile geometry", f.mac.geometryWrites.allSatisfy { !f.ids.contains($0.window) })
            s.expect("popup churn never moves tiles through the closet", f.mac.visibilityChanges.allSatisfy { Set($0.windows).isDisjoint(with: f.ids) })
            s.expect("popup churn never places or focuses the ignored root", !LayerFixture.axWrites(in: Array(f.mac.scheduler.trace.dropFirst(start))).contains { $0.contains("window \(popup) ") })
            if layout == .carousel {
                // Probe memory while the popup exists as well as after its
                // withdrawal, outside the churn's zero-operation journal.
                f.press("alt-2"); f.press("alt-1")
                s.expect("popup churn preserves the remembered tile", f.mac.focusedWindow == focused)
                unchanged("returning to the remembered tile")
                f.press("alt-h"); f.focus(f.ids[0]); f.order(f.ids)
            }
        })
    }

    @Test("#19 E3: link-hover and address popups preserve slot-two focus and three left presses stay in rail one")
    func popupChurnDoesNotEscapeTheRail() {
        requireLayer(Scenario.run("same-app auxiliary popup regression") { s in
            let app = s.mac.launch(), other = s.mac.launch(), agent = s.mac.launch()
            let a = app.open(), b = app.open(), c = other.open()
            _ = agent.open(WindowSpec(subrole: "AXDialog", cgLayer: 24), background: true)
            app.select(b)
            let t = s.startTessel(.carousel); s.settle()
            other.select(c); s.settle(); t.press("move down"); s.settle()
            app.select(b); s.settle()
            s.expect("the reproduction starts at slot two of rail one", t.windows.first { $0.id == b }?.rail == 1 && t.windows.first { $0.id == b }?.slot == 2)
            let before = [a, b].map { s.mac.frame($0) }, start = s.mac.scheduler.trace.count
            for size in [CGSize(width: 376, height: 22), CGSize(width: 1119, height: 138)] {
                let popup = app.open(WindowSpec(frame: CGRect(origin: CGPoint(x: 40, y: 60), size: size), subrole: "AXUnknown", resizable: false, popupParent: a), background: true)
                s.settle()
                s.expect("a browser's auxiliary root never steals slot-two focus", s.mac.focusedWindow == b && s.mac.frontmostApp == app.pid)
                app.close(popup); s.settle()
            }
            for index in 0..<3 {
                s.mac.clearMotionHistory()
                t.press("focus left"); s.settle()
                s.expect("left press \(index + 1) focuses slot one", s.mac.focusedWindow == a && s.mac.frontmostApp == app.pid)
                s.expect("left presses never change the rail", t.status.rail == 1)
                if index > 0 {
                    s.expect("left wall produces a stage bounce", s.mac.stageEvents.contains { if case .move = $0.kind { true } else { false } })
                    s.expect("the wall bounce writes no real geometry", s.mac.geometryWrites.isEmpty)
                }
            }
            s.expect("rail one retains both original slots", t.windows.filter { $0.rail == 1 }.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }.map(\.id) == [a, b])
            s.expect("the original rail geometry returns", [a, b].map { s.mac.frame($0) } == before)
            let activation = s.mac.scheduler.trace.dropFirst(start).filter { ($0.contains("set AXFrontmost=true") || $0.contains("ApplicationPort.activate ")) && !$0.contains(" reply ") }
            s.expect("no other app is activated by tessel", activation.allSatisfy { $0.contains(app.alias + " ") })
        })
    }

    @Test("#19 E4: level-zero dialogs, panels, fixed-size and constrained windows keep their classification")
    func ordinaryFloatingClassificationsStayIntact() {
        requireLayer(Scenario.run("existing level-zero floating classifications") { s in
            let app = s.mac.launch()
            let cases: [(WindowSpec, String)] = [
                (WindowSpec(subrole: "AXDialog"), "AXDialog"),
                (WindowSpec(subrole: "AXSystemDialog"), "AXSystemDialog"),
                // This example retains the app's explicit normal-level override.
                (WindowSpec(subrole: "AXFloatingWindow", cgLayer: 0), "AXFloatingWindow"),
                (WindowSpec(resizable: false), "fixed size"),
            ]
            let ids = cases.map { app.open($0.0) }
            let t = s.startTessel(.carousel); s.settle()
            for (id, item) in zip(ids, cases) {
                FoundationProof.row(id, in: t, state: .floats, reason: item.1, scenario: s)
                s.expect("ordinary/dialog windows are on CG layer zero", s.mac.windowOrder.windowLevels([id])[id] == 0)
            }
        })
    }

    @Test("#19 E31: a background layer-21 system alert never activates its app or becomes a new float", arguments: ["layer"])
    func systemAlertDoesNotStealFocus(_ layout: String) {
        requireLayer(Scenario.run("withdrawn non-zero system alert, layout=\(layout)") { s in
            let app = s.mac.launch(windows: 1), alerts = s.mac.launch()
            let tile = app.windows[0]
            app.select(tile)
            let layer = layout == "layer"
            let t = s.startTessel(text: layer ? LayerFixture.config : layout == "carousel" ? CarouselFixture.config : nil); s.settle()
            if layer { s.expect("the layer flag is accepted", t.configuration.error == nil) }
            let before = s.mac.frame(tile), start = s.mac.scheduler.trace.count
            s.mac.clearMotionHistory()
            let alert = alerts.open(WindowSpec(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), subrole: "AXSystemDialog", cgLayer: 21), background: true)
            s.settle()
            let row = t.windows.first { $0.id == alert }
            s.expect("the full-screen-sized alert is ignored by level", row?.state.rawValue == "ignored" && row?.reason == "window level 21" && row?.workspace == nil)
            s.expect("publishing an alert preserves focus and frontmost app", s.mac.focusedWindow == tile && s.mac.frontmostApp == app.pid)
            if layer {
                let state = encodedObject(t.status)["layer"] as? [String: Any]
                s.expect("the alert never enters single mode", state?["state"] as? String == "hidden" && state?["focused"] as? Bool == false)
            }
            alerts.close(alert); s.settle()
            s.expect("withdrawal preserves focus, app and tile geometry", s.mac.focusedWindow == tile && s.mac.frontmostApp == app.pid && s.mac.frame(tile) == before)
            let trace = Array(s.mac.scheduler.trace.dropFirst(start))
            s.expect("tessel never activates the alert app", !trace.contains { ($0.contains("set AXFrontmost=true") || $0.contains("ApplicationPort.activate ")) && $0.contains(alerts.alias + " ") })
            s.expect("the alert receives no AX writes or closet moves", !LayerFixture.axWrites(in: trace).contains { $0.contains("window \(alert) ") } && !s.mac.visibilityChanges.flatMap(\.windows).contains(alert))
        })
    }
}

import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerClassificationRegressions {
    @Test("A formerly managed float returns from the closet before becoming ignored", arguments: ["window level 21", "AXUnknown"])
    func releaseIgnoredFloat(_ reason: String) {
        requireLayer(Scenario.run("release a closeted float reclassified as \(reason)") { s in
            let mac = s.mac, app = mac.launch()
            let tile = app.open(), panels = mac.launch()
            let panel = panels.open(WindowSpec(subrole: "AXDialog"), background: true)
            app.select(tile)
            let rows = PublishedRows(now: { mac.scheduler.now })
            var config = Configuration()
            config.experiments["layer"] = true
            config.animation.duration = 0
            let workspaces = Workspaces(store: rows, trusted: true, configuration: config,
                applications: mac.applications, ax: mac.ax, screens: mac.screens,
                windowOrder: mac.windowOrder, scheduler: mac.scheduler, hotkeys: PressedKeys(),
                fixtureOnly: true) { mac.closetPort }
            // Test the existing catalog-to-policy boundary directly. This
            // introduces no simulated level/subrole notification behavior.
            var observations = [
                WindowObservation(record: WindowRecord(id: tile, app: "Example", bundleId: "test.example", state: .tiled, reason: "standard window", tabs: 1), frame: mac.frame(tile)!, parent: nil),
                WindowObservation(record: WindowRecord(id: panel, app: "Example", bundleId: "test.example", state: .floats, reason: "AXDialog", tabs: 1), frame: mac.frame(panel)!, parent: nil)
            ]
            workspaces.update(pid: app.pid, observations: [observations[0]], focused: tile, frontmost: true, change: .snapshot)
            workspaces.update(pid: panels.pid, observations: [observations[1]], focused: panel, frontmost: false, change: .snapshot)
            s.settle()
            s.expect("the managed panel starts closeted", mac.isInCloset(panel))
            observations[1].record.state = .ignored
            observations[1].record.reason = reason
            workspaces.update(pid: panels.pid, observations: [observations[1]], focused: panel, frontmost: false, change: .snapshot)
            s.settle()
            let released = rows.byPID[panels.pid]?.first { $0.id == panel }
            s.expect("released window is ignored without membership", released?.state == .ignored && released?.workspace == nil)
            s.expect("released window is outside the closet", !mac.isInCloset(panel) && mac.isVisible(panel))
            s.expect("release preserves keyboard focus", mac.focusedWindow == tile)
            workspaces.disable(reason: "quit"); s.settle()
            s.expect("quit cannot strand a formerly managed window", !mac.isInCloset(panel) && mac.isVisible(panel))
        })
    }
}

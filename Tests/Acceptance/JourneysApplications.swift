import Carbon
import Darwin
import Testing

extension Acceptance.Journeys {
    @Test("#63 E1: an accessory app quitting closes its rail gap and one focus key reaches the survivor")
    func accessoryQuitClosesItsRailGap() throws {
        try appExitClosesItsRailGap(accessory: true, crash: false)
    }

    @Test("#63 E2: an accessory app crashing closes its rail gap and one focus key reaches the survivor")
    func accessoryCrashClosesItsRailGap() throws {
        try appExitClosesItsRailGap(accessory: true, crash: true)
    }

    @Test("#63 E3: an accessory app's standard window is tiled without requesting activation")
    func accessoryWindowIsDiscoveredWithoutActivation() throws {
        defer { cleanUpLifecycleFixtures() }
        try desktop.configure("[animation]\nduration = 0\n", layout: "carousel")
        let anchor = try fixture.open(key: "anchor")
        try desktop.activate(key: "anchor")
        try desktop.expectFocus(anchor)
        let target = try harness.other(accessory: true)
        try #require(try target.command("ping").active == false)
        let reply = try target.command("open", ["key": "quiet", "withoutActivating": true])
        let window = try #require(reply.windows["quiet"])
        try #require(reply.active == false, "the fixture must open its window without activating itself")
        try requireFinalState("the accessory window opened without activation is tiled") {
            try harness.row(window)?.state == "tiled"
        }
    }

    @Test("#63 E5: a regular app's exit removes its rows and preserves contiguous survivor slots")
    func regularExitLeavesNoRowsOrRailGap() throws {
        try appExitClosesItsRailGap(accessory: false, crash: false)
    }

    private func appExitClosesItsRailGap(accessory: Bool, crash: Bool) throws {
        defer { cleanUpLifecycleFixtures() }
        // Discover an existing rail so all three nominal widths fit on screen.
        // Window IDs establish the same left/middle/right order independently
        // of which application's first AX snapshot finishes first.
        harness.stopApp()
        try desktop.writeConfig("[animation]\nduration = 0\n")
        let left = try fixture.open(key: "left", ["widthFraction": 0.25])
        let target = try harness.other(accessory: accessory)
        let middle = try target.open(key: "middle", ["widthFraction": 0.25])
        let right = try fixture.open(key: "right", ["widthFraction": 0.25])
        try desktop.activate(key: "left")
        try harness.startApp(fixtureReady: false)
        try requireFinalState("the exiting app's tile is between two regular fixture windows") {
            let rows = try harness.rows(), ids = [left, middle, right]
            return Set(rows.map(\.id)) == Set(ids) && ids.enumerated().allSatisfy { index, id in
                rows.contains { $0.id == id && $0.state == "tiled" && $0.workspace == 1 && $0.rail == 1 && $0.slot == index + 1 }
            }
        }
        try desktop.expectFocus(left)
        if crash { try #require(kill(target.pid, SIGKILL) == 0) }
        else { try target.command("quit") }
        try requireFinalState("the middle fixture process has exited") { kill(target.pid, 0) != 0 }
        target.disconnect()
        harness.otherFixtures.removeAll { $0 === target }
        try requireFinalState("the exited app leaves no rows and the surviving rail slots are contiguous") {
            let rows = try harness.rows(), ids = [left, right]
            return Set(rows.map(\.id)) == Set(ids) && ids.enumerated().allSatisfy { index, id in
                rows.contains { $0.id == id && $0.state == "tiled" && $0.workspace == 1 && $0.rail == 1 && $0.slot == index + 1 }
            }
        }
        try desktop.expectFocus(left)
        try desktop.post(kVK_ANSI_L)
        try desktop.expectFocus(right)
    }

    private func cleanUpLifecycleFixtures() {
        // An unfixed adapter leaves ghosts after failure. Retire its catalog
        // before killing fixtures so the next journey can establish its Given.
        harness.stopApp()
        for target in harness.otherFixtures { target.stop() }
        harness.otherFixtures.removeAll()
    }
}

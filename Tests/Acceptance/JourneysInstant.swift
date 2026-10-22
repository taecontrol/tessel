import Carbon
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("#33 E15: posted mouse resizing leaves the first navigation and width keys responsive", arguments: [false, true])
    func dragThenFirstKeyboardCommand(selectsNeighbor: Bool) throws {
        // Legacy keys make the same journey usable against the accepted
        // baseline; the kept implementation accepts and ignores them.
        let area = try desktop.observe().area
        let half = ((area[2] - 30) / 2) / (area[2] - 20)
        let ids = try desktop.railSetup([half, half, half], duration: 0,
                                      configuration: "[experiments]\nworkspaces = true\ncarousel = true\nlayer = true\n")
        // A border press may select a previously unfocused tile. Its native
        // selection must own every subsequent command after mouse-up.
        let id = ids[selectsNeighbor ? 1 : 0]
        let initial = try desktop.observe()
        _ = try #require(initial.windows.first { $0.id == id && $0.visible })
        try harness.observer.command("contract", ["operation": "snapshot", "pid": fixture.pid])
        try harness.observer.command("contract", ["operation": "pointerStart", "pid": fixture.pid])
        try harness.observer.command("contract", ["operation": "dragResize", "pid": fixture.pid, "id": id, "delta": -120])
        try requireFinalState("all twenty posted drag steps and their release were delivered") {
            let events = try harness.observer.command("contract", ["operation": "pointerSamples", "pid": fixture.pid]).contract?.pointerEvents ?? []
            return events.first == "press" && events.filter { $0 == "drag" }.count == 20 && events.last == "release"
        }
        // Every post is single-shot. A result wait never posts a retry.
        try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[selectsNeighbor ? 2 : 1])
        try desktop.post(kVK_ANSI_H); try desktop.expectFocus(id)
        try desktop.post(kVK_ANSI_J, shift: true)
        try requireFinalState("a second rail exists") { try harness.row(id)?.rail == 2 }
        try desktop.post(kVK_ANSI_K); try desktop.expectFocus(ids[selectsNeighbor ? 0 : 1])
        try desktop.post(kVK_ANSI_J); try desktop.expectFocus(id)
        let before = try #require(try desktop.observe().windows.first { $0.id == id }).frame[2]
        try desktop.post(kVK_ANSI_R)
        try requireFinalState("the first resize key changes width") { try desktop.observe().windows.contains { $0.id == id && abs($0.frame[2] - before) > 2 } }
    }
}

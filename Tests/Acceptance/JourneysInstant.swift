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
        let ids = try desktop.railSetup([half, half, half, half], duration: 0,
                                      configuration: "[experiments]\nworkspaces = true\ncarousel = true\nlayer = true\n")
        // Prepare a second rail before the drag. The post-drag J/K return to
        // this populated rail, where R must cycle the accepted mouse width.
        for index in 1...3 { try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[index]) }
        try desktop.post(kVK_ANSI_J, shift: true)
        try requireFinalState("the keyboard destination rail exists before dragging") { try harness.row(ids[3])?.rail == 2 }
        try desktop.post(kVK_ANSI_K); try desktop.expectFocus(ids[2])
        try desktop.post(kVK_ANSI_H); try desktop.expectFocus(ids[1])
        try desktop.post(kVK_ANSI_H); try desktop.expectFocus(ids[0])
        // A border press may select a previously unfocused tile. Its native
        // selection must own every subsequent command after mouse-up.
        let id = ids[selectsNeighbor ? 1 : 0]
        let initial = try desktop.observe()
        let initialWidth = try #require(initial.windows.first { $0.id == id && $0.visible }).frame[2]
        try harness.observer.command("contract", ["operation": "snapshot", "pid": fixture.pid])
        try harness.observer.command("contract", ["operation": "pointerStart", "pid": fixture.pid])
        try harness.observer.command("contract", ["operation": "dragResize", "pid": fixture.pid, "id": id, "delta": -120])
        try requireFinalState("all twenty posted drag steps and their release were delivered") {
            let events = try harness.observer.command("contract", ["operation": "pointerSamples", "pid": fixture.pid]).contract?.pointerEvents ?? []
            return events.first == "press" && events.filter { $0 == "drag" }.count == 20 && events.last == "release"
        }
        try requireFinalState("the independent native observer sees the drag shrink the window before any keyboard command") {
            try desktop.observe().windows.contains { $0.id == id && $0.frame[2] < initialWidth - 60 }
        }
        let draggedWidth = try #require(try desktop.observe().windows.first { $0.id == id }).frame[2]
        // Every post is single-shot. A result wait never posts a retry.
        try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[selectsNeighbor ? 2 : 1])
        try desktop.post(kVK_ANSI_H); try desktop.expectFocus(id)
        try desktop.post(kVK_ANSI_J); try desktop.expectFocus(ids[3])
        try desktop.post(kVK_ANSI_K); try desktop.expectFocus(id)
        let before = try #require(try desktop.observe().windows.first { $0.id == id }).frame[2]
        try #require(abs(before - draggedWidth) <= 2, "navigation preserves the accepted mouse width")
        try #require(try harness.row(id)?.rail == 1 && harness.row(ids[selectsNeighbor ? 2 : 1])?.rail == 1)
        try desktop.post(kVK_ANSI_R)
        let nominalHalf = (area[2] - 30) / 2
        try requireFinalState("the first resize key advances from the mouse width to the half preset in a populated rail") {
            try desktop.observe().windows.contains { $0.id == id && abs($0.frame[2] - nominalHalf) <= 2 && abs($0.frame[2] - before) > 2 }
        }
    }
}

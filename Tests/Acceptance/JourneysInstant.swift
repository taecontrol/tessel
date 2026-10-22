import Carbon
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("#33 E15: posted mouse resizing leaves the first navigation and width keys responsive")
    func dragThenFirstKeyboardCommand() throws {
        // Legacy keys make the same journey usable against the accepted
        // baseline; the kept implementation accepts and ignores them.
        let ids = try desktop.railSetup([0.5, 0.5, 0.5], duration: 0,
                                      configuration: "[experiments]\nworkspaces = true\ncarousel = true\nlayer = true\n")
        // Find the actual focused tile; railSetup owns its fixture key names.
        let initial = try desktop.observe()
        let selected = try #require(initial.windows.first { $0.focused && ids.contains($0.id) })
        let id = selected.id
        try harness.observer.command("contract", ["operation": "snapshot", "pid": fixture.pid])
        try harness.observer.command("contract", ["operation": "pointerStart", "pid": fixture.pid])
        try harness.observer.command("contract", ["operation": "dragResize", "pid": fixture.pid, "id": id, "delta": -120])
        try requireFinalState("all twenty posted drag steps and their release were delivered") {
            let events = try harness.observer.command("contract", ["operation": "pointerSamples", "pid": fixture.pid]).contract?.pointerEvents ?? []
            return events.first == "press" && events.filter { $0 == "drag" }.count == 20 && events.last == "release"
        }
        // Every post is single-shot. A result wait never posts a retry.
        try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[1])
        try desktop.post(kVK_ANSI_H); try desktop.expectFocus(id)
        try desktop.post(kVK_ANSI_J, shift: true)
        try requireFinalState("a second rail exists") { try harness.row(id)?.rail == 2 }
        try desktop.post(kVK_ANSI_K); try desktop.expectFocus(ids[1])
        try desktop.post(kVK_ANSI_J); try desktop.expectFocus(id)
        let before = try #require(try desktop.observe().windows.first { $0.id == id }).frame[2]
        try desktop.post(kVK_ANSI_R)
        try requireFinalState("the first resize key changes width") { try desktop.observe().windows.contains { $0.id == id && abs($0.frame[2] - before) > 2 } }
    }
}

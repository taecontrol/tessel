import Carbon
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("#33 E15: posted mouse resizing leaves the first navigation and width keys responsive")
    func dragThenFirstKeyboardCommand() throws {
        let ids = try desktop.railSetup([0.5, 0.5, 0.5], duration: 0)
        // Find the actual focused tile; railSetup owns its fixture key names.
        let initial = try desktop.observe()
        let selected = try #require(initial.windows.first { $0.focused && ids.contains($0.id) })
        let id = selected.id
        try #require(try harness.observer.command("contract", ["operation": "dragResize", "pid": fixture.pid, "id": id, "delta": -120]).contract != nil)
        try requireFinalState("the posted gesture changed width and released at rail height") {
            let observation = try desktop.observe()
            return observation.windows.contains { $0.id == id && abs($0.frame[2] - (selected.frame[2] - 120)) <= 2 && abs($0.frame[3] - selected.frame[3]) <= 1 }
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

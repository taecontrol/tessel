import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("screen-recording-preflight: the Screen Recording grant reads without a prompt and stays stable", contract(.screenRecordingPreflight))
    func screenRecordingPreflight() throws {
        let facts = try native("screenRecording")
        try #require(facts.preflightStable == true, "two preflights in a row must agree")
        // Two preflights usually take about 20 ms; a prompt would take seconds.
        try #require((facts.preflightMilliseconds ?? .infinity) < 500, "a preflight must not wait on a prompt: \(facts.preflightMilliseconds ?? -1) ms")
    }

    @Test("stage-whole-window-capture: a whole window is captured on screen, as a sliver and in the closet, without moving or activating it", contract(.stageWholeWindowCapture))
    func stageCapturesWholeWindows() throws {
        try #require(try native("screenRecording").screenRecording == true, "grant Screen Recording to the signed fixture observer")
        let id = try fixture.open(); let original = try window(id)
        let full = try #require(try native("screen").screen)
        try desktop.activate()
        @discardableResult func capture(_ place: String) throws -> NativeContractReply.Stage {
            let facts = try #require(try native("stageCapture", ["id": id]).stage)
            let size = try #require(facts.captureSize), scale = try #require(facts.scale), frame = try #require(facts.frameBefore)
            try #require(abs(size[0] - frame[2] * scale) <= 1 && abs(size[1] - frame[3] * scale) <= 1,
                         "\(place): the capture is the whole window at its live size, got \(size) for \(frame)")
            try #require((facts.opaque ?? 0) > 0.9, "\(place): the capture has the window's pixels, opaque \(facts.opaque ?? 0)")
            try #require(facts.frameAfter == frame, "\(place): capturing does not move the window")
            try #require(facts.frontmostAfter == facts.frontmostBefore, "\(place): capturing does not activate the window")
            return facts
        }
        try capture("on screen")
        try #require(try write(id, "AXPosition", [full[0] + full[2] - 1, original.frame[1]]) == 0)
        // AX accepts the position before WindowServer lists it; capture once
        // both agree.
        try requireFinalState("the window rests as a one-point sliver") {
            let frame = try native("retained", ["id": id]).window?.frame ?? []
            let listed = try native("cgFrames").cgFrames?[String(id)] ?? []
            return frame.count == 4 && abs(frame[0] - (full[0] + full[2] - 1)) <= 1 && listed.count == 4 && desktop.near(listed, frame)
        }
        try capture("as a sliver")
        try native("closetStart"); defer { _ = try? native("closetStop") }
        try native("closetHide", ["ids": [id]])
        try requireFinalState("the window leaves the active Space") { try native("spaces", ["ids": [id]]).memberships?.first?.ordinary.isEmpty == true }
        try capture("in the closet")
        // Like the other closet contracts, return the window and let it rejoin
        // the active Space before the closet is destroyed, so the next
        // contract's native transitions start from a settled desktop.
        try native("closetShow", ["ids": [id]])
        try requireFinalState("the window rejoins the active Space") { try native("spaces", ["ids": [id]]).memberships?.first?.ordinary.isEmpty == false }
    }

    @Test("stage-overlay: a click-through floating overlay is listed and reads back drawn within the stage's wait, above windows and below the menu bar, without taking focus", contract(.stageOverlay))
    func stageOverlayShowsWithoutFocus() throws {
        let id = try fixture.open(); _ = try window(id)
        try desktop.activate()
        defer { _ = try? native("stageOverlayHide") }
        let facts = try #require(try native("stageOverlayShow").stage)
        // WindowServer may take tens of milliseconds; the stage waits up to
        // 150 ms for its own window to read back drawn.
        let listed = try #require(facts.overlayListedMilliseconds), drawn = try #require(facts.overlayDrawnMilliseconds)
        print("Stage overlay: listed after \(Int(listed)) ms, drawn after \(Int(drawn)) ms")
        try #require(listed >= 0 && listed <= 150, "the overlay is listed within the stage's wait, took \(listed) ms")
        try #require(drawn >= 0 && drawn <= 150, "the overlay reads back drawn within the stage's wait, took \(drawn) ms")
        try #require((facts.overlayLayer ?? -1) > 0 && (facts.overlayLayer ?? .max) < (facts.menuBarLayer ?? 0),
                     "the overlay is above windows and below the menu bar: layer \(facts.overlayLayer ?? -1), menu bar \(facts.menuBarLayer ?? -1)")
        try #require(facts.ignoresMouse == true && facts.key == false, "the overlay takes neither the pointer nor key focus")
        try #require(facts.frontmostAfter == facts.frontmostBefore, "showing the overlay does not change the frontmost app")
    }
}

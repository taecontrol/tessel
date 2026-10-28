import Carbon
import CoreGraphics
import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("#18 E24: map-overlay: tessel's map sits above the stage without taking focus and passes a centre click to the fixture", contract(.mapOverlay))
    func mapOverlayPreservesFocusAndPassesClicks() throws {
        defer { harness.stopApp() }
        let ids = try desktop.railSetup([1], duration: 0, configuration: "[experiments]\nmap = true\n[map]\nduration = 5000\n")
        let id = ids[0]
        let before = try desktop.observe(focusedOnly: true), nativeBefore = try fixture.command("ping")
        try #require(before.frontmostFixturePID == fixture.pid && desktop.focused(id, in: before))
        try desktop.post(kVK_ANSI_L)
        let overlay = try #require(try finalValue { try harness.mapWindows().first }, "the real map window must appear in tessel's CG listing")
        let state = try harness.mapState()
        try #require(state.window == overlay.id, "the observed window belongs to the real map adapter")
        try #require(overlay.level > Int(CGWindowLevelForKey(.floatingWindow)) && overlay.level < Int(CGWindowLevelForKey(.mainMenuWindow)))
        let visible = try #require(try native("screen").axVisibleFrame)
        let visibleFrame = CGRect(x: visible[0], y: visible[1], width: visible[2], height: visible[3])
        try #require(visibleFrame.contains(overlay.frame))
        try #require(abs(overlay.frame.maxX - (visibleFrame.maxX - 10)) <= 2
            && abs(overlay.frame.maxY - (visibleFrame.maxY - 10)) <= 2, "the card occupies the primary visible frame's bottom-right corner")
        try #require(state.key == false && state.main == false, "the native map window is neither key nor main")
        let after = try desktop.observe(focusedOnly: true), nativeAfter = try fixture.command("ping")
        try #require(after.frontmostFixturePID == before.frontmostFixturePID && desktop.focused(id, in: after))
        try #require(nativeAfter.keyWindow == nativeBefore.keyWindow && nativeAfter.mainWindow == nativeBefore.mainWindow)
        _ = try window(id) // Retain the signed observer's AX handle before posting.
        let clicks = nativeAfter.clicks?[String(id)] ?? 0
        try native("pointerPress", ["id": id, "point": [overlay.frame.midX, overlay.frame.midY]])
        try requireFinalState("a centre click reaches the fixture beneath the still-visible map") {
            try (fixture.command("ping").clicks?[String(id)] ?? 0) == clicks + 1 && harness.mapWindows().contains { $0.id == overlay.id }
        }
        // Harness.rows filters to fixture-owned records; decode the full public
        // response here so that absence is a discriminating catalog assertion.
        let reply = try harness.invoke("windows", "--json")
        try #require(reply.status == 0)
        let rows = try JSONDecoder().decode([Row].self, from: reply.outputData)
        try #require(!rows.contains { $0.id == overlay.id }, "the map never enters tessel windows")
    }

    @Test("#36 E1: stage-protected-capture: protected video has a locked surface without a base address; display and unprotected captures are readable", contract(.stageProtectedCapture))
    func stageProtectedCapture() throws {
        try #require(try native("screenRecording").screenRecording == true, "grant Screen Recording to the signed fixture observer")
        let id = try fixture.open(kind: "video")
        let managed = try window(id)
        try #require(managed.layer == 0 && managed.subrole == "AXStandardWindow", "the video fixture is an ordinary managed window")
        try desktop.activate()
        try fixture.command("preventsCapture", ["enabled": true])
        try requireFinalState("the protected video frame is ready for display") { try fixture.command("ping").videosReady?["window"] == true }
        // Only drawn windows are captured: an undrawn screenshot leaks a
        // recording attribution in replayd (ADR-0007).
        try requireFinalState("the video window is drawn on the active desktop") { try native().visible.contains(id) }
        var protected = try #require(try native("stageCapture", ["id": id]).stage)
        try requireFinalState("WindowServer applies protection to the drawn video") {
            if protected.readable == false { return true }
            protected = try #require(try native("stageCapture", ["id": id]).stage)
            return protected.readable == false
        }
        try #require(protected.hasSurface == true, "the protected screenshot still returns an IOSurface")
        try #require(protected.lockResult == 0, "the protected surface locks successfully")
        try #require(protected.readable == false, "a successful lock does not make protected pixels readable")
        let display = try #require(try native("stageCapture", ["id": id, "display": true]).stage)
        try #require(display.hasSurface == true && display.lockResult == 0 && display.readable == true,
                     "a display capture including the protected window has a base address")
        try fixture.command("preventsCapture", ["enabled": false])
        try requireFinalState("the unprotected video frame is ready for display") { try fixture.command("ping").videosReady?["window"] == true }
        let plain = try #require(try native("stageCapture", ["id": id]).stage)
        try #require(plain.hasSurface == true && plain.lockResult == 0 && plain.readable == true,
                     "removing protection restores a readable window capture")
    }

    @Test("screen-recording-preflight: the Screen Recording grant reads without a prompt and stays stable", contract(.screenRecordingPreflight))
    func screenRecordingPreflight() throws {
        let facts = try native("screenRecording")
        try #require(facts.preflightStable == true, "two preflights in a row must agree")
        // Two preflights usually take about 20 ms; a prompt would take seconds.
        try #require((facts.preflightMilliseconds ?? .infinity) < 500, "a preflight must not wait on a prompt: \(facts.preflightMilliseconds ?? -1) ms")
    }

    @Test("stage-whole-window-capture: a whole window is captured on screen, as a sliver and in the closet, without moving or activating it; off screen, only a closet window is drawn", contract(.stageWholeWindowCapture))
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
        // Listed off screen, a closet window has no ordinary Space, and it is
        // drawn.
        try requireFinalState("the window leaves the active Space") {
            try native("spaces", ["ids": [id]]).memberships?.first?.ordinary.isEmpty == true && !native().visible.contains(id)
        }
        try capture("in the closet")
        // Like the other closet contracts, return the window and let it rejoin
        // the active Space before the closet is destroyed, so the next
        // contract's native transitions start from a settled desktop.
        try native("closetShow", ["ids": [id]])
        try requireFinalState("the window rejoins the active Space") { try native("spaces", ["ids": [id]]).memberships?.first?.ordinary.isEmpty == false }
        // A hidden app's window, like one ordering out as it closes, is listed
        // off screen but keeps its ordinary Space, and is not drawn: the stage
        // does not capture it, because a screenshot of it never returns and
        // replayd keeps that capture's recording attribution.
        try fixture.command("hide")
        defer { _ = try? fixture.command("show") }
        try requireFinalState("a hidden window is listed off screen and keeps its ordinary Space") {
            try !native().visible.contains(id) && native("spaces", ["ids": [id]]).memberships?.first?.ordinary.isEmpty == false
        }
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

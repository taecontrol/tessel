import Carbon
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_LAYER"] == "1", "owner review of the floating layer"))
    @MainActor
    struct LayerCaptures {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }
        var directory: URL { root.appending(path: ".work/captures/layer") }

        func prepare() throws -> (tiles: [UInt32], floats: [UInt32]) {
            try desktop.clear()
            let tiles = try desktop.railSetup([0.5, 0.5, 0.5], duration: 0)
            let floats = try ["panelA", "panelB"].map { try fixture.open(kind: "normalPanel", key: $0, ["background": true]) }
            try fixture.command("move", ["key": "panelA", "frame": [150, 200, 400, 260]])
            try fixture.command("move", ["key": "panelB", "frame": [400, 350, 380, 250]])
            try requireFinalState("the capture fixtures are catalogued") { Set(try harness.rows().map(\.id)) == Set(tiles + floats) }
            try desktop.activate(key: "w0")
            try desktop.configure("[experiments]\nlayer = true\n[animation]\nduration = 400\n", layout: "carousel")
            try requireFinalState("the capture starts on its tile with all floats hidden") {
                let observed = try desktop.observe()
                return desktop.focused(tiles[0], in: observed) && floats.allSatisfy { !observed.visibleIDs.contains($0) }
            }
            return (tiles, floats)
        }

        func instructions(_ example: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let body = "\(example): pending owner capture and review\n\n" + text + "\n"
            try Data(body.utf8).write(to: directory.appending(path: example + "-instructions.md"), options: .atomic)
            print(body)
            fflush(nil)
        }

        @Test("#19 E11: record visible pinned floats above moving rails for owner review")
        func capturePinnedFloatsAboveMovingRails() throws {
            let scene = try prepare()
            try desktop.activate(key: "w2")
            try desktop.post(kVK_ANSI_J, shift: true)
            try requireFinalState("the recording has a second rail") { try harness.row(scene.tiles[2])?.rail == 2 }
            try desktop.post(kVK_ANSI_K)
            try desktop.expectFocus(scene.tiles[1])
            try desktop.post(kVK_ANSI_Z, shift: true)
            try requireFinalState("both floats are pinned above the rail before recording") {
                let observed = try desktop.observe()
                return scene.floats.allSatisfy { observed.visibleIDs.contains($0) } && desktop.focused(scene.tiles[1], in: observed)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let movie = directory.appending(path: "E11-pinned-rails.mov")
            try? FileManager.default.removeItem(at: movie)
            let area = try desktop.observe().area.map { Int($0.rounded()) }
            let recorder = Process()
            recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            recorder.arguments = ["-v", "-V4", "-x", "-R" + area.map(String.init).joined(separator: ","), movie.path]
            recorder.standardInput = FileHandle.nullDevice
            recorder.standardOutput = FileHandle.nullDevice
            recorder.standardError = FileHandle.nullDevice
            try recorder.run()
            defer { if recorder.isRunning { recorder.terminate() } }
            // Recording cadence only; final states still use the shared margin.
            sleep(seconds: 0.2)
            for code in [kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_H] {
                try desktop.post(code)
                sleep(seconds: 0.4)
            }
            recorder.waitUntilExit()
            try #require(recorder.terminationStatus == 0 && (try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0,
                         "E11 needs a pixel recording; geometry observations alone cannot prove overlay ordering")
            try instructions("E11", "Review E11-pinned-rails.mov. Both invented panels must remain above every moving tile throughout the rail changes. Record the owner's verdict separately; creating this movie does not approve the behavior. Keep the movie local until any personal content is removed.")
        }

        @Test("#19 E30: prepare the chosen prototype interactions for an owner-performed comparison")
        func captureOwnerPrototypeComparison() throws {
            _ = try prepare()
            try instructions("E30", "Preparation only: the isolated fixtures are cleaned up when this test returns. In a separate authorized owner session with the signed fixed build, compare the chosen prototype variants U1 B, U2 B, U3 B, U4 A: arrival-order wrap with h/j/k/l; alt-f centers a tile at half width and two-thirds height; moving back chooses the nearest rail width; alt-shift-z pins. Record use of alt-z to return to the remembered tile and review the comparison. This harness does not record the owner's verdict.")
        }

        @Test("#19 E32: prepare the owner-performed timer-alert focus regression capture")
        func captureOwnerTimerAlertFocus() throws {
            _ = try prepare()
            try instructions("E32", "Preparation only: fixture-only mode excludes real system alerts, so it cannot validate this example. After harness cleanup, use the signed fixed build in the owner's authorized session, with a tile focused. Start a system timer, record the alert firing and whether keyboard focus and the frontmost app change. If focus is lost, preserve independent evidence of native activation and report it with the review. Keep raw recordings and window information private; this test neither drives a timer nor claims the regression passed.")
        }
    }
}

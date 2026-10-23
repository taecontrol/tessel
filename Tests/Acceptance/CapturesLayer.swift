import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_LAYER"] == "1", "local floating-layer evidence"))
    @MainActor
    struct LayerCaptures {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }
        var directory: URL { root.appending(path: ".work/captures/layer") }

        func prepare() throws {
            try desktop.clear()
            let tiles = try desktop.railSetup([0.5, 0.5, 0.5], duration: 0)
            let floats = try ["panelA", "panelB"].map { try fixture.open(kind: "normalPanel", key: $0, ["background": true]) }
            try fixture.command("move", ["key": "panelA", "frame": [150, 200, 400, 260]])
            try fixture.command("move", ["key": "panelB", "frame": [400, 350, 380, 250]])
            try requireFinalState("the capture fixtures are catalogued") { Set(try harness.rows().map(\.id)) == Set(tiles + floats) }
            try desktop.activate(fixture, key: "w0")
            try desktop.configure("[experiments]\nlayer = true\n[animation]\nduration = 400\n", layout: "carousel")
            try requireFinalState("the capture starts on its tile with all floats hidden") {
                let observed = try desktop.observe()
                return desktop.focused(tiles[0], in: observed) && floats.allSatisfy { !observed.visibleIDs.contains($0) }
            }
        }

        func instructions(_ example: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let body = "\(example): pending owner capture and review\n\n" + text + "\n"
            try Data(body.utf8).write(to: directory.appending(path: example + "-instructions.md"), options: .atomic)
            print(body)
            fflush(nil)
        }

        @Test("#19 E30; #38 E8: execute the selected prototype walkthroughs and record observed versus expected fidelity")
        func captureOwnerPrototypeComparison() throws {
            var fidelity = LayerFidelity(desktop: desktop, directory: directory)
            try fidelity.run()
        }

        @Test("#19 E32: prepare the owner-performed timer-alert focus regression capture")
        func captureOwnerTimerAlertFocus() throws {
            try prepare()
            try instructions("E32", "Preparation only: fixture-only mode excludes real system alerts, so it cannot validate this example. After harness cleanup, use the signed fixed build in the owner's authorized session, with a tile focused. Start a system timer, record the alert firing and whether keyboard focus and the frontmost app change. If focus is lost, preserve independent evidence of native activation and report it with the review. Keep raw recordings and window information private; this test neither drives a timer nor claims the regression passed.")
        }
    }
}

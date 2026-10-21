import Carbon
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

        func prepare(backgroundPanels: Bool = false) throws -> (tiles: [UInt32], floats: [UInt32], tilePIDs: [Int32], floatPID: Int32) {
            try desktop.clear()
            // A mixed-app rail exposes both sides of the native stacking limit:
            // panels cover background tiles while the focused tile stays above.
            let first = try backgroundPanels ? harness.other() : fixture
            let tiles = try desktop.railSetup([0.5, 0.5, 0.5], firstIn: first, duration: 0)
            let panels = try backgroundPanels ? harness.other() : fixture
            let floats = try ["panelA", "panelB"].map { try panels.open(kind: "normalPanel", key: $0, ["background": true]) }
            try panels.command("move", ["key": "panelA", "frame": [150, 200, 400, 260]])
            try panels.command("move", ["key": "panelB", "frame": [400, 350, 380, 250]])
            try requireFinalState("the capture fixtures are catalogued") { Set(try harness.rows().map(\.id)) == Set(tiles + floats) }
            try desktop.activate(first, key: "w0")
            try desktop.configure("[experiments]\nlayer = true\n[animation]\nduration = 400\n", layout: "carousel")
            try requireFinalState("the capture starts on its tile with all floats hidden") {
                let observed = try desktop.observe()
                return desktop.focused(tiles[0], in: observed) && floats.allSatisfy { !observed.visibleIDs.contains($0) }
            }
            return (tiles, floats, [first.pid, fixture.pid, fixture.pid], panels.pid)
        }

        func instructions(_ example: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let body = "\(example): pending owner capture and review\n\n" + text + "\n"
            try Data(body.utf8).write(to: directory.appending(path: example + "-instructions.md"), options: .atomic)
            print(body)
            fflush(nil)
        }

        @Test("#19 E11: record pinned floats in their at-rest stacking order above background-app tiles")
        func capturePinnedFloatsAboveMovingRails() throws {
            let scene = try prepare(backgroundPanels: true)
            try desktop.activate(key: "w2")
            try desktop.post(kVK_ANSI_J, shift: true)
            try requireFinalState("the recording has a second rail") { try harness.row(scene.tiles[2])?.rail == 2 }
            try desktop.post(kVK_ANSI_K)
            try desktop.expectFocus(scene.tiles[1])
            try desktop.post(kVK_ANSI_Z, shift: true)
            func pinnedOrder(_ observed: Observation, focus: UInt32) -> Bool {
                guard let tile = scene.tiles.firstIndex(of: focus), observed.frontmostFixturePID == scene.tilePIDs[tile],
                      desktop.focused(focus, in: observed), let keyIndex = observed.visibleIDs.firstIndex(of: focus) else { return false }
                return scene.floats.allSatisfy { float in
                    guard let index = observed.visibleIDs.firstIndex(of: float), keyIndex < index else { return false }
                    return scene.tiles.enumerated().filter { scene.tilePIDs[$0.offset] != observed.frontmostFixturePID }.allSatisfy { _, id in
                        observed.visibleIDs.firstIndex(of: id).map { index < $0 } ?? true
                    }
                }
            }
            func expectPinnedOrder(_ description: String, focus: UInt32) throws {
                let owners = Dictionary(uniqueKeysWithValues: zip(scene.tiles, scene.tilePIDs))
                    .merging(Dictionary(uniqueKeysWithValues: scene.floats.map { ($0, scene.floatPID) })) { tile, _ in tile }
                func window(_ id: UInt32) -> String {
                    "\(scene.tiles.contains(id) ? "tile" : "float") \(id) (fixture pid \(owners[id]!))"
                }
                var last = "no observation"
                do {
                    try requireFinalState(description) {
                        let observed = try desktop.observe()
                        let focused = observed.windows.filter { owners[$0.id] != nil && $0.focused }.map(\.id)
                        let target = observed.windows.first { $0.id == focus }
                        let order = observed.visibleIDs.enumerated().filter { owners[$0.element] != nil }
                            .map { "\($0.offset): \(window($0.element))" }
                        let missing = (scene.tiles + scene.floats).filter { !observed.visibleIDs.contains($0) }.map(window)
                        last = "frontmost fixture pid \(observed.frontmostFixturePID), expected \(owners[focus]!); "
                            + "focused scene IDs \(focused), expected \(focus); "
                            + "expected focus \(target.map { "visible=\($0.visible) main=\($0.main) focused=\($0.focused)" } ?? "absent"); "
                            + "CG front-to-back [\(order.joined(separator: "; "))]; absent from CG [\(missing.joined(separator: "; "))]"
                        return pinnedOrder(observed, focus: focus)
                    }
                } catch { throw HarnessError("\(error); last observation: \(last)") }
            }
            try expectPinnedOrder("both background panels are pinned in their at-rest order before recording", focus: scene.tiles[1])
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
            try expectPinnedOrder("the final tile keeps focus while panels remain above background tiles", focus: scene.tiles[0])
            try instructions("E11", "Review E11-pinned-rails.mov. The stage must draw pinned floats in their at-rest stacking order: above every tile macOS lets them cover (background apps' tiles), below the frontmost app's windows that remain above them. The panels use a different signed fixture app from both tile apps; the mixed-app rail supplies background tiles they can cover. macOS 27 retains the frontmost app's focused tile above these background panels even after AXRaise. The movie must preserve that order throughout motion and clearing, without a pop. Same-app floats are never raised because AXRaise may select them; their native at-rest order also determines their stand-ins. Record the owner's visual verdict separately; creating this movie does not approve the behavior. Keep the movie local until any personal content is removed.")
        }

        @Test("#19 E30: execute the selected prototype walkthroughs and record observed versus expected fidelity")
        func captureOwnerPrototypeComparison() throws {
            var fidelity = LayerFidelity(desktop: desktop, directory: directory)
            try fidelity.run()
        }

        @Test("#19 E32: prepare the owner-performed timer-alert focus regression capture")
        func captureOwnerTimerAlertFocus() throws {
            _ = try prepare()
            try instructions("E32", "Preparation only: fixture-only mode excludes real system alerts, so it cannot validate this example. After harness cleanup, use the signed fixed build in the owner's authorized session, with a tile focused. Start a system timer, record the alert firing and whether keyboard focus and the frontmost app change. If focus is lost, preserve independent evidence of native activation and report it with the review. Keep raw recordings and window information private; this test neither drives a timer nor claims the regression passed.")
        }
    }
}

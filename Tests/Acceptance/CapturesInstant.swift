import Carbon
import Darwin
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(launchesApp: false), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_INSTANT"] == "1", "opt-in instant pixel evidence"))
    @MainActor struct InstantCaptures {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }

        struct Row: Encodable {
            let operation: String
            let variant: String
            let repetition: Int
            let pixels: InstantPixelRecording.Analysis
            let nativeChanged: Bool
            let nativePixelsAgree: Bool
        }

        struct NativeViews: Encodable {
            let postedAt: Double
            let ids: [UInt32]
            let points: [Double]
            let before: [String: [Double]]
            let after: [String: [Double]]
            let beforeOrder: [UInt32]
            let afterOrder: [UInt32]
        }

        @Test("#33 E20: twelve fixture-only 120 Hz recordings per instant operation")
        func captureInstantOperations() throws {
            let directory = root.appending(path: ".work/captures/instant")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var results: [Row] = []
            var recordingActive = false
            defer {
                if recordingActive { _ = try? harness.observer.command("contract", ["operation": "instantRecordingStop", "pids": [fixture.pid], "path": directory.appending(path: "tail.json").path]) }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for operation in ["workspace", "rail", "width", "stop", "open", "close"] {
                for repetition in 1...12 {
                    let variant = operation == "width" ? (repetition.isMultiple(of: 2) ? "right" : "left")
                        : operation == "stop" ? (repetition.isMultiple(of: 2) ? "mixed" : "halves") : "standard"
                    print("Instant capture: \(operation) \(variant) \(repetition)/12"); fflush(nil)
                    // Reset while stopped: closing the old view under a live
                    // manager would queue a Finder activation into the next Given.
                    harness.stopApp()
                    try fixture.command("reset")
                    let area = try desktop.observe().area
                    let half = ((area[2] - 30) / 2) / (area[2] - 20)
                    let middle = variant == "mixed" ? half - 120 / (area[2] - 20) : half
                    // Palette style is part of window creation. Changing the
                    // titlebar style after Given would change its AX geometry.
                    let ids = try desktop.railSetup([half, middle, half], duration: 0, palette: true)
                    switch operation {
                    case "workspace":
                        try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[1])
                        try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[2])
                        try desktop.key(2, send: true)
                        try requireFinalState("capture destination membership") { try harness.row(ids[2])?.workspace == 2 && harness.status().workspaces?.active == 2 }
                        try desktop.expectFocus(ids[2]); try desktop.key(1); try desktop.expectFocus(ids[1])
                    case "rail":
                        try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[1])
                        try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[2])
                        try desktop.post(kVK_ANSI_J, shift: true)
                        try requireFinalState("capture destination rail") { try harness.row(ids[2])?.rail == 2 }
                        try desktop.expectFocus(ids[2]); try desktop.post(kVK_ANSI_K); try desktop.expectFocus(ids[1])
                    case "stop": try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[1])
                    case "width" where variant == "right": try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[1])
                    default: break
                    }
                    let before = try desktop.observe()
                    let path = directory.appending(path: "\(operation)-\(repetition).json")
                    let request: [String: Any] = ["operation": "instantRecordingStart", "pids": [fixture.pid]]
                    let started = try #require(try harness.observer.command("contract", request).contract)
                    let points = try #require(started.recordingPoints)
                    recordingActive = true
                    var recordingStopped = false
                    defer {
                        if !recordingStopped { _ = try? harness.observer.command("contract", ["operation": "instantRecordingStop", "pids": [fixture.pid], "path": path.path]) }
                    }
                    // Shareable-content setup can activate another process.
                    // Restore the start selection before the recorded baseline.
                    if let selected = before.windows.first(where: { $0.focused && ids.contains($0.id) }), let index = ids.firstIndex(of: selected.id) {
                        try desktop.activate(key: "w\(index)")
                        try desktop.expectFocus(selected.id)
                    }
                    // Stable baseline and final suffix are evidence, not timing gates.
                    sleep(seconds: 0.15)
                    let posted: Double
                    var arrivalFrame: [Double]?
                    switch operation {
                    case "workspace": posted = try desktop.key(2)
                    case "rail": posted = try desktop.post(kVK_ANSI_J)
                    case "width": posted = try desktop.post(kVK_ANSI_R)
                    case "stop": posted = try desktop.post(kVK_ANSI_L)
                    case "open":
                        posted = monotonicSeconds()
                        let arrival = try fixture.command("open", ["key": "arrival", "color": 3])
                        // The app reports this before yielding to AX. Convert
                        // AppKit's bottom-origin native frame to capture space.
                        let frame = try #require(arrival.frames?["arrival"])
                        arrivalFrame = [frame[0], points[1] - frame[1] - frame[3], frame[2], frame[3]]
                    default:
                        posted = monotonicSeconds(); try fixture.command("close", ["key": "w0"])
                    }
                    let finalFocus: UInt32
                    switch operation {
                    case "workspace", "rail", "stop": finalFocus = ids[2]
                    case "close": finalFocus = ids[1]
                    case "open": finalFocus = try #require(try fixture.command("ping").windows["arrival"])
                    default: finalFocus = ids[variant == "right" ? 1 : 0]
                    }
                    try desktop.expectFocus(finalFocus)
                    sleep(seconds: 0.35)
                    let after = try desktop.observe()
                    try harness.observer.command("contract", ["operation": "instantRecordingStop", "pids": [fixture.pid], "path": path.path, "keepRunning": true])
                    recordingStopped = true
                    let views = NativeViews(postedAt: posted, ids: ids, points: points,
                        before: Dictionary(uniqueKeysWithValues: before.windows.filter { $0.visible }.map { (String($0.id), $0.frame) }),
                        after: Dictionary(uniqueKeysWithValues: after.windows.filter { $0.visible }.map { (String($0.id), $0.frame) }),
                        beforeOrder: before.visibleIDs, afterOrder: after.visibleIDs)
                    try encoder.encode(views).write(to: directory.appending(path: "\(operation)-\(repetition)-native.json"), options: .atomic)
                    let recording = try JSONDecoder().decode(InstantPixelRecording.self, from: Data(contentsOf: path))
                    let finalArrival = after.windows.first { $0.id == finalFocus }?.frame
                    let analysis = try recording.analyze(postedAt: posted, pointsWide: points[0], arrival: operation == "open" ? 4 : nil,
                                                         departing: operation == "close" ? 1 : nil, initialArrival: arrivalFrame, finalArrival: operation == "open" ? finalArrival : nil)
                    let nativeChanged = before.windows.map(\.frame) != after.windows.map(\.frame) || before.visibleIDs != after.visibleIDs
                    // This validation rejects the spike's app-filtered stream,
                    // which stayed frozen while native probes saw AX movement.
                    try #require(nativeChanged && analysis.changedPixels > 0, "pixel movement must agree with the independent native probe")
                    var nativePixelsAgree = true
                    for (index, id) in ids.enumerated() {
                        for (observation, last) in [(before, false), (after, true)] {
                            guard let window = observation.windows.first(where: { $0.id == id && $0.visible }) else { continue }
                            // A partial edge tile's native center can lie off
                            // screen. Validate its visible content instead.
                            let visible = CGRect(x: window.frame[0], y: window.frame[1], width: window.frame[2], height: window.frame[3])
                                .intersection(CGRect(x: 0, y: 0, width: points[0], height: points[1]))
                            guard !visible.isEmpty,
                                  observation.visibleIDs.first == id || observation.windows.filter({ $0.visible && $0.id != id }).allSatisfy({ other in
                                      let x = visible.midX, y = visible.midY
                                      return x < other.frame[0] || x >= other.frame[0] + other.frame[2] || y < other.frame[1] || y >= other.frame[1] + other.frame[3]
                                  }) else { continue }
                            let matches = try recording.owner(UInt8(index + 1), at: [visible.minX, visible.minY, visible.width, visible.height], points: points, last: last, postedAt: posted)
                            #expect(matches, "fixture palette \(index + 1) must match window \(id), \(last ? "final" : "start") visible frame \(visible); native views saved beside the recording")
                            nativePixelsAgree = nativePixelsAgree && matches
                        }
                    }
                    if operation == "open", let frame = finalArrival {
                        let opened = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
                        #expect(after.windows.filter { $0.id != finalFocus && $0.visible }.allSatisfy { other in
                            !opened.intersects(CGRect(x: other.frame[0], y: other.frame[1], width: other.frame[2], height: other.frame[3]))
                        }, "the opened tile must not overlap another final tile")
                    }
                    results.append(Row(operation: operation, variant: variant, repetition: repetition, pixels: analysis, nativeChanged: nativeChanged, nativePixelsAgree: nativePixelsAgree))
                    try encoder.encode(results).write(to: directory.appending(path: "analysis.json"), options: .atomic)
                }
            }
            try harness.observer.command("contract", ["operation": "instantRecordingStop", "pids": [fixture.pid], "path": directory.appending(path: "tail.json").path])
            recordingActive = false
            try encoder.encode(results).write(to: directory.appending(path: "analysis.json"), options: .atomic)
            print("| Operation | Repetitions | Intermediate frames | Gap frames | Invalid palette |")
            print("| --- | ---: | ---: | ---: | ---: |")
            for operation in ["workspace", "rail", "width", "stop", "open", "close"] {
                let rows = results.filter { $0.operation == operation }
                let bad = rows.reduce(0) { $0 + $1.pixels.intermediateFrames }, gaps = rows.reduce(0) { $0 + $1.pixels.gapFrames }
                print("| \(operation) | \(rows.count) | \(bad) | \(gaps) | \(rows.filter { !$0.nativePixelsAgree }.count) |")
                #expect(bad == 0 && gaps == 0, "\(operation) must show only start/final content with uninterrupted shared coverage")
            }
            for variant in ["left", "right"] {
                let rows = results.filter { $0.operation == "width" && $0.variant == variant }
                print("| alt-r \(variant) | \(rows.count) | \(rows.reduce(0) { $0 + $1.pixels.intermediateFrames }) | \(rows.reduce(0) { $0 + $1.pixels.gapFrames }) | \(rows.filter { !$0.nativePixelsAgree }.count) |")
            }
        }
    }
}

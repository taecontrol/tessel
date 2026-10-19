import Carbon
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_CAROUSEL"] == "1", "owner review geometry capture"))
    @MainActor
    struct CarouselCaptures {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }

        struct Journey: Encodable {
            let example: String
            let duration: Int
            let screen: [Double]
            let area: [Double]
            var windows: [UInt32]
            var steps: [Step] = []
        }
        struct Step: Encodable {
            let command: String
            let eventClock: String
            let postedAt: Double
            let samples: [NativeContractReply.MotionSample]
        }
        struct Scene {
            let ids: [UInt32]
            let screen: [Double]
            let area: [Double]
            func width(_ preset: Double) -> Double { preset * (area[2] + 10) - 10 }
            func frames(_ ids: [UInt32], widths: [Double], camera: Double = 0, expanded: Int? = nil) -> [UInt32: [Double]] {
                var x = area[0] - camera
                if let expanded { x = area[0] - widths.prefix(expanded).reduce(0) { $0 + $1 + 10 } }
                var result: [UInt32: [Double]] = [:]
                for (index, id) in ids.enumerated() {
                    let width = expanded == index ? area[2] : widths[index]
                    let frame = [x, area[1], width, area[3]]
                    if x < screen[0] + screen[2] - 0.01 && x + width > screen[0] + 0.01 { result[id] = frame }
                    else if abs(x + width - screen[0]) < 0.01 { result[id] = [screen[0] - width, area[1], width, area[3]] }
                    x += width + 10
                }
                return result
            }
        }

        func prepare(_ presets: [Double]) throws -> Scene {
            try desktop.clear()
            let native = try #require(try harness.observer.command("contract", ["operation": "screen", "pid": fixture.pid]).contract)
            let screen = try #require(native.screen), visible = try #require(native.axVisibleFrame)
            let area = [visible[0] + 10, visible[1] + 10, visible[2] - 20, visible[3] - 20]
            var ids: [UInt32] = []
            for (index, preset) in presets.enumerated() {
                let key = "w\(index)"
                let id = try fixture.open(kind: index.isMultiple(of: 2) ? "heavyText" : "web", key: key,
                    ["title": "Invented window \(index + 1)"])
                ids.append(id)
                try fixture.command("move", ["key": key, "frame": [area[0], area[1], preset * (area[2] + 10) - 10, area[3]]])
            }
            try desktop.activate(key: "w0")
            try requireFinalState("the capture fixtures are catalogued") { Set(try harness.rows().map(\.id)) == Set(ids) }
            try duration(0)
            try desktop.expectShown(ids[0])
            return Scene(ids: ids, screen: screen, area: area)
        }

        func duration(_ value: Int) throws {
            try desktop.configure(desktop.carousel + "[animation]\nduration = \(value)\n", layout: "carousel")
        }

        func landed(_ frames: [UInt32: [Double]], among ids: [UInt32], focus: UInt32) throws -> Bool {
            let observation = try desktop.observe()
            return desktop.focused(focus, in: observation) && ids.allSatisfy { id in
                guard let expected = frames[id] else { return !observation.visibleIDs.contains(id) }
                // Fractional presets can put an edge less than a native pixel
                // outside. AX's one-point clamp may retain that boundary tile;
                // the recording preserves it rather than inventing occlusion.
                if abs(expected[0] + expected[2] - observation.area[0]) < 0.01 {
                    return !observation.visibleIDs.contains(id) || observation.windows.contains {
                        $0.id == id && $0.frame[0] + $0.frame[2] <= observation.area[0] + 1
                            && desktop.near(Array($0.frame.suffix(3)), Array(expected.suffix(3)))
                    }
                }
                return observation.visibleIDs.contains(id) && observation.windows.contains {
                    $0.id == id && $0.visible && desktop.near($0.frame, expected)
                }
            }
        }

        func settle(_ frames: [UInt32: [Double]], among ids: [UInt32], focus: UInt32) throws {
            try requireFinalState("the capture setup's worked final geometry, focus and visibility") {
                try landed(frames, among: ids, focus: focus)
            }
        }

        func record(_ command: String, duration: Int, ids: [UInt32], discover: Bool = false,
                    action: () throws -> Double, final: () throws -> Bool) throws -> Step {
            guard finalValue({ try? harness.observer.command("contract", ["operation": "motionStart", "pid": fixture.pid,
                "capture": true, "discover": discover, "targets": [["pid": fixture.pid, "ids": ids]]]).contract }) != nil else {
                throw HarnessError("capture observer did not start")
            }
            defer { _ = try? harness.observer.command("contract", ["operation": "motionStop", "pid": fixture.pid]) }
            var samples: [NativeContractReply.MotionSample] = []
            func drain(_ operation: String = "motionSamples") throws -> NativeContractReply {
                let reply = try #require(try harness.observer.command("contract",
                    ["operation": operation, "pid": fixture.pid, "drain": true]).contract)
                samples += reply.motionSamples ?? []
                return reply
            }
            try requireFinalState("at least one independent baseline display sample") {
                _ = try drain(); return !samples.isEmpty
            }
            let postedAt = try action()
            // A fixed recording window includes bounce and a settled tail. It
            // does not judge speed; only Latency.swift does that. Drain often
            // so all display callbacks fit the bounded fixture socket buffer.
            for _ in 0..<Int(ceil(Double(max(140, duration) + 100) / 40)) {
                sleep(seconds: 0.04); _ = try drain()
            }
            try requireFinalState("the captured command's worked final state") { _ = try drain(); return try final() }
            let stopped = try drain("motionStop")
            try #require(stopped.motionFrameCount == samples.count, "capture must retain every delivered observer frame")
            try #require(samples.enumerated().allSatisfy { $0.element.frame == $0.offset + 1 }, "capture frame sequence must have no missing callbacks")
            try #require(samples.allSatisfy { $0.startedAt != nil && $0.sampledAt != nil }, "capture must bracket sequential AX reads in the raw clock")
            return Step(command: command, eventClock: discover ? "open request, CLOCK_MONOTONIC_RAW" : "fixture key postedAt, CLOCK_MONOTONIC_RAW",
                        postedAt: postedAt, samples: samples)
        }

        func key(_ code: Int, label: String, in journey: inout Journey,
                 frames: [UInt32: [Double]], focus: UInt32) throws {
            let ids = journey.windows
            do {
                journey.steps.append(try record(label, duration: journey.duration, ids: ids,
                    action: { try desktop.post(code) }, final: { try landed(frames, among: ids, focus: focus) }))
            } catch {
                let observed = try desktop.observe()
                throw HarnessError("\(journey.example) \(journey.duration) ms \(label): \(error); expected \(frames), focus \(focus); observed \(observed.windows.map { "\($0.id):\($0.frame) visible=\($0.visible) focus=\($0.focused)" })")
            }
        }

        @Test("#26 E21: fixture geometry filmstrips at 80 and 400 ms for owner review")
        func captureCarouselMotionForOwnerReview() throws {
            var journeys: [Journey] = []
            let directory = root.appending(path: ".build/captures/carousel")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let commit = try run(["git", "-C", root.path, "rev-parse", "HEAD"], timeout: margin, check: true).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = try harness.status().version
            let dirty = try !run(["git", "-C", root.path, "status", "--porcelain"], timeout: margin, check: true).output.isEmpty
            func save() throws {
                struct Artifact: Encodable {
                    let schemaVersion = 1
                    let reviewStatus = "pending owner review"
                    let measuredAt = ISO8601DateFormatter().string(from: Date())
                    let source = "Signed development app and independent signed AX/CG display-link observer; fixture windows only"
                    let sampling = "One observation per delivered NSScreen display callback; WindowServer CG bounds, with AX fallback when absent; raw-clock startedAt/sampledAt bracket reads; at is CADisplayLink.timestamp. Focus uses short AX queries. No interpolation or screenshots."
                    let commit: String
                    let appVersion: String
                    let workingTreeDirty: Bool
                    let operatingSystem: String
                    let journeys: [Journey]
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(Artifact(commit: commit, appVersion: version, workingTreeDirty: dirty,
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, journeys: journeys))
                try data.write(to: directory.appending(path: "carousel-motion.json"), options: .atomic)
                try Data(carouselCaptureHTML(data).utf8).write(to: directory.appending(path: "index.html"), options: .atomic)
            }
            defer { try? save() }
            for ms in [80, 400] {
                var scene = try prepare([0.5, 0.5, 0.5])
                var ids = scene.ids, half = scene.width(0.5)
                var journey = Journey(example: "E1", duration: ms, screen: scene.screen, area: scene.area, windows: ids)
                try duration(ms)
                for (code, label, camera, expanded, focus) in [
                    (kVK_ANSI_L, "L · [1 | 2], focus 2", 0.0, nil as Int?, 1),
                    (kVK_ANSI_L, "L · [2 | 3], focus 3", half + 10, nil, 2),
                    (kVK_ANSI_L, "L · expand 3", 0, 2, 2),
                    (kVK_ANSI_L, "L · right bounce", 0, 2, 2),
                    (kVK_ANSI_H, "H · [2 | 3], focus 2", half + 10, nil, 1),
                    (kVK_ANSI_H, "H · [1 | 2], focus 1", 0, nil, 0),
                    (kVK_ANSI_H, "H · expand 1", 0, 0, 0),
                    (kVK_ANSI_H, "H · left bounce", 0, 0, 0)] {
                    try key(code, label: label, in: &journey,
                        frames: scene.frames(ids, widths: Array(repeating: half, count: 3), camera: camera, expanded: expanded), focus: ids[focus])
                }
                journeys.append(journey); try save()

                let presets = [0.5, 1.0/3, 1.0/3, 1, 0.5]
                scene = try prepare(presets); ids = scene.ids
                let widths = presets.map(scene.width)
                var starts: [Double] = [], x = 0.0
                for w in widths { starts.append(x); x += w + 10 }
                try desktop.post(kVK_ANSI_L)
                try settle(scene.frames(ids, widths: widths), among: ids, focus: ids[1])
                try desktop.post(kVK_ANSI_L)
                try settle(scene.frames(ids, widths: widths, camera: starts[2] + widths[2] - scene.area[2]), among: ids, focus: ids[2])
                journey = Journey(example: "E3", duration: ms, screen: scene.screen, area: scene.area, windows: ids)
                try duration(ms)
                for (camera, focus, label) in [(starts[1], 2, "L · window 2 meets left edge"), (starts[2], 2, "L · window 3 meets left edge"),
                    (starts[3], 3, "L · window 4 complete"), (starts[4] + widths[4] - scene.area[2], 4, "L · window 5 meets right edge")] {
                    try key(kVK_ANSI_L, label: label, in: &journey, frames: scene.frames(ids, widths: widths, camera: camera), focus: ids[focus])
                }
                for label in ["L · expand 5", "L · right bounce"] {
                    try key(kVK_ANSI_L, label: label, in: &journey, frames: scene.frames(ids, widths: widths, expanded: 4), focus: ids[4])
                }
                journeys.append(journey); try save()

                scene = try prepare([1.0/3, 0.5, 1]); ids = scene.ids
                var cycleWidths = [1.0/3, 0.5, 1].map(scene.width)
                journey = Journey(example: "E7", duration: ms, screen: scene.screen, area: scene.area, windows: ids)
                try duration(ms)
                for (preset, label) in [(0.5, "R · expanded nominal third → half"), (2.0/3, "R · half → two thirds"),
                    (1.0, "R · two thirds → full"), (1.0/3, "R · full → third")] {
                    cycleWidths[0] = scene.width(preset)
                    try key(kVK_ANSI_R, label: label, in: &journey, frames: scene.frames(ids, widths: cycleWidths), focus: ids[0])
                }
                try key(kVK_ANSI_L, label: "L · focus complete window 2", in: &journey, frames: scene.frames(ids, widths: cycleWidths), focus: ids[1])
                cycleWidths[1] = scene.width(2.0/3)
                try key(kVK_ANSI_R, label: "R · window 2 grows with its left edge anchored", in: &journey, frames: scene.frames(ids, widths: cycleWidths), focus: ids[1])
                cycleWidths[1] = scene.width(1)
                try key(kVK_ANSI_R, label: "R · full width needs a minimal reveal", in: &journey,
                    frames: scene.frames(ids, widths: cycleWidths, camera: cycleWidths[0] + 10), focus: ids[1])
                journeys.append(journey); try save()

                scene = try prepare([0.5, 0.5]); ids = scene.ids; half = scene.width(0.5)
                try desktop.post(kVK_ANSI_L)
                try settle(scene.frames(ids, widths: [half, half]), among: ids, focus: ids[1])
                journey = Journey(example: "E10", duration: ms, screen: scene.screen, area: scene.area, windows: ids)
                try duration(ms)
                var newID: UInt32 = 0
                let arrival = try record("Open · [2 | new 3], focus 3", duration: ms, ids: ids, discover: true, action: {
                    let requested = monotonicSeconds()
                    newID = try fixture.open(kind: "heavyText", key: "w2", ["title": "Invented window 3"])
                    return requested
                }, final: {
                    try landed(scene.frames(ids + [newID], widths: [half, half, half], camera: half + 10), among: ids + [newID], focus: newID)
                })
                journey.windows.append(newID); journey.steps.append(arrival)
                try #require(arrival.samples.contains { $0.windows.contains { $0.id == newID && $0.valid } }, "the observer must discover the new fixture")
                journeys.append(journey); try save()

                scene = try prepare(Array(repeating: 0.5, count: 5)); ids = scene.ids; half = scene.width(0.5)
                let top = Array(ids.prefix(3)), bottom = Array(ids.suffix(2))
                try desktop.activate(key: "w3")
                try settle(scene.frames(ids, widths: Array(repeating: half, count: 5), camera: 2 * (half + 10)), among: ids, focus: ids[3])
                try desktop.post(kVK_ANSI_J, shift: true)
                try settle(scene.frames([ids[3]], widths: [scene.area[2]]), among: ids, focus: ids[3])
                try desktop.activate(key: "w4")
                try settle(scene.frames(top + [ids[4]], widths: Array(repeating: half, count: 4), camera: 2 * (half + 10)),
                    among: ids, focus: ids[4])
                try desktop.post(kVK_ANSI_J, shift: true)
                try settle(scene.frames(bottom, widths: [half, half]), among: ids, focus: ids[4])
                try desktop.post(kVK_ANSI_L)
                let bottomFrames = scene.frames(bottom, widths: [half, half], expanded: 1)
                try settle(bottomFrames, among: ids, focus: ids[4])
                let topFrames = scene.frames(top, widths: [half, half, half], camera: half + 10)
                try desktop.post(kVK_ANSI_K)
                try settle(topFrames, among: ids, focus: ids[2])
                try desktop.activate(key: "w0")
                try settle(scene.frames(top, widths: [half, half, half]), among: ids, focus: ids[0])
                try desktop.post(kVK_ANSI_L); try desktop.expectFocus(ids[1])
                try desktop.post(kVK_ANSI_L)
                try settle(topFrames, among: ids, focus: ids[2])
                journey = Journey(example: "E14", duration: ms, screen: scene.screen, area: scene.area, windows: ids)
                try duration(ms)
                for (code, label, frames, focus) in [(kVK_ANSI_J, "J · incoming card covers the remembered top pair", bottomFrames, ids[4]),
                    (kVK_ANSI_K, "K · leaving card uncovers [2 | 3]", topFrames, ids[2]), (kVK_ANSI_K, "K · top rail bounce", topFrames, ids[2]),
                    (kVK_ANSI_J, "J · expanded window 5 is remembered", bottomFrames, ids[4]), (kVK_ANSI_J, "J · bottom rail bounce", bottomFrames, ids[4])] {
                    try key(code, label: label, in: &journey, frames: frames, focus: focus)
                }
                journeys.append(journey); try save()
            }
            try #require(journeys.count == 10)
            print("Carousel E21 geometry capture: \(directory.appending(path: "index.html").path) — pending owner review")
        }
    }
}

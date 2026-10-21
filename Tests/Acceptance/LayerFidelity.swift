import Carbon
import Foundation

/// E30's selected prototype walkthroughs, driven through signed fixtures and
/// real Option-key events. Expected geometry comes from the accepted fractions
/// and rail presets; unchanged geometry is compared with the setup observation.
@MainActor
struct LayerFidelity {
    let desktop: Desktop
    let directory: URL
    var harness: Harness { desktop.harness }
    var fixture: FixtureSession { desktop.fixture }
    private var report = """
    # E30 — observed versus expected prototype fidelity

    Selected variants: U1 B, U2 B, U3 B, U4 A. Each walkthrough starts fresh.
    Frames are (x, y, width, height) as fractions of the usable area inside the
    outer gap. Rail widths include the accepted gap adjustment. Frame tolerance
    is one point; final states use the harness's shared 5 s margin.
    All layer/navigation/transfer actions use real keys. The prototype's external
    Cmd-Tab/click actions use signed fixture focus selection. No owner is needed.
    Wrap in all four directions, pinning a transferred tile, returning to its
    remembered neighbor, and a non-half nearest-width case extend the scripts.

    | Walkthrough / action | Focus expected → observed | Layer expected → observed | Visible floats expected → observed | Frames expected → observed | Result |
    | --- | --- | --- | --- | --- | --- |

    """

    init(desktop: Desktop, directory: URL) {
        self.desktop = desktop
        self.directory = directory
    }

    private struct Scene {
        var ids: [String: UInt32]
        let area: [Double]
        let floatFrames: [String: [Double]]
        let initialFrames: [String: [Double]]
        var floats: Set<String> { Set(floatFrames.keys) }

        func absolute(_ frame: [Double]) -> [Double] {
            [area[0] + frame[0] * area[2], area[1] + frame[1] * area[3], frame[2] * area[2], frame[3] * area[3]]
        }
        func fractions(_ frame: [Double]) -> [Double] {
            [(frame[0] - area[0]) / area[2], (frame[1] - area[1]) / area[3], frame[2] / area[2], frame[3] / area[3]]
        }
        func returning(_ preset: Double) -> [Double] {
            let width = (preset * (area[2] + 10) - 10) / area[2]
            return [1 - width, 0, width, 1]
        }
    }

    private func prepare() throws -> Scene {
        try desktop.clear()
        let screen = try desktop.observe().area
        let area = [screen[0] + 10, screen[1] + 10, screen[2] - 20, screen[3] - 20]
        var ids: [String: UInt32] = [:]
        // The prototype starts with three mixed-width tiles and two on a
        // second rail. Set exact preset widths before enabling management.
        for (i, preset) in [0.5, 1.0 / 3, 2.0 / 3, 0.5, 0.5].enumerated() {
            let key = "w\(i)"
            ids[key] = try fixture.open(key: key)
            try fixture.command("move", ["key": key, "frame": [area[0], area[1], preset * (area[2] + 10) - 10, area[3]]])
        }
        let frames = ["f0": [0.52, 0.08, 0.38, 0.48], "f1": [0.70, 0.20, 0.25, 0.65], "f2": [0.09, 0.50, 0.30, 0.40]]
        var scene = Scene(ids: ids, area: area, floatFrames: frames, initialFrames: [:])
        // Create floats while management is off. Ordinary carousel would
        // select each arrival and make the last one MRU before E30 starts.
        for (key, kind) in [("f0", "fixed"), ("f1", "normalPanel"), ("f2", "normalPanel")] {
            ids[key] = try fixture.open(kind: kind, key: key, ["background": true])
            try fixture.command("move", ["key": key, "frame": scene.absolute(frames[key]!)])
        }
        try requireFinalState("E30's floats reach the catalog in arrival order") { Set(try harness.rows().map(\.id)) == Set(ids.values) }
        try desktop.activate(key: "w0")
        try desktop.configure(desktop.carousel + "[animation]\nduration = 0\n", layout: "carousel")
        for key in ["w3", "w4"] {
            try desktop.activate(key: key)
            try desktop.post(kVK_ANSI_J, shift: true)
            try requireFinalState("E30 \(key) reaches the second rail") { try harness.row(ids[key]!)?.rail == 2 }
        }
        try desktop.activate(key: "w3") // The second rail remembers its first tile.
        try desktop.activate(key: "w0")
        try desktop.configure("[experiments]\nlayer = true\n[animation]\nduration = 0\n", layout: "carousel")
        try requireFinalState("E30 starts hidden on the first tile") {
            let observation = try desktop.observe(), layer = try harness.status().workspaces?.layer
            return desktop.focused(ids["w0"]!, in: observation) && layer?.state == "hidden" && layer?.focused == false
                && ["f0", "f1", "f2"].allSatisfy { !observation.visibleIDs.contains(ids[$0]!) }
        }
        scene = Scene(ids: ids, area: area, floatFrames: frames, initialFrames: [:])
        let observation = try desktop.observe()
        let initial = Dictionary(uniqueKeysWithValues: ids.keys.sorted().compactMap { key -> (String, [Double])? in
            observation.windows.first { $0.id == ids[key] }.map { (key, scene.fractions($0.frame)) }
        })
        return Scene(ids: ids, area: area, floatFrames: frames, initialFrames: initial.merging(frames) { _, requested in requested })
    }

    private mutating func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(report.utf8).write(to: directory.appending(path: "E30-fidelity.md"), options: .atomic)
    }

    private func describe(_ frames: [String: [Double]]) -> String {
        frames.keys.sorted().map { key in
            key + "=(" + frames[key]!.map { String(format: "%.4f", $0) }.joined(separator: ", ") + ")"
        }.joined(separator: "; ")
    }

    private mutating func check(_ label: String, _ scene: Scene, focus: String, state: String, inLayer: Bool,
                                visible: Set<String>, floating: Set<String>? = nil, frames: [String: [Double]]? = nil,
                                returned: String? = nil) throws {
        let floats = floating ?? scene.floats, expectedFrames = frames ?? scene.floatFrames
        var actualFocus = "unanswered", actualLayer = "unanswered", actualVisible = Set<String>(), actualFrames: [String: [Double]] = [:]
        let matched = try finalState {
            let observation = try desktop.observe(), layer = try harness.status().workspaces?.layer, rows = try harness.rows()
            actualFocus = scene.ids.keys.sorted().first { key in
                observation.windows.contains { $0.id == scene.ids[key] && $0.focused }
            } ?? "none"
            actualLayer = layer.map { "\($0.state)/\($0.focused)" } ?? "missing"
            actualVisible = Set(floats.filter { observation.visibleIDs.contains(scene.ids[$0]!) })
            actualFrames = Dictionary(uniqueKeysWithValues: expectedFrames.keys.sorted().compactMap { key -> (String, [Double])? in
                observation.windows.first { $0.id == scene.ids[key] }.map { (key, scene.fractions($0.frame)) }
            })
            let geometry = expectedFrames.allSatisfy { key, frame in
                observation.windows.first { $0.id == scene.ids[key] }.map { desktop.near($0.frame, scene.absolute(frame)) } == true
            }
            let classification = floats.allSatisfy { key in
                rows.contains { $0.id == scene.ids[key] && $0.state == "floats" && $0.rail == nil && $0.slot == nil }
            } && (returned.map { key in rows.contains { $0.id == scene.ids[key] && $0.state == "tiled" && $0.rail == 1 && $0.slot == 3 } } ?? true)
            return actualFocus == focus && observation.visibleIDs.contains(scene.ids[focus]!)
                && observation.frontmostFixturePID == fixture.pid && layer?.state == state && layer?.focused == inLayer
                && actualVisible == visible && geometry && classification
        }
        report += "| \(label) | \(focus) → \(actualFocus) | \(state)/\(inLayer) → \(actualLayer) | \(visible.sorted()) → \(actualVisible.sorted()) | \(describe(expectedFrames)) → \(describe(actualFrames)) | \(matched ? "PASS" : "FAIL") |\n"
        try save()
        guard matched else { throw HarnessError("E30 fidelity mismatch at \(label); see .work/captures/layer/E30-fidelity.md") }
    }

    private func openDialog(_ scene: inout Scene) throws {
        scene.ids["dialog"] = try fixture.open(kind: "dialog", key: "dialog")
        try fixture.command("move", ["key": "dialog", "frame": scene.absolute([0.33, 0.27, 0.34, 0.29])])
    }

    mutating func run() throws {
        try save() // A failed setup cannot leave a stale successful table.
        do {
            try visitLayer()
            try dialogs()
            try pinLayer()
            try transfer()
            try externalFocusAndFixedSize()
            report += "\nAll scripted walkthroughs and selected-variant extensions passed.\n"
            try save()
        } catch {
            report += "\nWalkthrough failed: \(error).\n"
            try save()
            throw error
        }
    }

    private mutating func visitLayer() throws {
        let scene = try prepare()
        try check("Visit / start", scene, focus: "w0", state: "hidden", inLayer: false, visible: [], frames: scene.initialFrames)
        try desktop.post(kVK_ANSI_Z)
        try check("Visit / alt-z", scene, focus: "f0", state: "shown", inLayer: true, visible: scene.floats, frames: scene.initialFrames)
        for (code, key, target) in [(kVK_ANSI_L, "l", "f1"), (kVK_ANSI_L, "l", "f2"), (kVK_ANSI_J, "j wraps", "f0"),
                                    (kVK_ANSI_H, "h wraps", "f2"), (kVK_ANSI_K, "k", "f1"), (kVK_ANSI_K, "k", "f0"),
                                    (kVK_ANSI_K, "k wraps", "f2"), (kVK_ANSI_L, "l wraps", "f0")] {
            try desktop.post(code)
            try check("Visit / alt-\(key)", scene, focus: target, state: "shown", inLayer: true, visible: scene.floats, frames: scene.initialFrames)
        }
        try desktop.post(kVK_ANSI_Z)
        try check("Visit / alt-z remembers tile", scene, focus: "w0", state: "hidden", inLayer: false, visible: [], frames: scene.initialFrames)
    }

    private mutating func dialogs() throws {
        var scene = try prepare()
        try desktop.post(kVK_ANSI_L)
        try check("Dialog appears / alt-l", scene, focus: "w1", state: "hidden", inLayer: false, visible: [])
        try openDialog(&scene)
        let frames = scene.floatFrames.merging(["dialog": [0.33, 0.27, 0.34, 0.29]]) { _, value in value }
        let floats = scene.floats.union(["dialog"])
        try check("Dialog appears / open", scene, focus: "dialog", state: "single", inLayer: true, visible: ["dialog"], floating: floats, frames: frames)
        try fixture.command("close", ["key": "dialog"])
        try check("Dialog appears / close", scene, focus: "w1", state: "hidden", inLayer: false, visible: [])

        scene = try prepare()
        try openDialog(&scene)
        try check("Dialog then explore / open", scene, focus: "dialog", state: "single", inLayer: true, visible: ["dialog"], floating: floats, frames: frames)
        try desktop.post(kVK_ANSI_H)
        try check("Dialog then explore / alt-h", scene, focus: "f2", state: "shown", inLayer: true, visible: floats, floating: floats, frames: frames)
        try desktop.post(kVK_ANSI_Z)
        try check("Dialog then explore / alt-z", scene, focus: "w0", state: "hidden", inLayer: false, visible: [], floating: floats, frames: frames)
    }

    private mutating func pinLayer() throws {
        let scene = try prepare()
        try desktop.post(kVK_ANSI_Z, shift: true)
        try check("Pin / alt-shift-z", scene, focus: "w0", state: "pinned", inLayer: false, visible: scene.floats)
        for (code, label, target, entered) in [(kVK_ANSI_L, "alt-l", "w1", false), (kVK_ANSI_L, "alt-l", "w2", false),
                                               (kVK_ANSI_Z, "alt-z enters", "f0", true), (kVK_ANSI_Z, "alt-z returns", "w2", false)] {
            try desktop.post(code)
            try check("Pin / \(label)", scene, focus: target, state: "pinned", inLayer: entered, visible: scene.floats)
        }
        try desktop.post(kVK_ANSI_Z, shift: true)
        try check("Pin / alt-shift-z hides", scene, focus: "w2", state: "hidden", inLayer: false, visible: [])
    }

    private mutating func transfer() throws {
        let scene = try prepare(), center = [0.25, 1.0 / 6, 0.5, 2.0 / 3]
        let floats = scene.floats.union(["w2"]), centered = scene.floatFrames.merging(["w2": center]) { _, value in value }
        try desktop.post(kVK_ANSI_L)
        try check("Transfer / first alt-l", scene, focus: "w1", state: "hidden", inLayer: false, visible: [])
        try desktop.post(kVK_ANSI_L)
        try check("Transfer / second alt-l", scene, focus: "w2", state: "hidden", inLayer: false, visible: [])
        try desktop.post(kVK_ANSI_F)
        try check("Transfer / alt-f centers at half × two-thirds", scene, focus: "w2", state: "shown", inLayer: true, visible: floats, floating: floats, frames: centered)
        try desktop.post(kVK_ANSI_Z, shift: true)
        try check("Transfer / alt-shift-z pins, does not move", scene, focus: "w2", state: "pinned", inLayer: true, visible: floats, floating: floats, frames: centered)
        try desktop.post(kVK_ANSI_Z)
        try check("Transfer / alt-z returns to left neighbor", scene, focus: "w1", state: "pinned", inLayer: false, visible: floats, floating: floats, frames: centered)
        try desktop.post(kVK_ANSI_Z)
        try check("Transfer / alt-z recalls moved float", scene, focus: "w2", state: "pinned", inLayer: true, visible: floats, floating: floats, frames: centered)
        try desktop.post(kVK_ANSI_Z, shift: true)
        try check("Transfer / unpin stays entered", scene, focus: "w2", state: "shown", inLayer: true, visible: floats, floating: floats, frames: centered)
        try desktop.post(kVK_ANSI_F)
        try check("Transfer / alt-f returns at nearest half", scene, focus: "w2", state: "hidden", inLayer: false, visible: [],
                  frames: scene.floatFrames.merging(["w2": scene.returning(0.5)]) { _, value in value }, returned: "w2")
        // Half would not distinguish U3 B from U3 A. Resize the floated tile
        // to 0.62 of the area, nearer two-thirds, before the second return.
        try desktop.post(kVK_ANSI_F)
        try check("Nearest width / alt-f", scene, focus: "w2", state: "shown", inLayer: true, visible: floats, floating: floats, frames: centered)
        let resized = [0.19, 1.0 / 6, 0.62, 2.0 / 3]
        try fixture.command("move", ["key": "w2", "frame": scene.absolute(resized)])
        try check("Nearest width / resize to 0.62", scene, focus: "w2", state: "shown", inLayer: true, visible: floats, floating: floats,
                  frames: scene.floatFrames.merging(["w2": resized]) { _, value in value })
        try desktop.post(kVK_ANSI_F)
        try check("Nearest width / alt-f chooses two-thirds", scene, focus: "w2", state: "hidden", inLayer: false, visible: [],
                  frames: scene.floatFrames.merging(["w2": scene.returning(2.0 / 3)]) { _, value in value }, returned: "w2")
    }

    private mutating func externalFocusAndFixedSize() throws {
        var scene = try prepare()
        try desktop.activate(key: "f0")
        try check("Mouse and Cmd-Tab / external float focus", scene, focus: "f0", state: "shown", inLayer: true, visible: scene.floats)
        try desktop.post(kVK_ANSI_L)
        try check("Mouse and Cmd-Tab / alt-l", scene, focus: "f1", state: "shown", inLayer: true, visible: scene.floats)
        try desktop.activate(key: "w1")
        try check("Mouse and Cmd-Tab / external tile focus", scene, focus: "w1", state: "hidden", inLayer: false, visible: [])

        scene = try prepare()
        try desktop.activate(key: "f0")
        try check("Fixed size / external float focus", scene, focus: "f0", state: "shown", inLayer: true, visible: scene.floats, frames: scene.initialFrames)
        try desktop.post(kVK_ANSI_F)
        try check("Fixed size / alt-f keeps the float", scene, focus: "f0", state: "shown", inLayer: true, visible: scene.floats, frames: scene.initialFrames)
    }
}

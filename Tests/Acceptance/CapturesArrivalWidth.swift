import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_ARRIVAL_WIDTH"] == "1", "owner review of full-width arrivals"))
    @MainActor struct ArrivalWidthCaptures {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }

        struct Capture: Encodable {
            let kind: String
            let window: UInt32
            let area: [Double]
            let expected: [Double]
            let observed: [Double]?
            let focused: Bool
            let matched: Bool
        }

        @Test("#49 E15: signed standard and 480-point maximum-width arrivals land left aligned")
        func captureNewWindowArrivalWidths() throws {
            let directory = root.appending(path: ".work/captures/arrival-width")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let commit = try run(["git", "-C", root.path, "rev-parse", "HEAD"], timeout: margin, check: true).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let dirty = try !run(["git", "-C", root.path, "status", "--porcelain"], timeout: margin, check: true).output.isEmpty
            let version = try harness.status().version
            var captures: [Capture] = []

            func save() throws {
                struct Artifact: Encodable {
                    let example = "#49 E15"
                    let reviewStatus = "pending owner review"
                    let source = "Signed development app and independent signed AX/CG observer; fixture windows only"
                    let measuredAt = ISO8601DateFormatter().string(from: Date())
                    let commit: String
                    let workingTreeDirty: Bool
                    let appVersion: String
                    let captures: [Capture]
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(Artifact(commit: commit, workingTreeDirty: dirty, appVersion: version, captures: captures))
                    .write(to: directory.appending(path: "arrival-width.json"), options: .atomic)
                let panels = captures.map { capture in
                    let frame = capture.observed
                    let rectangle = frame.map {
                        "<rect x='\($0[0] - capture.area[0])' y='\($0[1] - capture.area[1])' width='\($0[2])' height='\($0[3])' fill='#6495ed'/>"
                    } ?? ""
                    return """
                    <section><h2>\(capture.kind)</h2>
                    <p>Expected: \(capture.expected). Observed: \(frame.map(String.init(describing:)) ?? "absent").
                    Focused: \(capture.focused). Matched: \(capture.matched).</p>
                    <svg viewBox="0 0 \(capture.area[2]) \(capture.area[3])" role="img" aria-label="Observed fixture geometry inside the rail area">
                    <rect width="100%" height="100%" fill="#e8edf3"/>\(rectangle)</svg></section>
                    """
                }.joined(separator: "\n")
                let html = """
                <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                <title>#49 E15 arrival widths</title>
                <style>body{font:16px system-ui;max-width:1000px;margin:32px auto;padding:0 20px;color:#182331}section{margin:32px 0}svg{display:block;width:100%;max-height:420px}p{overflow-wrap:anywhere}</style>
                <h1>#49 E15: new window arrival widths</h1><p>Independent native geometry from signed fixtures. Pending owner review.</p>
                \(panels)</html>
                """
                try Data(html.utf8).write(to: directory.appending(path: "index.html"), options: .atomic)
            }
            defer { try? save() }

            for kind in ["standard", "maxWidth"] {
                // Keep tessel running while opening each window: startup
                // windows retain observed widths and do not prove arrivals.
                try desktop.clear()
                try desktop.configure("[animation]\nduration = 0\n", layout: "carousel")
                let visible = try desktop.observe().area
                let area = [visible[0] + 10, visible[1] + 10, visible[2] - 20, visible[3] - 20]
                try #require(area[2] > 480, "the rail area must exceed the fixture's maximum")
                let expected = [area[0], area[1], kind == "maxWidth" ? 480 : area[2], area[3]]
                let id = try fixture.open(kind: kind, key: "arrival", ["title": "Invented arrival window"])
                var last: Observation?
                let matched = try finalState {
                    let observation = try desktop.observe(); last = observation
                    let inRail = try harness.row(id)?.rail == 1
                    return desktop.focused(id, in: observation)
                        && observation.windows.contains { $0.id == id && desktop.near($0.frame, expected) }
                        && inRail
                }
                captures.append(Capture(kind: kind, window: id, area: area, expected: expected,
                                        observed: last?.windows.first { $0.id == id }?.frame,
                                        focused: last.map { desktop.focused(id, in: $0) } ?? false, matched: matched))
                try save()
                try #require(matched, "\(kind) must land at \(expected); native geometry saved in \(directory.path)")
            }
            print("#49 E15 arrival geometry capture: \(directory.appending(path: "index.html").path) — pending owner review")
        }
    }
}

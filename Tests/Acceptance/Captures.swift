import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CAPTURE_WORKSPACES"] == "1", "owner review captures"))
    @MainActor
    struct Captures {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }

        init() throws { try desktop.clear() }

        func copyCapture(_ name: String) throws {
            let source = harness.configFile.deletingLastPathComponent().appending(path: "ui-captures/" + name + ".png")
            let png = try #require(finalValue { () -> Data? in
                guard let data = FileManager.default.contents(atPath: source.path),
                      data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { return nil }
                return data
            }, "the running development app must export its own rendered view")
            let directory = root.appending(path: ".work/captures")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appending(path: name + ".png"), options: .atomic)
        }

        @Test("#2 E37: workspace menu capture")
        func captureWorkspaceMenuForOwnerReview() throws {
            let (a, b) = try desktop.split()
            try desktop.expectShown(a)
            try desktop.expectMenu("Workspace 1")
            try copyCapture("E37-workspace-1")
            try desktop.key(2)
            try desktop.expectShown(b)
            try desktop.expectMenu("Workspace 2")
            try copyCapture("E37-workspace-2")
            try desktop.writeConfig("")
            try requireFinalState("workspaces disabled for menu capture") { try harness.status().workspaces?.enabled == false }
            try harness.observer.command("menu", ["pid": harness.appPID, "open": true, "keepOpen": true])
            defer { _ = try? harness.observer.command("menu", ["pid": harness.appPID, "open": true, "press": false]) }
            try requireFinalState("the disabled workspace menu open for capture") {
                try harness.observer.command("menu", ["pid": harness.appPID, "open": true, "press": false,
                    "keepOpen": true, "expected": "experiment off"]).menuContains == true
            }
            try copyCapture("E37-disabled-menu")
            harness.stopApp()
            try harness.startApp()
        }

        @Test("rails status item capture")
        func captureRailsStatusItem() throws {
            let ids = try desktop.railSetup([0.3, 0.3, 0.3])
            try desktop.post(38, shift: true)
            try desktop.expectFocus(ids[0])
            try desktop.post(40)
            // The upper rail remembers the departed tile's right neighbor.
            try desktop.expectFocus(ids[1])
            for (rail, code) in [(2, 38), (1, 40)] {
                let name = "E26-workspace-1-rail-\(rail)"
                let source = harness.configFile.deletingLastPathComponent().appending(path: "ui-captures/" + name + ".png")
                try? FileManager.default.removeItem(at: source)
                try desktop.post(code)
                try desktop.expectMenu("Workspace 1, rail \(rail) of 2")
                try copyCapture(name)
            }
        }
    }
}

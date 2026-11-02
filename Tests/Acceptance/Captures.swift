import ApplicationServices
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
            harness.stopApp()
            try harness.startApp()
        }

        @Test("#67 E14: restart menu captures in enabled and disabled states")
        func captureRestartMenuForOwnerReview() throws {
            for enabled in [true, false] {
                harness.stopApp()
                try harness.startApp(fixtureReady: false, arguments: enabled ? [] : ["--test-missing-skylight"])
                try requireFinalState("workspaces \(enabled ? "enabled" : "disabled") for the menu capture") {
                    try harness.status().workspaces?.enabled == enabled
                }
                let pid = harness.appPID
                try harness.observer.command("menu", ["pid": pid, "open": true, "keepOpen": true])
                defer { _ = try? harness.observer.command("menu", ["pid": pid, "open": true, "press": false]) }
                var last: FixtureReply?
                let reply = try #require(finalValue { () throws -> FixtureReply? in
                    let reply = try harness.observer.command("menu", ["pid": pid, "open": true, "press": false,
                        "keepOpen": true, "readItems": true])
                    last = reply
                    return reply.menuTitles?.contains("Quit Tessel") == true && reply.restartKeyEquivalentError != nil ? reply : nil
                }, "the observer must read the open menu's titles and Restart's AXMenuItemCmdChar; last titles: \(last?.menuTitles ?? []), AX result: \(String(reflecting: last?.restartKeyEquivalentError))")
                let titles = try #require(reply.menuTitles)
                let keyError = try #require(reply.restartKeyEquivalentError)
                try #require(Array(titles.suffix(2)) == ["Restart Tessel", "Quit Tessel"])
                try #require(keyError == AXError.noValue.rawValue
                    || keyError == AXError.success.rawValue && reply.restartKeyEquivalent == "")
                let name = enabled ? "E14-enabled-menu" : "E14-disabled-menu"
                try copyCapture(name)
                let keyEquivalent = reply.restartKeyEquivalent.map { String(reflecting: $0) } ?? "<no value> (AXError.noValue)"
                let dump = titles.joined(separator: "\n") + "\n\nRestart Tessel AXMenuItemCmdChar: \(keyEquivalent)\n"
                try Data(dump.utf8).write(to: root.appending(path: ".work/captures/" + name + ".txt"), options: .atomic)
            }
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

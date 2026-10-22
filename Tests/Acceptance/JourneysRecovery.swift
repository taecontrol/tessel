import Carbon
import CoreGraphics
import Darwin
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("crash and quit journey")
    func crashAndQuit() throws {
        try step("#2 E28 quit returns managed windows and releases hotkeys") {
            let (a, b) = try desktop.split()
            harness.stopApp()
            try desktop.expectInside([a, b])
            try desktop.activate(key: "a")
            try desktop.expectPassedKey(kVK_ANSI_1)
            let status = try harness.invoke("status", "--json")
            try #require(status.status != 0 && status.error.contains("tessel is not running"))
        }
        try step("#2 E29 crash recovery returns orphans after a successful AX enumeration") {
            do {
                try desktop.clear()
                let (a, b) = try desktop.split()
                try #require(try !desktop.visible(b))
                kill(harness.appPID, SIGKILL)
                try requireFinalState("the crashed app exited") { !harness.appIsRunning }
                try harness.startApp(fixtureReady: false)
                try requireFinalState("both recovered fixtures assigned to workspace 1") {
                    let rows = try harness.rows()
                    return [a, b].allSatisfy { id in rows.contains { $0.id == id && $0.workspace == 1 } }
                }
                let current = try #require(try finalValue {
                    try desktop.observe(focusedOnly: true).windows.first { $0.main && $0.focused && $0.visible }?.id
                })
                try desktop.post(current == a ? kVK_ANSI_L : kVK_ANSI_H)
                try desktop.expectShown(current == a ? b : a)
            }
            try desktop.clear()
            let (a, b) = try desktop.split()
            kill(harness.appPID, SIGKILL)
            try requireFinalState("the app exited before blocked-AX recovery") { !harness.appIsRunning }
            try desktop.writeConfig("")
            kill(fixture.pid, SIGSTOP)
            do {
                defer { kill(fixture.pid, SIGCONT) }
                try harness.startApp(fixtureReady: false)
                try requireFinalState("startup has no successful fixture enumeration") { try harness.rows().isEmpty }
                guard let listing = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
                    throw HarnessError("cannot read fixture visibility while AX is blocked")
                }
                let orphanVisible = listing.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == b }
                try #require(!orphanVisible, "recovery must not show an orphan before the first successful AX enumeration")
            }
            try requireFinalState("the orphan catalogued after AX resumes") { try harness.row(b) != nil }
            for (key, id) in [("a", a), ("b", b)] { try desktop.activate(key: key); try desktop.expectFocus(id) }
        }
        try step("rail quit and crash preserve managed windows") {
            for crash in [false, true] {
                try desktop.clear()
                let ids = try desktop.railSetup([0.6, 0.6, 0.6, 0.6], duration: 0)
                if crash {
                    kill(harness.appPID, SIGKILL)
                    try requireFinalState("the crashed process exits") { !harness.appIsRunning }
                    try harness.startApp(fixtureReady: false)
                    for (index, id) in ids.enumerated() { try desktop.activate(key: "w\(index)"); try desktop.expectFocus(id) }
                } else { harness.stopApp(); try desktop.expectInside(ids) }
            }
        }
        try step("#2 E34 missing SkyLight and failed hide disable safely; test arguments stay private") {
            for failure in ["--test-missing-skylight", "--test-failed-hide"] {
                try desktop.clear()
                harness.stopApp()
                let ids = try [fixture.open(key: "a"), fixture.open(key: "b")]
                try desktop.activate(key: "b")
                let frame = try #require(try desktop.window(ids[1])).frame
                try desktop.writeConfig(desktop.carousel)
                try harness.startApp(fixtureReady: false, arguments: [failure])
                try requireFinalState("the unavailable hiding mechanism reported") {
                    let status = try harness.status().workspaces
                    return status?.enabled == false && status?.reason.lowercased().contains("skylight") == true
                }
                try desktop.expectInside(ids)
                if failure == "--test-missing-skylight" {
                    try #require(try desktop.window(ids[1])?.frame == frame)
                    try desktop.expectMenu(try #require(try harness.status().workspaces).reason, open: true)
                }
                try desktop.activate(key: "b")
                try desktop.expectPassedKey(kVK_ANSI_1)
            }
            for argument in ["--test-missing-skylight", "--test-failed-hide", "--test-capture-ui"] {
                try #require(try run([appExecutable.path, "--check-permission", argument], timeout: margin).status == 2)
            }
            try #require(try run([appExecutable.path, "--check-permission", "--test-fixture-only", "--test-unknown"], timeout: margin).status == 2)
            let output = root.appending(path: ".work/daily-journey-arguments")
            defer { try? FileManager.default.removeItem(at: output) }
            try run([buildTool.path, "--variant", "daily", "--output-dir", output.path], timeout: 600, check: true)
            let executable = output.appending(path: "Tessel.app/Contents/MacOS/TesselApp")
            for argument in ["--test-fixture-only", "--test-missing-skylight", "--test-failed-hide", "--test-capture-ui"] {
                // Exit before AppKit starts even if an argument guard regresses.
                try #require(try run([executable.path, "--check-permission", argument], timeout: margin).status == 2)
            }
        }
    }
}

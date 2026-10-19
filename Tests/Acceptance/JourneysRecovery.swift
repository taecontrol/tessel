import Carbon
import CoreGraphics
import Darwin
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("crash, quit and disable journey")
    func crashQuitAndDisable() throws {
        try step("#2 E28 disable and quit return managed windows and release hotkeys") {
            for quit in [false, true] {
                try desktop.clear()
                let (a, b) = try desktop.split()
                if quit { harness.stopApp() }
                else {
                    try desktop.writeConfig("")
                    try requireFinalState("workspace disablement") { try harness.status().workspaces?.enabled == false }
                }
                try desktop.expectInside([a, b])
                try desktop.activate(key: "a")
                try desktop.expectPassedKey(kVK_ANSI_1)
                if quit {
                    let status = try harness.invoke("status", "--json")
                    try #require(status.status != 0 && status.error.contains("tessel is not running"))
                }
            }
        }
        try step("#2 E29 crash recovery returns orphans after a successful AX enumeration") {
            for enabled in [true, false] {
                try desktop.clear()
                let (a, b) = try desktop.split()
                try #require(try !desktop.visible(b))
                kill(harness.appPID, SIGKILL)
                try requireFinalState("the crashed app exited") { !harness.appIsRunning }
                if !enabled { try desktop.writeConfig("") }
                try harness.startApp(fixtureReady: false)
                if enabled {
                    try requireFinalState("both recovered fixtures assigned to workspace 1") {
                        let rows = try harness.rows()
                        return [a, b].allSatisfy { id in rows.contains { $0.id == id && $0.workspace == 1 } }
                    }
                    let current = try #require(try finalValue {
                        try desktop.observe(focusedOnly: true).windows.first { $0.main && $0.focused && $0.visible }?.id
                    })
                    try desktop.post(kVK_ANSI_J)
                    try desktop.expectShown(current == a ? b : a)
                } else { try desktop.expectInside([a, b]) }
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
            try desktop.expectInside([a, b])
        }
        try step("rail disable, quit, crash and failed hide return managed windows") {
            for operation in ["disable", "quit", "stack-disable", "stack-quit", "crash-off", "crash-on", "failed-hide"] {
                print("Rail cleanup: \(operation)")
                try desktop.clear()
                let ids: [UInt32]
                if operation == "failed-hide" {
                    harness.stopApp()
                    ids = try (0..<4).map { try fixture.open(key: "w\($0)", ["widthFraction": 0.6]) }
                    try desktop.activate(key: "w0")
                    try desktop.writeConfig(desktop.carousel)
                    try harness.startApp(fixtureReady: false, arguments: ["--test-failed-hide"])
                    try requireFinalState("safe disablement after a failed rail hide") {
                        let status = try harness.status().workspaces
                        return status?.enabled == false && status?.reason == "SkyLight could not hide a window"
                    }
                } else {
                    // Three 60% windows can all remain partially visible after a scroll.
                    ids = try desktop.railSetup([0.6, 0.6, 0.6, 0.6])
                    try desktop.post(kVK_ANSI_L)
                    try desktop.expectFocus(ids[1])
                    try requireFinalState("a rail fixture hidden in the closet before cleanup") {
                        let visible = try desktop.observe(focusedOnly: true).visibleIDs
                        return ids.contains { !visible.contains($0) }
                    }
                    if operation.hasPrefix("stack-") { try desktop.configure(desktop.stack, layout: "stack") }
                    switch operation {
                    case "disable", "stack-disable":
                        try desktop.writeConfig("")
                        try requireFinalState("rail disablement") { try harness.status().workspaces?.enabled == false }
                    case "quit", "stack-quit": harness.stopApp()
                    default:
                        kill(harness.appPID, SIGKILL)
                        try requireFinalState("the rail app exited after a crash") { !harness.appIsRunning }
                        if operation == "crash-off" { try desktop.writeConfig("") }
                        try harness.startApp(fixtureReady: false)
                    }
                }
                if operation == "crash-on" {
                    for (index, id) in ids.enumerated() {
                        try desktop.activate(key: "w\(index)")
                        try desktop.expectFocus(id)
                    }
                } else if operation == "crash-off" {
                    // With no persisted membership, recovery can only return
                    // closet windows; a former partial peek stays where it was.
                    try requireFinalState("all crashed rail fixtures back from the closet") {
                        let visible = try desktop.observe(focusedOnly: true).visibleIDs
                        return ids.allSatisfy(visible.contains)
                    }
                } else {
                    try desktop.expectInside(ids)
                    try desktop.activate(key: "w0")
                    try desktop.expectPassedKey(kVK_ANSI_L)
                }
            }
        }
        try step("#2 E34 missing SkyLight and failed hide disable safely; test arguments stay private") {
            for failure in ["--test-missing-skylight", "--test-failed-hide"] {
                try desktop.clear()
                harness.stopApp()
                let ids = try [fixture.open(key: "a"), fixture.open(key: "b")]
                try desktop.activate(key: "b")
                let frame = try #require(try desktop.window(ids[1])).frame
                try desktop.writeConfig(desktop.stack)
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

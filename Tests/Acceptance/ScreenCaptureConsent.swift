import Carbon
import CoreGraphics
import Darwin
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession(), .enabled(if: ProcessInfo.processInfo.environment["TESSEL_SCREEN_CAPTURE_CONSENT"] == "1"
        && ProcessInfo.processInfo.environment["CI"] != "true", "interactive screen-capture consent outside CI only"))
    @MainActor
    struct ScreenCaptureConsent {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }

        @Test("record ScreenCaptureKit acknowledgements and prove they survive process restarts")
        func screenCaptureConsent() throws {
            guard try !acknowledgementPending() else {
                throw HarnessError("A system alert was already on screen; settle it before running screen-capture consent")
            }
            try desktop.clear()
            try capture(for: "Tessel Dev") { try captureCarouselMove() }
            try desktop.clear()
            let previousApp = harness.appPID
            harness.stopApp()
            guard kill(previousApp, 0) != 0 else { throw HarnessError("Tessel Dev did not quit before its consent check") }
            try harness.startApp()
            guard harness.appPID != previousApp else { throw HarnessError("Tessel Dev did not relaunch before its consent check") }
            try capture(for: "Tessel Dev", afterRestart: true) { try captureCarouselMove() }

            // Default layout keeps the app alive without further stage captures
            // while the independent observer acknowledges its own identity.
            try desktop.clear()
            let id = try harness.fixture.open()
            try desktop.activate()
            try capture(for: "Tessel Fixture") { try captureWholeWindow(id) }
            let previousObserver = harness.observer.pid, previousFixture = harness.fixture.pid
            harness.observer.stop()
            harness.fixture.stop()
            guard kill(previousObserver, 0) != 0, kill(previousFixture, 0) != 0 else {
                throw HarnessError("Tessel Fixture did not quit before its consent check")
            }
            harness.fixture = try FixtureSession(directory: harness.directory, number: 0)
            harness.observer = try FixtureSession(directory: harness.directory, number: 999)
            guard harness.observer.pid != previousObserver else { throw HarnessError("Tessel Fixture did not relaunch before its consent check") }
            let relaunchedID = try harness.fixture.open()
            try desktop.activate()
            try capture(for: "Tessel Fixture", afterRestart: true) { try captureWholeWindow(relaunchedID) }
        }

        private func captureCarouselMove() throws {
            // Setup is instant so only the explicit move below requests captures.
            _ = try desktop.railSetup([0.6, 0.6], duration: 0)
            try desktop.configure(desktop.carousel + "[animation]\nduration = 400\n", layout: "carousel")
            guard try harness.status().workspaces?.motion == "on" else {
                throw HarnessError("Grant Screen Recording to Tessel Dev before preparing capture consent")
            }
            let before = try harness.stageWork()
            try desktop.post(kVK_ANSI_L)
            // Capture instrumentation advances after ScreenCaptureKit returns
            // pixels; focus may already belong to the acknowledgement alert.
            try requireFinalState("Tessel Dev completes a real stage capture") { try harness.stageWork() > before }
        }

        private func captureWholeWindow(_ id: UInt32) throws {
            // The observer captures only windows whose AX handles a snapshot retained.
            try requireFinalState("the observer retains the fixture window's handle") {
                let state = try harness.observer.command("contract", ["operation": "snapshot", "pid": harness.fixture.pid]).contract
                return state?.roots.contains { $0.id == id && $0.roleError == 0 } == true
            }
            let facts = try harness.observer.command("contract", ["operation": "stageCapture", "pid": harness.fixture.pid, "id": id]).contract?.stage
            guard let size = facts?.captureSize, size.count == 2, size.allSatisfy({ $0 > 0 }), (facts?.opaque ?? 0) > 0.9 else {
                throw HarnessError("Tessel Fixture did not return a real whole-window capture")
            }
        }

        private func capture(for identity: String, afterRestart: Bool = false, _ trigger: () throws -> Void) throws {
            say("\(identity): \(afterRestart ? "checking consent after restart" : "preparing screen-capture consent"). If its acknowledgement appears, click Allow. Keep this run open.")
            var captureError: Error?
            do { try trigger() } catch { captureError = error }
            // The acknowledgement arrives after a successful capture. Watch for
            // the entire generous margin even when the capture has returned.
            let appeared = try finalState {
                try requireProcessesAlive()
                return try acknowledgementPending()
            } || acknowledgementPending()
            if appeared {
                if afterRestart { say("alert reappeared: consent not recorded for \(identity)") }
                say("\(identity): acknowledgement pending; click Allow. Waiting up to 120 s.")
                // Also settle a failed persistence check before cleanup can
                // terminate its requesting process and turn the answer into refusal.
                try awaitAcknowledgement(for: identity)
                if afterRestart { throw HarnessError("alert reappeared: consent not recorded for \(identity)") }
            } else if !afterRestart, captureError == nil {
                say("\(identity): no acknowledgement alert appeared (already approved)")
            }
            if let captureError { throw captureError }
            if afterRestart { say("consent recorded for \(identity)") }
        }

        private func awaitAcknowledgement(for identity: String) throws {
            // This is a human response window, not an app-state deadline. The
            // owner has up to 120 s to answer; retain both processes for another
            // 2 s of continuous absence so replayd can record the acknowledgement.
            let responseStarted = monotonicSeconds()
            var absentSince: Double?
            while true {
                try requireProcessesAlive()
                let now = monotonicSeconds()
                if try acknowledgementPending() {
                    absentSince = nil
                    guard now - responseStarted < 120 else {
                        throw HarnessError("\(identity): acknowledgement timed out after 120 s; consent not recorded")
                    }
                } else if let absentSince {
                    if now - absentSince >= 2 { return }
                } else {
                    absentSince = now
                }
                sleep(seconds: 0.05)
            }
        }

        private func requireProcessesAlive() throws {
            guard kill(harness.appPID, 0) == 0, kill(harness.observer.pid, 0) == 0, kill(harness.fixture.pid, 0) == 0 else {
                throw HarnessError("A capture process exited before consent could be recorded; rerun screen-capture consent")
            }
        }

        private func acknowledgementPending() throws -> Bool {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                throw HarnessError("Cannot check whether the system acknowledgement alert is on screen")
            }
            // Read only the owner, then layer and bounds of the system alert
            // process. Never inspect titles or other applications' window data.
            return windows.contains { window in
                guard window[kCGWindowOwnerName as String] as? String == "UserNotificationCenter",
                      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 8,
                      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
                return !frame.isEmpty
            }
        }

        private func say(_ message: String) {
            print(message)
            fflush(nil)
        }
    }
}

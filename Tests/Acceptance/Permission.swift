import Darwin
import Foundation
import Testing

extension Acceptance {
    /// Denial and automatic restart. Locally, grant Accessibility through System Settings instead.
    @Suite(.enabled(if: onDisposableRunner, "changes the Accessibility database of a disposable GitHub runner only"))
    struct Permission {
        @Test func e13ReportsMissingPermissionAndE14RestartsWhenGranted() throws {
            let home = FileManager.default.temporaryDirectory.appending(path: "tessel-permission-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            var environment = ProcessInfo.processInfo.environment
            environment["XDG_CONFIG_HOME"] = home.path
            var pids: Set<pid_t> = []
            defer {
                for pid in pids { kill(pid, SIGTERM) }
                sleep(seconds: 0.1)
                try? FileManager.default.removeItem(at: home)
            }

            func status() throws -> Status? {
                let result = try run([cli.path, "status", "--json"], environment: environment, timeout: 1.2)
                guard result.status == 0 else { return nil }
                let value = try JSONDecoder().decode(Status.self, from: result.outputData)
                pids.insert(value.pid)
                return value
            }

            func wait(seconds: Double, for predicate: (Status) -> Bool) throws -> Status {
                let deadline = monotonicSeconds() + seconds
                while monotonicSeconds() < deadline {
                    if let value = try status(), predicate(value) { return value }
                    sleep(seconds: 0.025)
                }
                throw HarnessError("permission state did not converge within the deadline")
            }

            let provision = root.appending(path: "scripts/ci-accessibility").path
            try run([provision, "--deny-development"], timeout: 30, check: true)
            try run(["open", "-n", "-g", "--stdout", "/dev/null", "--stderr", "/dev/null",
                     "--env", "XDG_CONFIG_HOME=" + home.path, app.path], check: true)
            let initial = try wait(seconds: 5) { $0.permission == "needed" }
            let windows = try run([cli.path, "windows", "--json"], environment: environment, timeout: 1)
            #expect(windows.status != 0)
            #expect(windows.error.contains("Accessibility permission needed"))
            print("E13: missing permission is reported by status and windows; visual evidence is separate.")

            let started = monotonicSeconds()
            try run([provision], timeout: 30, check: true)
            _ = try wait(seconds: 3) { $0.permission == "granted" && $0.pid != initial.pid }
            let elapsed = monotonicSeconds() - started
            #expect(elapsed < 3)
            print(String(format: "E14: automatic restart with permission granted in %.3f s; visual evidence is separate.", elapsed))
        }
    }
}

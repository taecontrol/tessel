import Darwin
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("signing and permission journey")
    func signingAndPermission() throws {
        try step("#1 E16 signing requires an exact available identity and rejects ad-hoc values") {
            for identity in [nil, "", "-", "adhoc", "Ad-Hoc", "Sign to run locally", "Unavailable fixture signing identity"] as [String?] {
                let config = harness.directory.appending(path: "NoIdentity.local.xcconfig")
                try? FileManager.default.removeItem(at: config)
                if let identity { try Data("CODE_SIGN_IDENTITY = \(identity)\n".utf8).write(to: config) }
                let output = harness.directory.appending(path: "unsigned-output-" + UUID().uuidString)
                let result = try run([buildTool.path, "--signing-config", config.path, "--output-dir", output.path], timeout: margin)
                try #require(result.status != 0 && result.error.contains("docs/development.md"))
                if identity != "Unavailable fixture signing identity" { try #require(result.error.contains("Signing.local.xcconfig")) }
                try #require(!FileManager.default.fileExists(atPath: output.path))
            }
            // Stand-ins stop before a compiler or signer can create a bundle.
            let shims = harness.directory.appending(path: "signing-tools")
            try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: false)
            let marker = harness.directory.appending(path: "signing-command-reached")
            let fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567"
            let name = "Generic Contract Signing Identity"
            let listing = "  1) \(fingerprint) \"\(name)\"\n     1 valid identities found\n"
            let commands = [
                "security": "#!/bin/sh\ncat <<'IDENTITIES'\n" + listing + "IDENTITIES\n",
                "xcrun": "#!/bin/sh\nprintf compiler > \"$TESSEL_SIGNING_PROBE\"\nexit 91\n",
                "codesign": "#!/bin/sh\nprintf signer > \"$TESSEL_SIGNING_PROBE\"\nexit 92\n",
            ]
            for (command, body) in commands {
                FileManager.default.createFile(atPath: shims.appending(path: command).path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o755])
            }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = shims.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["TESSEL_SIGNING_PROBE"] = marker.path
            let invalid = ["CODE_SIGN_IDENTITY = \t \n", "CODE_SIGN_IDENTITY = \"  \t \"\n",
                "CODE_SIGN_IDENTITY = \nOTHER_SETTING = ignored\n", "CODE_SIGN_IDENTITY = Contract Signing\n",
                "CODE_SIGN_IDENTITY = " + fingerprint.prefix(20) + "\n"]
            let valid = ["CODE_SIGN_IDENTITY = \"\(name)\"\n", "CODE_SIGN_IDENTITY = " + fingerprint.lowercased() + "\n"]
            for (index, text) in (invalid + valid).enumerated() {
                try? FileManager.default.removeItem(at: marker)
                let config = harness.directory.appending(path: "GenericIdentity.local.xcconfig")
                try Data(text.utf8).write(to: config)
                let output = harness.directory.appending(path: "signing-output-\(index)")
                let result = try run([buildTool.path, "--signing-config", config.path, "--output-dir", output.path], environment: environment, timeout: margin)
                let reached = try? String(contentsOf: marker, encoding: .utf8)
                try #require(result.status != 0, "the stand-in compiler must prevent a build")
                if index < invalid.count {
                    try #require(reached == nil && !FileManager.default.fileExists(atPath: output.path), "an invalid identity must not reach compilation")
                    try #require(result.error.contains("docs/development.md"))
                } else {
                    try #require(reached == "compiler", "an exact identity must reach compilation, never signing")
                    let bundles = (try? FileManager.default.contentsOfDirectory(atPath: output.path))?.filter { $0.hasSuffix(".app") } ?? []
                    try #require(bundles.isEmpty)
                }
            }
        }
        try step("#1 E15 a signed rebuild preserves Accessibility") {
            let before = try harness.status()
            try #require(before.permission == "granted")
            let window = try fixture.open()
            try requireFinalState("a fixture observed before the signed rebuild") { try harness.row(window)?.state == "tiled" }
            harness.stopApp()
            // Invoke the already-built tool: SwiftPM is locked by this test run.
            try run([buildTool.path], timeout: 600, check: true)
            try harness.startApp(fixtureReady: false)
            let after = try harness.status()
            try #require(after.version != before.version, "the rebuild must change the signed binary")
            try #require(after.permission == "granted")
            try requireFinalState("the same fixture observed after rebuilding") { try harness.row(window)?.state == "tiled" }
        }
    }

    @Test("permission steps of the signing and permission journey",
          .enabled(if: onDisposableRunner, "changes the Accessibility database of a disposable GitHub runner only"))
    func permissionDenialAndRestart() throws {
        let provision = root.appending(path: "scripts/ci-accessibility").path
        var initialPID: pid_t = 0
        try step("#1 E13 missing Accessibility permission is reported") {
            harness.stopApp()
            try run([provision, "--deny-development"], timeout: 30, check: true)
            try harness.startApp(fixtureReady: false)
            try requireFinalState("permission denial reported by status") { try harness.status().permission == "needed" }
            initialPID = try harness.status().pid
            let result = try harness.invoke("windows", "--json")
            try #require(result.status != 0 && result.error.contains("Accessibility permission needed"))
            try desktop.expectMenu("Accessibility permission needed", open: true)
            try desktop.expectMenu("Open Accessibility Settings…", open: true)
        }
        try step("granting Accessibility relaunches the app (wiring, CI runner only)") {
            try run([provision], timeout: 30, check: true)
            let status = try finalValue { () throws -> Status? in
                do {
                    let result = try harness.invoke("status", "--json")
                    guard result.status == 0 else { return nil }
                    let status = try JSONDecoder().decode(Status.self, from: result.outputData)
                    return status.permission == "granted" && status.pid != initialPID ? status : nil
                } catch is ProcessTimeout { return nil }
            }
            let granted = try #require(status, "a fresh process must report Accessibility granted within the margin")
            try desktop.expectMenu("Accessibility permission granted", open: true, pid: granted.pid)
            harness.stopApp()
            try harness.startApp(fixtureReady: false)
        }
    }
}

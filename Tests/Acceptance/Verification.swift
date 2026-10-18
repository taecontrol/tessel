import Testing

extension Acceptance {
    struct Verification {
        @Test func removedResourceCalibrationFlagPrintsUsage() throws {
            // --help keeps the old parser from starting a nested SwiftPM run.
            let result = try run([root.appending(path: "scripts/verify").path, "--calibrate-resources", "--help"], timeout: margin)
            #expect(result.status == 2)
            #expect(result.error.hasPrefix("Usage: scripts/verify "))
            #expect(!result.error.contains("--calibrate-resources"))
        }
    }
}

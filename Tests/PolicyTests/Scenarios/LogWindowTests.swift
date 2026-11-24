import Testing
@testable import Policy

@Suite struct LogWindowTests {
    @Test("#75 E1: --last converts minutes, hours and days to whole seconds")
    func supportedWindows() {
        for (value, seconds) in [("30m", 1_800), ("6h", 21_600), ("2d", 172_800)] {
            #expect(LogWindow.seconds(value) == seconds, "--last \(value)")
        }
    }

    @Test("#75 E2: --last rejects other spellings and a window whose seconds overflow")
    func invalidWindows() {
        for value in ["0m", "5x", "m", "-5m", "1.5h", "+5m", " 5m", "999999999999999999d"] {
            #expect(LogWindow.seconds(value) == nil, "Accepted --last \(value)")
        }
    }
}

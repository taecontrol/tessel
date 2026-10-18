import ApplicationServices
import Foundation
import Testing

extension Acceptance {
    @MainActor
    struct ContractsClosedHandles {
        @Test("contract(.closedWindowHandles): retained AX handles after ordinary and retained NSWindow closes")
        func closedWindowHandles() throws {
            guard try run([fixtureExecutable.path, "--check-session"], timeout: margin).status == 0 else {
                throw HarnessError("Wake and unlock the Mac before running GUI verification")
            }
            let directory = FileManager.default.temporaryDirectory.appending(path: "tessel-closed-handles-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try FixtureSession(directory: directory, number: 0)
            defer { fixture.stop() }
            let observer = try FixtureSession(directory: directory, number: 999)
            defer { observer.stop() }
            for retain in [false, true] {
                try fixture.command("reset")
                let id = try fixture.open(key: "closing")
                let before = try #require(finalValue {
                    try? observer.command("retainWindowHandle", ["pid": fixture.pid, "id": id]).windowHandle
                })
                try #require(before.idStatus == 0 && before.id == id && before.listed)
                try #require(before.roleStatus == 0 && before.minimizedStatus == 0 && before.positionStatus == 0)
                try fixture.command("close", ["key": "closing", "retain": retain])
                let closedAt = monotonicSeconds()
                var reads = 0
                func retired(_ sample: WindowHandleSample) -> Bool {
                    sample.idStatus == AXError.illegalArgument.rawValue && sample.id == 0
                        && sample.roleStatus == AXError.invalidUIElement.rawValue
                        && sample.minimizedStatus == AXError.invalidUIElement.rawValue
                        && sample.positionStatus == AXError.invalidUIElement.rawValue
                        && sample.listStatus == 0 && !sample.listed && sample.listCount == 0
                }
                let result = try finalValue {
                    let sample = try #require(try observer.command("sampleWindowHandle").windowHandle)
                    reads += 1
                    return retired(sample) ? sample : nil
                }
                let first = try #require(result)
                for _ in 0..<20 {
                    let sample = try #require(try observer.command("sampleWindowHandle").windowHandle)
                    try #require(retired(sample))
                }
                print(String(format: "closed handle retain=%@ listed=%@ listCount=%d first=%.3f s reads=%d+20 idStatus=%d id=%u attributes=%d",
                             String(retain), String(first.listed), first.listCount, first.sampledAt - closedAt, reads,
                             first.idStatus, first.id, first.roleStatus))
            }
        }
    }
}

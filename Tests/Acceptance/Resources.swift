import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct Resources: AppSessionTest {
        init() throws { try Harness.shared.reset() }

        struct Budget: Decodable {
            let cpuNanoseconds: UInt64
            let residentBytes: UInt64
        }

        struct Calibration: Encodable {
            struct Measurement: Encodable {
                let cpuNanoseconds: UInt64
                let residentBytes: UInt64
            }
            struct Timebase: Encodable {
                let numer: UInt32
                let denom: UInt32
            }
            let measurements: [Measurement]
            let cpuNanoseconds: UInt64
            let residentBytes: UInt64
            let machTimebase: Timebase
        }

        @Test func e22TwentyIdleWindowsStayWithinCPUAndMemoryBudgets() throws {
            for index in 0..<20 { _ = try fixture.open(key: "idle\(index)") }
            try #require(try converges(within: 2) { $0.count == 20 })
            sleep(seconds: 1)  // Let the bounded new-window settling work finish.
            let budget = try JSONDecoder().decode(Budget.self, from: Data(contentsOf: root.appending(path: "Tests/Acceptance/resource-budget.json")))
            // Calibration keeps enforcing the 100 ms cap while recording new measurements.
            let calibrating = ProcessInfo.processInfo.environment["TESSEL_CALIBRATE_RESOURCES"] == "1"
            var measurements: [Calibration.Measurement] = []
            for index in 0..<10 {
                let before = try resources(harness.appPID).cpuNanoseconds
                sleep(seconds: 60)
                let after = try resources(harness.appPID)
                let measurement = Calibration.Measurement(cpuNanoseconds: after.cpuNanoseconds - before, residentBytes: after.residentBytes)
                measurements.append(measurement)
                print(String(format: "E22 run %d/10: CPU %.3f ms, RSS %.2f MB", index + 1,
                             Double(measurement.cpuNanoseconds) / 1e6, Double(measurement.residentBytes) / 1e6))
                try #require(measurement.residentBytes < budget.residentBytes)
                try #require(measurement.cpuNanoseconds < (calibrating ? 100_000_000 : budget.cpuNanoseconds))
            }
            let maximum = measurements.map(\.cpuNanoseconds).max() ?? 0
            let calibration = Calibration(measurements: measurements, cpuNanoseconds: min(100_000_000, maximum * 3),
                                          residentBytes: 50_000_000, machTimebase: .init(numer: timebase.numer, denom: timebase.denom))
            let destination = root.appending(path: ".work/resource-calibration.json")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (encoder.encode(calibration) + Data("\n".utf8)).write(to: destination)
            print("E22 calibration: \(calibration.cpuNanoseconds) ns (3 × maximum of ten CI runs)")
        }
    }
}

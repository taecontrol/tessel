import Foundation
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

extension Acceptance.Verification {
    @Test("the instant pixel oracle allows an old/final sweep and rejects wrong content and desktop")
    func instantPixelOracle() throws {
        let width = 60, height = 20
        func frame(_ left: UInt8, _ right: UInt8, at time: Double) -> InstantPixelRecording.Frame {
            var data = Data()
            for _ in 0..<height {
                for value in [left, right] { var count = UInt32(width / 2).bigEndian; withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(value) }
            }
            return InstantPixelRecording.Frame(time: time, owners: data)
        }
        func analyze(_ middle: InstantPixelRecording.Frame) throws -> InstantPixelRecording.Analysis {
            try InstantPixelRecording(width: width, height: height, frames: [frame(1, 2, at: 0), middle, frame(2, 3, at: 2)], failure: nil, requestedHz: 120).analyze(postedAt: 0.5, pointsWide: 600)
        }
        let sweep = try analyze(frame(1, 3, at: 1))
        #expect(sweep.intermediateFrames == 0 && sweep.gapFrames == 0 && sweep.changedPixels > 0)
        #expect(try analyze(frame(4, 3, at: 1)).intermediateFrames == 1)
        #expect(try analyze(frame(0, 3, at: 1)).gapFrames == 1)

        func born(at x: Int?, time: Double) -> InstantPixelRecording.Frame {
            var data = Data()
            for _ in 0..<height {
                for column in 0..<width {
                    var count = UInt32(1).bigEndian
                    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
                    data.append(x.map { (column >= $0 && column < $0 + 30) ? 4 : 0 } ?? 0)
                }
            }
            return .init(time: time, owners: data)
        }
        for intermediateX in [0, 15] {
            let opening = InstantPixelRecording(width: width, height: height,
                frames: [born(at: nil, time: 0), born(at: 0, time: 1), born(at: intermediateX, time: 2), born(at: 30, time: 3)],
                failure: nil, requestedHz: 120)
            let result = try opening.analyze(postedAt: 0.5, pointsWide: 600, arrival: 4,
                                            initialArrival: [0, 0, 300, 200], finalArrival: [300, 0, 300, 200])
            #expect(result.intermediateFrames == (intermediateX == 0 ? 0 : 1), "an opening may occupy only its native initial or final frame")
        }
        // E20 keeps opening's original one-step rule. Its new pointwise
        // coverage rule names workspace, rail, width, stop and close only.
        let opening = InstantPixelRecording(width: width, height: height,
            frames: [frame(1, 2, at: 0), frame(4, 2, at: 1), frame(0, 4, at: 2), frame(3, 4, at: 3)],
            failure: nil, requestedHz: 120)
        let opened = try opening.analyze(postedAt: 0.5, pointsWide: 600, arrival: 4,
                                         initialArrival: [0, 0, 300, 200], finalArrival: [300, 0, 300, 200])
        #expect(opened.intermediateFrames == 0 && opened.gapFrames == 0)
        let immediate = InstantPixelRecording(width: width, height: height,
            frames: [frame(1, 2, at: 0), frame(3, 4, at: 1), frame(3, 4, at: 2)], failure: nil, requestedHz: 120)
        let landed = try immediate.analyze(postedAt: 0.5, pointsWide: 600, arrival: 4,
                                          initialArrival: [0, 0, 300, 200], finalArrival: [300, 0, 300, 200])
        #expect(landed.intermediateFrames == 0 && landed.changedPixels > 0, "a birth first recorded at its final frame is live pixel evidence")
    }
}

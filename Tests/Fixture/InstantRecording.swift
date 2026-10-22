import AppKit
import CoreMedia
import Darwin
import ScreenCaptureKit

/// Records only signed fixture windows. Persisted frames contain palette IDs,
/// never desktop pixels, titles or other applications' contents.
final class FixtureInstantRecording: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let colors: [(Int, Int, Int)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255), (0, 255, 255)]
    private let queue = DispatchQueue(label: "fixture.instant-recording", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var frames: [[String: Any]] = []
    private var failure: String?
    private var width = 0, height = 0
    private var clockOffset = 0.0

    func start(pids: Set<pid_t>) async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw FixtureContractError("no recording display") }
        // Including apps missed AX moves in the measured spike. Excluding every
        // non-fixture app captures them; output is additionally palette masked.
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { !pids.contains($0.processID) }, exceptingWindows: [])
        if let stream {
            try await stream.updateContentFilter(filter)
            guard lock.withLock({ failure == nil }) else { throw FixtureContractError("the recording stream stopped") }
            // ScreenCaptureKit emits idle statuses for an unchanged view.
            // Keep its latest actual image as the baseline of the next clip.
            lock.withLock { frames = frames.last.map { [$0] } ?? [] }
            return ["recordingWidth": width, "recordingHeight": height, "recordingPoints": [display.width, display.height]]
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(Double(display.width) * Double(filter.pointPixelScale)) / 4
        configuration.height = Int(Double(display.height) * Double(filter.pointPixelScale)) / 4
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 8
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        width = configuration.width; height = configuration.height
        clockOffset = Self.now(CLOCK_MONOTONIC_RAW) - Self.now(CLOCK_UPTIME_RAW)
        lock.withLock { frames.removeAll(); failure = nil }
        let recording = SCStream(filter: filter, configuration: configuration, delegate: self)
        try recording.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await recording.startCapture()
        stream = recording
        return ["recordingWidth": width, "recordingHeight": height, "recordingPoints": [display.width, display.height]]
    }

    func stop(to path: String, keepRunning: Bool = false) async throws -> [String: Any] {
        guard let stream else { throw FixtureContractError("no instant recording is running") }
        if !keepRunning {
            try await stream.stopCapture()
            self.stream = nil
        }
        // Drain the sample lane before serializing its masks.
        queue.sync {}
        let result = lock.withLock { () -> [String: Any] in
            ["width": width, "height": height, "frames": frames, "failure": failure as Any? ?? NSNull(), "requestedHz": 120]
        }
        try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: path), options: .atomic)
        return ["recordingFrames": lock.withLock { frames.count }]
    }

    private static func now(_ clock: clockid_t) -> Double { Double(clock_gettime_nsec_np(clock)) / 1e9 }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = String(describing: error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var runs = Data(), owner: UInt8 = 0, count: UInt32 = 0
        func flush() {
            guard count > 0 else { return }
            var length = count.bigEndian
            withUnsafeBytes(of: &length) { runs.append(contentsOf: $0) }
            runs.append(owner)
        }
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<w {
                let pixel = row[x], r = Int((pixel >> 16) & 255), g = Int((pixel >> 8) & 255), b = Int(pixel & 255)
                let bits = (r >= 231 ? 4 : 0) | (g >= 231 ? 2 : 0) | (b >= 231 ? 1 : 0)
                let saturated = (r <= 24 || r >= 231) && (g <= 24 || g >= 231) && (b <= 24 || b >= 231)
                let value: UInt8
                if saturated {
                    value = switch bits {
                    case 4: 1
                    case 2: 2
                    case 1: 3
                    case 6: 4
                    case 5: 5
                    case 3: 6
                    default: 0
                    }
                } else { value = 0 }
                if count > 0 && value != owner { flush(); count = 0 }
                owner = value; count += 1
            }
        }
        flush()
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds + clockOffset
        lock.withLock { frames.append(["time": time, "owners": runs.base64EncodedString()]) }
    }
}

/// The fixture's synchronous command socket must not block MainActor while
/// ScreenCaptureKit awaits native services.
extension FixtureInstantRecording {
    final class ResultBox: @unchecked Sendable { var result: Result<[String: Any], Error>? }
    func command(_ input: [String: Any]) throws -> [String: Any] {
        let done = DispatchSemaphore(value: 0), box = ResultBox()
        let starting = input["operation"] as? String == "instantRecordingStart"
        let pids = Set((input["pids"] as? [Int32]) ?? [])
        let output = input["path"] as? String
        let keepRunning = input["keepRunning"] as? Bool == true
        Task.detached {
            do {
                if starting {
                    box.result = .success(try await self.start(pids: pids))
                } else {
                    guard let path = output else { throw FixtureContractError("recording needs a local output path") }
                    box.result = .success(try await self.stop(to: path, keepRunning: keepRunning))
                }
            } catch { box.result = .failure(error) }
            done.signal()
        }
        // Setup/teardown is not a product latency measurement.
        guard done.wait(timeout: .now() + 5) == .success, let result = box.result else { throw FixtureContractError("instant recording setup/teardown timed out") }
        return try result.get()
    }
}

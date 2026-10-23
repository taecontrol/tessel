import AppKit
import AVFoundation

/// A single invented video frame, using the same capture protection as a player.
@MainActor
final class FixtureVideo: NSView {
    private(set) var video = AVSampleBufferDisplayLayer()
    private var sample: CMSampleBuffer?
    private var resizeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemGreen.cgColor
        video.frame = CGRect(x: 40, y: 30, width: 320, height: 240)
        layer?.addSublayer(video)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            for i in 0..<(CVPixelBufferGetBytesPerRow(buffer) * 240 / 4) {
                base[i * 4] = 30; base[i * 4 + 1] = 30; base[i * 4 + 2] = 200; base[i * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                               sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        self.sample = sample
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[kCMSampleAttachmentKey_DisplayImmediately] = true
        video.enqueue(sample)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func preventCapture(_ enabled: Bool, afterResize: Bool) {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver); self.resizeObserver = nil }
        if afterResize, let window {
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.preventCapture(enabled, afterResize: false) }
            }
        } else {
            video.removeFromSuperlayer()
            let replacement = AVSampleBufferDisplayLayer()
            replacement.frame = CGRect(x: 40, y: 30, width: 320, height: 240)
            replacement.preventsCapture = enabled
            if let sample { replacement.enqueue(sample) }
            layer?.addSublayer(replacement)
            video = replacement
            CATransaction.flush()
        }
    }
}

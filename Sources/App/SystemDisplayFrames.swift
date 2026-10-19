import AppKit
import QuartzCore

/// A display link exists only while a client has outstanding one-shot demand.
/// The callback can renew demand synchronously without restarting the link.
@MainActor
final class SystemDisplayFrames: NSObject, DisplayFramePort {
    private var link: CADisplayLink?
    private var pending: (id: UUID, receive: @MainActor @Sendable (TimeInterval) -> Void)?
    #if TESSEL_DEVELOPMENT
    var onFrame: (() -> Void)?
    #endif
    var now: TimeInterval { CACurrentMediaTime() }

    func requestFrame(_ receive: @escaping @MainActor @Sendable (TimeInterval) -> Void) -> any ScheduledWork {
        let id = UUID()
        pending = (id, receive)
        if link == nil, let screen = NSScreen.screens.first {
            let display = screen.displayLink(target: self, selector: #selector(frame(_:)))
            display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(screen.maximumFramesPerSecond),
                                                              preferred: Float(screen.maximumFramesPerSecond))
            link = display
            display.add(to: .main, forMode: .common)
        }
        return Demand { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.pending = nil
            self.link?.invalidate(); self.link = nil
        }
    }

    @objc private func frame(_ display: CADisplayLink) {
        #if TESSEL_DEVELOPMENT
        onFrame?()
        #endif
        let receive = pending?.receive
        pending = nil
        receive?(display.timestamp)
        if pending == nil { link?.invalidate(); link = nil }
    }

    private final class Demand: ScheduledWork, @unchecked Sendable {
        private let cancelOnMain: @MainActor @Sendable () -> Void
        init(_ cancel: @escaping @MainActor @Sendable () -> Void) { cancelOnMain = cancel }
        func cancel() {
            if Thread.isMainThread { MainActor.assumeIsolated { cancelOnMain() } }
            else { DispatchQueue.main.async(execute: cancelOnMain) }
        }
    }
}

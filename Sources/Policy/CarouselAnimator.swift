import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

/// Owns display demand and interpolated geometry. AX workers reserve one
/// intermediate batch per app and discard late frames rather than queue them.
@MainActor
final class CarouselAnimator {
    struct Write: Sendable {
        let frame: CGRect
        let position: Bool
        let resize: Bool
        let screenRight: CGFloat
    }
    typealias Writer = ([UInt32: Write], Bool, @escaping @MainActor @Sendable () -> Void) -> Void
    private let display: any DisplayFramePort
    private let main: any MainLane
    private var demand: (any ScheduledWork)?
    private var deadline: (any ScheduledWork)?
    private var generation = 0
    private(set) var frames: [UInt32: CGRect] = [:]
    private(set) var active = false

    init(display: any DisplayFramePort, main: any MainLane) {
        self.display = display
        self.main = main
    }
    var now: TimeInterval { display.now }

    func cancel() {
        generation += 1
        demand?.cancel(); demand = nil
        deadline?.cancel(); deadline = nil
        active = false
    }

    func start(from: [UInt32: CGRect], to: [UInt32: CGRect], duration: Int,
               bounds: CGRect, menuBottom: CGFloat, bounce: CGPoint? = nil, startedAt: TimeInterval? = nil,
               unread: [UInt32: Bool] = [:],
               ready: @escaping @MainActor () -> Bool = { true },
               apply: @escaping Writer, completion: @escaping @MainActor () -> Void) {
        cancel()
        frames = from
        let token = generation, start = startedAt ?? display.now
        let seconds = bounce == nil ? Double(duration) / 1_000 : max(0.140, Double(duration) * 0.0009)
        let moving = to.keys.sorted().filter { from[$0] != to[$0] || bounce != nil || unread[$0] != nil }
        guard duration > 0, !moving.isEmpty else { completion(); return }
        active = true
        var busy = false, prepared = false, landing = false
        func request() {
            demand = display.requestFrame { [weak self] now in
                guard let self, self.generation == token, !landing else { return }
                self.demand = nil
                advance(now)
            }
        }
        func advance(_ now: TimeInterval) {
            guard generation == token, !landing else { return }
            let p = min(1, max(0, (now - start) / seconds))
            guard !busy || p >= 1 else { return }
            if !prepared {
                prepared = ready()
                // AXRaise and closet return can acknowledge before CG
                // reflects their order. No moving frame precedes it.
                if !prepared && p < 1 { request(); return }
            }
            let spring = p >= 1 ? 1 : 1 - (1 + 7.43 * p) * exp(-7.43 * p)
            var batch: [UInt32: Write] = [:]
            for id in moving {
                guard let a = from[id], let b = to[id] else { continue }
                // A slow AX lane could not confirm its interrupted frame.
                // Skip guesses during motion and always write its landing.
                if p < 1, unread[id] != nil { continue }
                var frame: CGRect
                if let bounce {
                    let amplitude = p >= 1 ? 0 : sin(.pi * p) * exp(-2 * p) * 0.045
                    frame = a.offsetBy(dx: bounce.x * bounds.width * amplitude,
                                       dy: bounce.y * bounds.height * amplitude)
                } else {
                    frame = CGRect(x: a.minX + (b.minX - a.minX) * spring,
                                   y: a.minY + (b.minY - a.minY) * spring,
                                   width: a.width + (b.width - a.width) * spring,
                                   height: a.height + (b.height - a.height) * spring)
                }
                frame.origin.x = max(bounds.minX + 1 - frame.width, min(bounds.maxX - 1, frame.minX))
                frame.origin.y = max(menuBottom, min(bounds.maxY - 32, frame.minY))
                // Intermediate writes may have been skipped by a busy AX
                // lane. Every moving window still receives the landing.
                if p < 1, self.frames[id] == frame { continue }
                batch[id] = Write(frame: frame, position: a.origin != b.origin || a.size != b.size || bounce != nil || unread[id] != nil,
                                  resize: a.size != b.size || unread[id] == true, screenRight: bounds.maxX)
            }
            let displayed = batch.mapValues(\.frame)
            if p >= 1 {
                landing = true
                demand?.cancel(); demand = nil
                deadline?.cancel(); deadline = nil
            }
            busy = true
            apply(batch, p >= 1) { [weak self] in
                guard let self, self.generation == token else { return }
                self.frames.merge(displayed) { _, new in new }
                busy = false
                if p >= 1 {
                    self.demand?.cancel(); self.demand = nil
                    self.active = false
                    completion()
                } else if !landing { request() }
            }
        }
        // Display links can stop delivering, including before their first tick.
        // One bounded deadline lands through the same final writer; it is
        // cancelled on ordinary completion, retargeting and interruption.
        let remaining = max(0, start + seconds - display.now)
        deadline = main.after(milliseconds: Int(ceil(remaining * 1_000)) + 50) { [weak self] in
            guard let self, self.generation == token else { return }
            advance(start + seconds + 0.001)
        }
        request()
    }
}

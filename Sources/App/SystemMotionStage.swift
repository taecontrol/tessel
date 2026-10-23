import AppKit
import CoreMedia
import IOSurface
import QuartzCore
import ScreenCaptureKit
import VideoToolbox

/// Window captures animated by Core Animation in a click-through overlay, so
/// motion runs at display rate whatever the apps are doing. Captures use
/// ScreenCaptureKit: the recording indicator goes out a few seconds after the
/// last one. Every image is released when the stage clears.
#if TESSEL_DEVELOPMENT
enum StageEvent { case begin, screenshot(UInt32), pending(Int), capture, show, settled, clear }
#endif

@MainActor
final class SystemMotionStage: MotionStagePort {
    private final class StandIn {
        let container = CALayer()
        var images: [CALayer] = []
        var rect = CGRect.zero
        /// The window's corner radius, in points.
        var radius: CGFloat = 0
        var path: Path?
        var motion: [CAAnimation] = []
    }
    /// One motion of a stand-in. Each component (x, y, width, height)
    /// returns to rest critically damped, stiffer than the native Space
    /// switch so the tail settles within the duration. A motion from rest is
    /// launched; a retarget keeps the speed the stand-in has, so repeats and
    /// reversals do not kick.
    private struct Path {
        static let stiffness = 10.0, launch = 0.38
        let to: CGRect
        /// Start minus rest, and velocity in points per duration.
        let offset: [Double], velocity: [Double]
        let begin: CFTimeInterval, duration: TimeInterval
        init(from: CGRect, to: CGRect, speed: [Double] = [0, 0, 0, 0], begin: CFTimeInterval, duration: TimeInterval) {
            let k = Self.stiffness
            self.to = to; self.begin = begin; self.duration = duration
            offset = [from.minX - to.minX, from.minY - to.minY, from.width - to.width, from.height - to.height]
            velocity = zip(offset, speed).map { d, speed in
                let launched = -k * Self.launch * d, carried = speed * duration
                // Toward rest, the faster of the two; away from it, the
                // launch turns the stand-in around.
                var v = carried * launched > 0 ? (abs(carried) > abs(launched) ? carried : launched) : launched + carried
                // Never past rest.
                if d > 0 { v = max(v, -k * d) } else if d < 0 { v = min(v, -k * d) }
                return v
            }
        }
        private func residual(_ i: Int, _ p: Double) -> Double {
            let k = Self.stiffness, d = offset[i]
            return (d + (velocity[i] + k * d) * p) * exp(-k * p)
        }
        func rect(_ p: Double) -> CGRect {
            guard p < 1 else { return to }
            let r = (0..<4).map { residual($0, max(0, p)) }
            return CGRect(x: to.minX + r[0], y: to.minY + r[1], width: to.width + r[2], height: to.height + r[3])
        }
        func progress(at time: CFTimeInterval) -> Double { duration > 0 ? (time - begin) / duration : 1 }
        /// Points per second, per component.
        func speed(at time: CFTimeInterval) -> [Double] {
            let p = progress(at: time), k = Self.stiffness
            guard p >= 0, p < 1 else { return [0, 0, 0, 0] }
            return (0..<4).map { i in
                let d = offset[i], v = velocity[i]
                return ((v + k * d) - k * (d + (v + k * d) * p)) * exp(-k * p) / duration
            }
        }
        /// The progress from which every component stays within `tolerance`
        /// of rest.
        func settles(within tolerance: Double) -> Double {
            var p = 1.0
            for step in stride(from: 100, through: 0, by: -1) {
                let q = Double(step) / 100
                if (0..<4).contains(where: { abs(residual($0, q)) >= tolerance }) { break }
                p = q
            }
            return p
        }
    }
    private var overlay: NSWindow?
    private let root = CALayer(), canvas = CALayer(), backdrop = CALayer()
    /// How long the stage takes to fade into the real windows once they are in place.
    private static let fade = 0.04
    /// The longest the stage waits for WindowServer to draw the overlay.
    private static let drawLimit = 0.15
    private var standIns: [UInt32: StandIn] = [:]
    private enum CaptureError: Error { case unreadable }
    /// One window's capture, measured once.
    private final class Capture: @unchecked Sendable {
        let sample: CMSampleBuffer
        let surface: IOSurfaceRef
        let edge: CGColor?
        /// The window's corner radius and its size, in pixels.
        let radius: CGFloat
        let pixels: CGSize
        /// What a layer shows. An IOSurface from ScreenCaptureKit draws
        /// about 100 ms late in a layer, so it is copied into a CGImage.
        let contents: Any
        init?(_ sample: CMSampleBuffer) throws {
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
            guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let address = IOSurfaceGetBaseAddress(surface)
            // A protected capture can lock successfully without mapping pixels.
            guard Int(bitPattern: address) != 0 else { throw CaptureError.unreadable }
            self.sample = sample
            self.surface = surface
            (edge, radius) = Self.measure(surface, base: address.assumingMemoryBound(to: UInt8.self))
            pixels = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            guard let image else { return nil }
            contents = image
        }
        /// The window's own colour just inside its right edge, for the band a
        /// growing stand-in uncovers, and its corner radius, read from the
        /// transparent run at the start of its top row: a corner of radius r
        /// leaves r − √(r − ¼) pixels clear there. Pixels are BGRA.
        private static func measure(_ surface: IOSurfaceRef, base: UnsafePointer<UInt8>) -> (CGColor?, CGFloat) {
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            guard width > 8, height > 8 else { return (nil, 0) }
            let row = IOSurfaceGetBytesPerRow(surface)
            var sum = [0.0, 0.0, 0.0], count = 0.0
            for y in stride(from: height / 4, to: height * 3 / 4, by: max(1, height / 32)) {
                let pixel = base + y * row + (width - 6) * 4
                sum[0] += Double(pixel[2]); sum[1] += Double(pixel[1]); sum[2] += Double(pixel[0]); count += 1
            }
            // The top edge may carry a transparent border: measure on the
            // first row whose middle is opaque.
            var top = 0
            while top < min(16, height / 4), base[top * row + width / 2 * 4 + 3] < 128 { top += 1 }
            let first = base + top * row
            var run = 0
            while run < 64, first[run * 4 + 3] < 128 { run += 1 }
            if run == 64 { run = 0 }
            var radius = 0.0
            if run > 0 {
                radius = stride(from: Double(run), through: Double(run) * 4 + 8, by: 0.25)
                    .min { abs($0 - ($0 - 0.25).squareRoot() - Double(run)) < abs($1 - ($1 - 0.25).squareRoot() - Double(run)) } ?? 0
            }
            return (CGColor(srgbRed: sum[0] / count / 255, green: sum[1] / count / 255, blue: sum[2] / count / 255, alpha: 1), radius)
        }
    }
    private var captures: [UInt32: Task<Capture?, Never>] = [:]
    /// Captures that arrived this session, for a move to install.
    private var ready: [UInt32: Capture] = [:]
    private var background: Task<Capture?, Never>?
    /// Unlike the session's image tasks, this count survives `clear()`. A
    /// cancelled Swift task does not cancel replayd's native request.
    private var pendingCaptures = 0 {
        didSet {
            #if TESSEL_DEVELOPMENT
            onEvent?(.pending(pendingCaptures))
            #endif
        }
    }
    var capturesPending: Bool { pendingCaptures > 0 }
    var onCapturesSettled: (@MainActor @Sendable () -> Void)?
    var onCaptureFailed: (@MainActor @Sendable () -> Void)?
    /// Whether a window rests in tessel's closet, the only place a window
    /// WindowServer lists off screen is still drawn.
    var inCloset: @MainActor (UInt32) -> Bool = { _ in false }
    private var refreshes: [UInt32: Int] = [:]
    private var retried = Set<UInt32>()
    /// Protection cannot improve during a move, including later resize
    /// refreshes. Forget it when the stage clears so the next move tries again.
    private var unreadable = Set<UInt32>()
    /// Windows not drawn when their capture was due: closing, or in a hidden
    /// app. Nothing of them shows, so the stage needs no stand-in for them.
    private var undrawn = Set<UInt32>()
    private var revealing = 0
    private var content: SCShareableContent?
    private var session = 0
    private var shown = false
    private var lastMove: (rects: [UInt32: CGRect], entering: [UInt32: CGRect], begin: CFTimeInterval, duration: TimeInterval)?
    private var settle: (any ScheduledWork)?
    /// Held while a motion is staged: an idle agent app's timers and commits
    /// are otherwise coalesced, which drew the stage tens of milliseconds late.
    private var activity: NSObjectProtocol?
    #if TESSEL_DEVELOPMENT
    var onEvent: ((StageEvent) -> Void)?
    #endif

    /// A preflight takes about 10 ms and up to 30: the stage answers from the
    /// last one and refreshes it off the main thread, so a revoked grant shows
    /// on the next command, and a failed capture places the windows at once.
    private var granted: Bool?
    private var checkingAccess = false
    var available: Bool {
        let answer = granted ?? CGPreflightScreenCaptureAccess()
        granted = answer
        if !checkingAccess {
            checkingAccess = true
            Task.detached(priority: .utility) { [weak self] in
                let value = CGPreflightScreenCaptureAccess()
                await MainActor.run { self?.granted = value; self?.checkingAccess = false }
            }
        }
        return answer
    }
    func requestAccess() { _ = CGRequestScreenCaptureAccess() }

    private var screen: CGRect { NSScreen.screens.first?.frame ?? .zero }
    /// Below the menu bar: the live menu bar stays on top, and nothing is
    /// captured or drawn under it.
    private var stageRect: CGRect {
        guard let main = NSScreen.screens.first else { return .zero }
        let menu = main.frame.maxY - main.visibleFrame.maxY
        return CGRect(x: main.frame.minX, y: menu, width: main.frame.width, height: main.frame.height - menu)
    }

    func capture(_ windows: Set<UInt32>, background excluding: Set<UInt32>?) {
        let token = session
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "carousel motion")
            #if TESSEL_DEVELOPMENT
            onEvent?(.begin)
            #endif
        }
        for id in windows.sorted() where captures[id] == nil {
            captures[id] = Task { [weak self] in
                let image = await self?.captureWindow(id, session: token)
                guard let self, token == self.session else { return image }
                if let image { self.ready[id] = image; self.join(id, image: image) }
                else {
                    // A window resized during its capture, or ScreenCaptureKit
                    // failed once: try once more, so a window first seen by a
                    // retarget still gets its stand-in.
                    self.captures[id] = nil
                    if self.retried.insert(id).inserted { self.capture([id], background: nil) }
                    else if !self.undrawn.contains(id) { self.onCaptureFailed?() }
                }
                return image
            }
        }
        if let excluding, background == nil {
            background = Task { [weak self] in await self?.captureBackground(excluding: excluding, session: token) }
        }
    }

    func show(_ rects: [UInt32: CGRect], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let token = session
        let pending = captures, backdropTask = background
        Task { [weak self] in
            var images: [UInt32: Capture] = [:]
            for (id, task) in pending { if let image = await task.value { images[id] = image } }
            let back = await backdropTask?.value
            guard let self, token == self.session else { completion(false); return }
            // Without what lies under them, moving stand-ins would uncover the
            // real windows being placed.
            guard backdropTask == nil || back != nil,
                  !rects.keys.contains(where: { pending[$0] != nil && images[$0] == nil && !self.undrawn.contains($0) }) else { completion(false); return }
            self.prepareOverlay()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.backdrop.frame = self.stageRect
            self.backdrop.contents = back?.contents
            for (id, rect) in rects.sorted(by: { $0.key < $1.key }) {
                guard let image = images[id] else { continue }
                self.place(id, image: image, at: rect)
            }
            CATransaction.commit()
            self.shown = true
            #if TESSEL_DEVELOPMENT
            self.onEvent?(.show)
            #endif
            // Real windows must not move before the overlay covers them.
            // WindowServer usually draws a commit within a frame, but takes
            // about 50 ms at times, as when another app redraws busily.
            CATransaction.flush()
            let start = CACurrentMediaTime()
            @MainActor func covered() {
                guard token == self.session else { completion(false); return }
                let waited = CACurrentMediaTime() - start
                guard self.overlayDrawn() || waited > Self.drawLimit else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { MainActor.assumeIsolated { covered() } }
                    return
                }
                completion(true)
            }
            covered()
        }
    }

    /// One point of the overlay, as WindowServer composites it: opaque once
    /// the backdrop is drawn. A process may capture its own windows without
    /// Screen Recording.
    private func overlayDrawn() -> Bool {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let number = overlay?.windowNumber, number > 0,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return true }
        let point = CGRect(x: stageRect.midX, y: stageRect.midY, width: 1, height: 1)
        guard let image = unsafeBitCast(symbol, to: Create.self)(point, 1 << 3, UInt32(number), 1 << 4)?.takeRetainedValue(),
              let data = image.dataProvider?.data, CFDataGetLength(data) >= 4 else { return false }
        let bytes = CFDataGetBytePtr(data)!
        let alpha: UInt8
        switch image.alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: alpha = bytes[image.bitmapInfo.contains(.byteOrder32Little) ? 3 : 0]
        default: alpha = bytes[image.bitmapInfo.contains(.byteOrder32Little) ? 0 : 3]
        }
        return alpha > 200
    }

    func move(_ rects: [UInt32: CGRect], entering: [UInt32: CGRect], duration: TimeInterval,
              settled: @escaping @MainActor @Sendable () -> Void) {
        revealing += 1
        let begin = CACurrentMediaTime()
        var p = 0.0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        canvas.removeAnimation(forKey: "reveal"); canvas.opacity = 1
        for (id, standIn) in standIns where rects[id] == nil {
            standIn.container.removeFromSuperlayer()
            standIns[id] = nil
        }
        for (id, end) in rects.sorted(by: { $0.key < $1.key }) {
            let path: Path
            if let standIn = standIns[id] {
                let from = standIn.path.map { $0.rect($0.progress(at: begin)) } ?? standIn.rect
                path = Path(from: from, to: end, speed: standIn.path?.speed(at: begin) ?? [0, 0, 0, 0], begin: begin, duration: duration)
                animate(standIn, along: path)
            } else if let start = entering[id], captures[id] != nil {
                path = Path(from: start, to: end, begin: begin, duration: duration)
                // A capture that arrived before this move joins it now.
                if shown, let image = ready[id] {
                    place(id, image: image, at: start)
                    animate(standIns[id]!, along: path)
                }
            } else { continue }
            // The real windows take over once every stand-in is within 1.5 pt
            // of rest: the curve's tail is invisible, and frozen content is not.
            p = max(p, path.settles(within: 1.5))
        }
        CATransaction.commit()
        lastMove = (rects, entering, begin, duration)
        let token = session
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.session else { return }
                #if TESSEL_DEVELOPMENT
                self.onEvent?(.settled)
                #endif
                settled()
            }
        }
        settle = Cancel(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * p, execute: work)
    }

    func cover(_ covered: @escaping @MainActor @Sendable () -> Void) {
        let token = session, start = CACurrentMediaTime()
        CATransaction.flush()
        @MainActor func check() {
            guard token == session else { return }
            guard overlayDrawn() || CACurrentMediaTime() - start > Self.drawLimit else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { MainActor.assumeIsolated { check() } }
                return
            }
            covered()
        }
        check()
    }

    func reveal(_ frames: [UInt32: CGRect], hidden: Set<UInt32>,
                revealed: @escaping @MainActor @Sendable () -> Void) {
        revealing += 1
        let token = revealing, session = self.session
        func check() {
            guard token == revealing, session == self.session else { return }
            let live = windowServer(Set(frames.keys).union(hidden))
            let waiting = frames.keys.filter { id in
                guard let (bounds, onScreen) = live[id] else { return false }
                return !onScreen || distance(bounds, frames[id]!) >= 1
            } + hidden.filter { live[$0]?.onScreen == true }
            guard waiting.isEmpty else {
                // Once a frame: WindowServer draws what it lists in its next frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 240) { MainActor.assumeIsolated { check() } }
                return
            }
            // The stage fades into the real windows, now in place under it:
            // the curve's last points, the shadows and the focus look change
            // over a few frames instead of in one.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { if token == self.revealing, session == self.session { revealed() } }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = Self.fade
            canvas.add(fade, forKey: "reveal")
            canvas.opacity = 0
            CATransaction.commit()
        }
        check()
    }

    func refresh(_ window: UInt32) {
        let token = session
        refreshes[window, default: 0] += 1
        let revision = refreshes[window]
        // A frame for the app to draw what it just accepted.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 17_000_000)
            guard let self, token == self.session, revision == self.refreshes[window],
                  let image = await self.captureWindow(window, session: token),
                  token == self.session, revision == self.refreshes[window], let standIn = self.standIns[window] else { return }
            self.ready[window] = image
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let layer = self.imageLayer(image, size: standIn.rect.size)
            // Once the new capture has faded in, the ones under it go, so key
            // repeat never stacks image generations.
            CATransaction.setCompletionBlock { [weak standIn, weak layer] in
                MainActor.assumeIsolated {
                    guard let standIn, let layer, standIn.images.last === layer else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    standIn.images.dropLast().forEach { $0.removeFromSuperlayer() }
                    CATransaction.commit()
                    standIn.images = [layer]
                }
            }
            if standIn.motion.count == 4 {
                layer.add(standIn.motion[2], forKey: "position")
                layer.add(standIn.motion[3], forKey: "bounds")
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.06
            layer.add(fade, forKey: "fade")
            standIn.container.addSublayer(layer)
            standIn.images.append(layer)
            CATransaction.commit()
        }
    }

    func clear() {
        #if TESSEL_DEVELOPMENT
        onEvent?(.clear)
        #endif
        session += 1
        onCaptureFailed = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        settle?.cancel(); settle = nil
        captures.values.forEach { $0.cancel() }
        captures.removeAll()
        ready.removeAll()
        refreshes.removeAll()
        retried.removeAll()
        unreadable.removeAll()
        undrawn.removeAll()
        background?.cancel(); background = nil
        lastMove = nil
        revealing += 1
        guard shown || !standIns.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdrop.contents = nil
        standIns.values.forEach { $0.container.removeFromSuperlayer() }
        standIns.removeAll()
        canvas.removeAnimation(forKey: "reveal"); canvas.opacity = 1
        CATransaction.commit()
        shown = false
        // The empty overlay stays ordered in, transparent and click-through,
        // so the next show draws in its first frame.
    }

    // MARK: Captures

    private func captureSettled() {
        pendingCaptures -= 1
        if pendingCaptures == 0 { onCapturesSettled?() }
    }

    private func shareable(_ id: UInt32) async -> SCWindow? {
        if let window = content?.windows.first(where: { $0.windowID == id }) { return window }
        content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content?.windows.first { $0.windowID == id }
    }

    private func liveSize(_ id: UInt32) -> CGSize? { windowServer([id])[id]?.bounds.size }

    /// What WindowServer lists for each window: its bounds and whether it is
    /// on screen. A closed window is missing.
    private func windowServer(_ ids: Set<UInt32>) -> [UInt32: (bounds: CGRect, onScreen: Bool)] {
        guard !ids.isEmpty else { return [:] }
        var pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = CFArrayCreate(nil, &pointers, pointers.count, nil)
        let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
        var result: [UInt32: (bounds: CGRect, onScreen: Bool)] = [:]
        for entry in list {
            guard let id = entry[kCGWindowNumber as String] as? UInt32, let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            result[id] = (rect, entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        return result
    }

    /// The whole window, sized from its live bounds: shareable content goes
    /// stale after a resize, and ScreenCaptureKit fits the window into the
    /// output, which would draw it smaller.
    private func captureWindow(_ id: UInt32, session token: Int) async -> Capture? {
        guard token == session else { return nil }
        pendingCaptures += 1
        defer { captureSettled() }
        guard let window = await shareable(id), token == session, !unreadable.contains(id),
              let live = windowServer([id])[id] else { return nil }
        // A window ordering out, as a closing one does, is not drawn: a
        // screenshot of it never completes, and replayd then keeps the
        // capture's recording attribution until it restarts. Every later
        // capture on the Mac waits longer for the indicator to publish.
        guard live.onScreen || inCloset(id) else {
            undrawn.insert(id); retried.insert(id)
            return nil
        }
        let size = live.bounds.size
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(size.width * scale); configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // Measured as BGRA, with the window's own transparent corners.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        #if TESSEL_DEVELOPMENT
        onEvent?(.screenshot(id))
        #endif
        guard let sample = await screenshot(filter, configuration) else {
            // Waiting again could only leave another capture behind.
            if token == session { retried.insert(id) }
            return nil
        }
        let image: Capture
        do {
            guard let converted = try await Self.convert(sample) else { return nil }
            image = converted
        } catch {
            // An unreadable surface cannot improve within this move.
            if token == session { retried.insert(id); unreadable.insert(id) }
            return nil
        }
        guard token == session else { return nil }
        // A window that changed size during the capture was drawn scaled.
        guard liveSize(id) == size else { return nil }
        #if TESSEL_DEVELOPMENT
        onEvent?(.capture)
        #endif
        return image
    }

    private func captureBackground(excluding: Set<UInt32>, session token: Int) async -> Capture? {
        guard token == session else { return nil }
        pendingCaptures += 1
        defer { captureSettled() }
        // A window opened since the last fetch would otherwise stay in the
        // backdrop, frozen where it opened.
        if content == nil || !excluding.isSubset(of: Set(content?.windows.map(\.windowID) ?? [])) {
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard token == session, let content, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return nil }
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        let excluded = content.windows.filter {
            excluding.contains($0.windowID) || $0.owningApplication?.processID == getpid() || $0.windowLayer >= floating
        }
        // What lies under the stand-ins is mostly wallpaper, seen for a
        // moment: nominal resolution halves the pixels and the capture time.
        let rect = stageRect, scale: CGFloat = 1
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = Int(rect.width * scale); configuration.height = Int(rect.height * scale)
        configuration.showsCursor = false
        guard let sample = await screenshot(SCContentFilter(display: display, excludingWindows: excluded), configuration) else { return nil }
        return try? await Self.convert(sample)
    }

    /// The longest the stage waits for one screenshot, queued behind the
    /// move's other captures. replayd takes them one at a time.
    private static let captureLimit = 1.0

    /// A screenshot, or nothing once it fails or `captureLimit` passes. One
    /// that never completes must not hold the stage: the windows are then
    /// placed at once, and a window that stopped drawing during its capture
    /// is not captured again.
    private func screenshot(_ filter: SCContentFilter, _ configuration: SCStreamConfiguration) async -> Sample? {
        let reply = Reply()
        return await withCheckedContinuation { continuation in
            reply.continuation = continuation
            // A cancelled timer source leaves no wakeup behind at rest.
            reply.limit.schedule(deadline: .now() + Self.captureLimit)
            reply.limit.setEventHandler { reply.resume(nil) }
            reply.limit.resume()
            SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration) { sample, _ in
                let sample = sample.map(Sample.init)
                DispatchQueue.main.async { reply.resume(sample) }
            }
        }
    }

    /// A sample buffer is immutable once captured.
    private struct Sample: @unchecked Sendable { let buffer: CMSampleBuffer }

    /// Resumes its continuation once, on the main queue.
    private final class Reply: @unchecked Sendable {
        var continuation: CheckedContinuation<Sample?, Never>?
        let limit = DispatchSource.makeTimerSource(queue: .main)
        func resume(_ sample: Sample?) {
            limit.cancel()
            continuation?.resume(returning: sample)
            continuation = nil
        }
    }

    /// Converting a capture takes milliseconds; the main thread keeps
    /// committing the motion meanwhile.
    private nonisolated static func convert(_ sample: Sample) async throws -> Capture? {
        try await Task.detached(priority: .userInitiated) { try Capture(sample.buffer) }.value
    }

    // MARK: Layers

    /// The overlay covers the stage only, below the menu bar, so nothing
    /// masks the canvas; the canvas keeps the screen's CG coordinates.
    private func prepareOverlay() {
        let screen = self.screen, stage = stageRect
        let frame = NSRect(x: screen.minX, y: screen.minY, width: stage.width, height: stage.height)
        if overlay == nil {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            // AppKit resets a layer-backed view's flip; a flipped sublayer
            // keeps CG's top-left coordinates.
            view.layer = root
            view.wantsLayer = true
            canvas.isGeometryFlipped = true
            window.contentView = view
            overlay = window
        }
        if overlay?.frame != frame { overlay?.setFrame(frame, display: false) }
        // Layers added or changed outside a transaction without actions fade
        // in over a quarter second; the real windows would show through.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if canvas.superlayer == nil { root.addSublayer(canvas); canvas.addSublayer(backdrop) }
        root.frame = CGRect(origin: .zero, size: frame.size)
        // Flipped, its top is the screen's top, a menu bar above the window's.
        canvas.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        backdrop.contentsScale = 1
        CATransaction.commit()
        if overlay?.isVisible != true { overlay?.orderFrontRegardless() }
    }

    private func place(_ id: UInt32, image: Capture, at rect: CGRect) {
        let standIn = standIns[id] ?? StandIn()
        standIn.rect = rect
        standIn.path = nil
        standIn.container.frame = rect
        standIn.radius = image.radius / scale
        // The capture carries the window's own corners; the shadow follows
        // a path, so Core Animation need not render the stand-in offscreen.
        standIn.container.shadowOpacity = 0.3
        standIn.container.shadowRadius = 16
        standIn.container.shadowOffset = CGSize(width: 0, height: 10)
        standIn.container.shadowPath = shadow(rect.size, radius: standIn.radius)
        standIn.images.forEach { $0.removeFromSuperlayer() }
        standIn.images = [imageLayer(image, size: rect.size)]
        standIn.container.addSublayer(standIn.images[0])
        if standIn.container.superlayer == nil { canvas.addSublayer(standIn.container) }
        standIns[id] = standIn
    }

    /// The capture keeps its scale, anchored top-left: a frame that grows
    /// uncovers the window's own edge colour until the new capture fades in,
    /// and one that shrinks crops.
    private func imageLayer(_ image: Capture, size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.contents = image.contents
        layer.contentsScale = scale
        layer.contentsGravity = .topLeft
        layer.masksToBounds = true
        layer.cornerRadius = image.radius / scale
        layer.frame = CGRect(origin: .zero, size: size)
        let width = image.pixels.width / scale, height = image.pixels.height / scale
        for band in [CGRect(x: width, y: 0, width: 10_000, height: 10_000), CGRect(x: 0, y: height, width: 10_000, height: 10_000)] {
            let fill = CALayer()
            fill.frame = band
            fill.backgroundColor = image.edge
            layer.addSublayer(fill)
        }
        return layer
    }

    private var scale: CGFloat { NSScreen.screens.first?.backingScaleFactor ?? 2 }

    private func shadow(_ size: CGSize, radius: CGFloat) -> CGPath {
        let radius = min(radius, size.width / 2, size.height / 2)
        return CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// Keyframes along the path for the container and its images, which
    /// fill it at every sample.
    private func animate(_ standIn: StandIn, along path: Path) {
        let samples = (0...120).map { path.rect(Double($0) / 120) }, b = path.to
        func keyframes(_ key: String, _ value: (CGRect) -> NSValue) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = samples.map(value)
            animation.duration = path.duration
            animation.beginTime = path.begin
            animation.calculationMode = .linear
            animation.fillMode = .both
            return animation
        }
        standIn.motion = [
            keyframes("position") { NSValue(point: CGPoint(x: $0.midX, y: $0.midY)) },
            keyframes("bounds") { NSValue(rect: CGRect(origin: .zero, size: $0.size)) },
            keyframes("position") { NSValue(point: CGPoint(x: $0.width / 2, y: $0.height / 2)) },
            keyframes("bounds") { NSValue(rect: CGRect(origin: .zero, size: $0.size)) },
        ]
        let shadows = CAKeyframeAnimation(keyPath: "shadowPath")
        shadows.values = samples.map { shadow($0.size, radius: standIn.radius) }
        shadows.duration = path.duration; shadows.beginTime = path.begin
        shadows.calculationMode = .discrete; shadows.fillMode = .both
        standIn.path = path
        standIn.rect = b
        standIn.container.frame = b
        standIn.container.shadowPath = shadow(b.size, radius: standIn.radius)
        standIn.container.add(standIn.motion[0], forKey: "position")
        standIn.container.add(standIn.motion[1], forKey: "bounds")
        standIn.container.add(shadows, forKey: "shadowPath")
        for image in standIn.images {
            image.frame = CGRect(origin: .zero, size: b.size)
            image.add(standIn.motion[2], forKey: "position")
            image.add(standIn.motion[3], forKey: "bounds")
        }
    }

    /// A capture that arrives after its move joins it on the same clock.
    private func join(_ id: UInt32, image: Capture) {
        guard shown, standIns[id] == nil, let move = lastMove, let end = move.rects[id], let start = move.entering[id] else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place(id, image: image, at: start)
        animate(standIns[id]!, along: Path(from: start, to: end, begin: move.begin, duration: move.duration))
        CATransaction.commit()
    }

    private final class Cancel: ScheduledWork, @unchecked Sendable {
        private let work: DispatchWorkItem
        init(_ work: DispatchWorkItem) { self.work = work }
        func cancel() { work.cancel() }
    }
}

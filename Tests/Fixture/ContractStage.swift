import AppKit
import CoreGraphics
import IOSurface
import ScreenCaptureKit
import VideoToolbox

/// Native facts behind the motion stage: Screen Recording preflight, whole
/// captures of signed fixture windows, and a click-through overlay. Captures
/// are measured and dropped; no pixels leave this process.
@MainActor
final class FixtureStage {
    private var overlay: NSWindow?

    func preflight() -> [String: Any] {
        let start = CACurrentMediaTime()
        let first = CGPreflightScreenCaptureAccess(), second = CGPreflightScreenCaptureAccess()
        return ["screenRecording": first && second, "preflightStable": first == second,
                "preflightMilliseconds": (CACurrentMediaTime() - start) * 1_000]
    }

    /// Captures a fixture window sized from its live bounds and reports what
    /// came back, with the window's frame and the frontmost app around it.
    func capture(_ id: UInt32, pid: pid_t, display: Bool = false) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { throw FixtureContractError("grant Screen Recording to the signed fixture observer") }
        let before = fixtureCGFrames([pid])[id]?.frame ?? []
        let front = FixtureProbe.frontmostPID()
        // ScreenCaptureKit replies off the main thread; wait for it here.
        let box = CaptureBox(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await Self.capture(id, pid: pid, size: before, display: display)) }
            catch { box.result = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success, let result = box.result else { throw FixtureContractError("the capture did not return") }
        var facts = try result.get()
        facts["frameAfter"] = fixtureCGFrames([pid])[id]?.frame ?? []
        facts["frontmostBefore"] = front ?? 0
        facts["frontmostAfter"] = FixtureProbe.frontmostPID() ?? 0
        return ["stage": facts]
    }

    private final class CaptureBox: @unchecked Sendable { var result: Result<[String: Any], Error>? }

    private nonisolated static func capture(_ id: UInt32, pid: pid_t, size before: [Double], display: Bool) async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid }),
              before.count == 4 else { throw FixtureContractError("the fixture window is not shareable") }
        let filter: SCContentFilter
        let size: CGSize
        if display {
            guard let screen = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw FixtureContractError("the primary display is not shareable")
            }
            filter = SCContentFilter(display: screen, excludingWindows: content.windows.filter { $0.windowID != id })
            size = CGSize(width: screen.width, height: screen.height)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = CGSize(width: before[2], height: before[3])
        }
        let configuration = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        configuration.width = Int(size.width * scale); configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let start = CACurrentMediaTime()
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
        let elapsed = (CACurrentMediaTime() - start) * 1_000
        var facts: [String: Any] = ["scale": scale, "frameBefore": before, "captureMilliseconds": elapsed, "hasSurface": false]
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return facts }
        facts["hasSurface"] = true
        facts["captureSize"] = [IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface)]
        let locked = IOSurfaceLock(surface, .readOnly, nil)
        facts["lockResult"] = locked
        guard locked == kIOReturnSuccess else { return facts }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let readable = Int(bitPattern: IOSurfaceGetBaseAddress(surface)) != 0
        facts["readable"] = readable
        if readable {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            if let image { facts["opaque"] = opaqueShare(image) }
        }
        return facts
    }

    /// Shows a transparent, click-through overlay at floating level with one
    /// opaque band, and reports when WindowServer lists it, when the band
    /// reads back drawn from the window itself, and at what level.
    func showOverlay() -> [String: Any] {
        let front = FixtureProbe.frontmostPID()
        let frame = NSScreen.screens.first?.frame ?? .zero
        let window = overlay ?? NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let band = CALayer()
        band.frame = CGRect(x: 0, y: 0, width: frame.width, height: 40)
        band.backgroundColor = NSColor.systemPink.cgColor
        view.layer?.addSublayer(band)
        window.contentView = view
        window.setFrame(frame, display: false)
        overlay = window
        let start = CACurrentMediaTime()
        window.orderFrontRegardless()
        CATransaction.flush()
        var listed: [String: Any]?
        while listed == nil && CACurrentMediaTime() - start < 0.5 {
            listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).first {
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
            }
            if listed == nil { usleep(1_000) }
        }
        let listedAt = listed == nil ? -1 : (CACurrentMediaTime() - start) * 1_000
        var drawn = -1.0
        while drawn < 0 && CACurrentMediaTime() - start < 0.5 {
            if Self.bandDrawn(window.windowNumber, in: frame) { drawn = (CACurrentMediaTime() - start) * 1_000 } else { usleep(1_000) }
        }
        return ["stage": ["overlayListedMilliseconds": listedAt, "overlayDrawnMilliseconds": drawn,
                          "overlayLayer": (listed?[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                          "menuBarLayer": Int(CGWindowLevelForKey(.mainMenuWindow)),
                          "ignoresMouse": window.ignoresMouseEvents, "key": window.isKeyWindow,
                          "frontmostBefore": front ?? 0, "frontmostAfter": FixtureProbe.frontmostPID() ?? 0] as [String: Any]]
    }

    func hideOverlay() { overlay?.orderOut(nil) }

    /// One point of the band, read from the overlay window as WindowServer
    /// composites it. A process may read its own windows without Screen
    /// Recording; CGWindowListCreateImage is resolved at run time because
    /// Swift hides it since macOS 15.
    private static func bandDrawn(_ number: Int, in frame: CGRect) -> Bool {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard number > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return false }
        let point = CGRect(x: frame.midX, y: frame.maxY - 20, width: 1, height: 1)
        guard let image = unsafeBitCast(symbol, to: Create.self)(point, 1 << 3, UInt32(number), 1 << 4)?.takeRetainedValue() else { return false }
        return opaqueShare(image) > 0.5
    }

    private nonisolated static func opaqueShare(_ image: CGImage) -> Double {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let opaque = (0..<(side * side)).filter { pixels[$0 * 4 + 3] > 0 }.count
        return Double(opaque) / Double(side * side)
    }
}

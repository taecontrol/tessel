import AppKit
import ApplicationServices
import Darwin
import QuartzCore

/// Independent display-link sampling of signed fixture windows. No app policy
/// or adapters are linked here, and no titles or unrelated windows are sampled.
@MainActor
final class FixtureMotionProbe: NSObject {
    private var link: CADisplayLink?
    private var targets: [(id: UInt32, pid: pid_t, element: AXUIElement)] = []
    private var samples: [[String: Any]] = []
    private var frameCount = 0
    private var preferenceChanges: [Bool] = []
    private var observing = false
    private var originalPreference: Bool?
    private var originalPreferenceWasPresent = false
    private var pointerMonitor: Any?
    private var pointerPresses = 0
    private var pointerEvents: [String] = []

    func startPointer() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerPresses = 0
        pointerEvents.removeAll()
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.pointerEvents.append(event.type == .leftMouseDragged ? "drag" : "press")
                if event.type != .leftMouseDragged { self?.pointerPresses += 1 }
            }
        }
    }

    func reset() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        if let originalPreference {
            try? setReduceMotion(originalPreference)
            if !originalPreferenceWasPresent {
                CFPreferencesSetAppValue("reduceMotion" as CFString,nil,"com.apple.universalaccess" as CFString)
                CFPreferencesAppSynchronize("com.apple.universalaccess" as CFString)
            }
        }
        originalPreference = nil
        stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        targets.removeAll(); samples.removeAll(); frameCount = 0
        preferenceChanges.removeAll(); observing = false
    }
    func start(_ command: [String: Any]) throws {
        stop(); samples.removeAll(); frameCount = 0; targets.removeAll()
        for target in command["targets"] as? [[String: Any]] ?? [] {
            guard let pid = target["pid"] as? pid_t, FixtureProbe.isFixture(pid), let ids = target["ids"] as? [UInt32] else {
                throw FixtureContractError("motion sampling accepts signed fixture targets only")
            }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.05)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { throw FixtureContractError("motion targets have no AX window list") }
            for id in ids {
                guard let element = windows.first(where: { var number: UInt32 = 0; return fixtureWindowID($0, &number) == .success && number == id }) else {
                    throw FixtureContractError("motion target was not a signed fixture AX window")
                }
                AXUIElementSetMessagingTimeout(element, 0.01)
                targets.append((id,pid,element))
            }
        }
        guard let screen = NSScreen.screens.first else { throw FixtureContractError("display frame contract needs a screen") }
        let display = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link = display
        display.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    /// NSWorkspace reads HIServices' interface preference, not libAccessibility's
    /// iOS-style ReduceMotionEnabled setting. Its setter publishes the native
    /// display-options change; the test never posts a synthetic notification.
    func setReduceMotion(_ value: Bool) throws {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        guard let library = dlopen(path,RTLD_NOW | RTLD_LOCAL),
              let setter = dlsym(library,"_AXInterfaceSetReduceMotionEnabled") else {
            throw FixtureContractError("native macOS Reduce Motion setter unavailable")
        }
        if originalPreference == nil {
            originalPreference = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            originalPreferenceWasPresent = CFPreferencesCopyAppValue("reduceMotion" as CFString,"com.apple.universalaccess" as CFString) != nil
        }
        typealias SetPreference = @convention(c) (Int32) -> Void
        unsafeBitCast(setter,to:SetPreference.self)(value ? 1 : 0)
        dlclose(library)
    }
    func preferences() -> [String: Any] {
        if !observing {
            observing = true
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(preferencesChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        return ["reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "motionChanges": preferenceChanges]
    }
    func facts() -> [String: Any] {
        ["motionSamples": samples, "motionFrameCount": frameCount,
         "pointerPresses": pointerPresses,
         "pointerEvents": pointerEvents,
         "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "motionChanges": preferenceChanges,
         "sampledAt": Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9]
    }
    @objc private func preferencesChanged() { preferenceChanges.append(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
    @objc private func frame(_ display: CADisplayLink) {
        frameCount += 1
        guard samples.count < 64 else { return }
        let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        var appValue: CFTypeRef?, frontmost: pid_t = 0
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
           let value = appValue, CFGetTypeID(value) == AXUIElementGetTypeID() {
            AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &frontmost)
        }
        let windows: [[String: Any]] = targets.map { target in
            guard FixtureProbe.isFixture(target.pid) else { return ["id": target.id, "valid": false, "frame": [], "visible": false] }
            var position: CFTypeRef?, size: CFTypeRef?, point = CGPoint.zero, dimensions = CGSize.zero
            let a = AXUIElementCopyAttributeValue(target.element, kAXPositionAttribute as CFString, &position)
            let b = AXUIElementCopyAttributeValue(target.element, kAXSizeAttribute as CFString, &size)
            let valid = a == .success && b == .success && position.map { CFGetTypeID($0) == AXValueGetTypeID() } == true && size.map { CFGetTypeID($0) == AXValueGetTypeID() } == true
            if valid {
                AXValueGetValue(unsafeBitCast(position!, to: AXValue.self), .cgPoint, &point)
                AXValueGetValue(unsafeBitCast(size!, to: AXValue.self), .cgSize, &dimensions)
            }
            return ["id": target.id, "valid": valid, "frame": [point.x,point.y,dimensions.width,dimensions.height], "visible": order.contains(target.id)]
        }
        // CG order is restricted to targets before it crosses the observer socket.
        let ids = Set(targets.map(\.id))
        samples.append(["at": display.timestamp, "windows": windows, "order": order.filter { ids.contains($0) }, "frontmost": frontmost])
    }
}

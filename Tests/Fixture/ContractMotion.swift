import AppKit
import ApplicationServices
import Darwin
import QuartzCore

/// WindowServer metadata is available without Screen Recording and without an
/// AX round trip to a busy fixture. Never expose unrelated window descriptions.
@MainActor
func fixtureCGFrames(_ pids: Set<pid_t>) -> [UInt32: (pid: pid_t, frame: [Double])] {
    let trusted = pids.filter { FixtureProbe.isFixture($0) }
    var result: [UInt32: (pid: pid_t, frame: [Double])] = [:]
    for info in CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [] {
        guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, trusted.contains(pid),
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        result[id] = (pid, [frame.minX, frame.minY, frame.width, frame.height])
    }
    return result
}

/// Independent display-link sampling of signed fixture windows. No app policy
/// or adapters are linked here, and no titles or unrelated windows are sampled.
@MainActor
final class FixtureMotionProbe: NSObject {
    private var link: CADisplayLink?
    private var targets: [(id: UInt32, pid: pid_t, element: AXUIElement?)] = []
    private var samples: [[String: Any]] = []
    private var frameCount = 0
    private var capturesFocus = false
    private var discoveryPIDs: [pid_t] = []
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
        capturesFocus = command["capture"] as? Bool == true
        discoveryPIDs.removeAll()
        for target in command["targets"] as? [[String: Any]] ?? [] {
            guard let pid = target["pid"] as? pid_t, FixtureProbe.isFixture(pid), let ids = target["ids"] as? [UInt32] else {
                throw FixtureContractError("motion sampling accepts signed fixture targets only")
            }
            let application = AXUIElementCreateApplication(pid)
            if capturesFocus, command["discover"] as? Bool == true { discoveryPIDs.append(pid) }
            AXUIElementSetMessagingTimeout(application, FixtureProbe.observationTimeout)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { throw FixtureContractError("motion targets have no AX window list") }
            for id in ids {
                guard let element = windows.first(where: { var number: UInt32 = 0; return fixtureWindowID($0, &number) == .success && number == id }) else {
                    throw FixtureContractError("motion target was not a signed fixture AX window")
                }
                AXUIElementSetMessagingTimeout(element, capturesFocus ? 0.002 : FixtureProbe.observationTimeout)
                targets.append((id,pid,element))
            }
        }
        guard let screen = NSScreen.screens.first else { throw FixtureContractError("display frame contract needs a screen") }
        let display = screen.displayLink(target: self, selector: #selector(frame(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(screen.maximumFramesPerSecond),
                                                          preferred: Float(screen.maximumFramesPerSecond))
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
    func facts(draining: Bool = false) -> [String: Any] {
        defer { if draining { samples.removeAll(keepingCapacity: true) } }
        return ["motionSamples": samples, "motionFrameCount": frameCount,
         "pointerPresses": pointerPresses,
         "pointerEvents": pointerEvents,
         "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "motionChanges": preferenceChanges,
         "sampledAt": Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9]
    }
    @objc private func preferencesChanged() { preferenceChanges.append(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
    @objc private func frame(_ display: CADisplayLink) {
        let started = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        frameCount += 1
        guard samples.count < 64 else { return }
        var appValue: CFTypeRef?, frontmost: pid_t = 0
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, capturesFocus ? 0.002 : FixtureProbe.observationTimeout)
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
           let value = appValue, CFGetTypeID(value) == AXUIElementGetTypeID() {
            AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &frontmost)
        }
        // Geometry remains observable when a busy app cannot service AX.
        // Read it after focus so a slow focus answer cannot age the frames
        // before their matching WindowServer order is sampled below.
        let cg = targets.isEmpty ? [:] : fixtureCGFrames(Set(targets.map(\.pid)))
        // E10 discovery uses fixture-owned WindowServer IDs, so the first
        // published frame does not wait for the new window's AX enumeration.
        for (id, value) in cg.sorted(by: { $0.key < $1.key }) where discoveryPIDs.contains(value.pid) && !targets.contains(where: { $0.id == id }) {
            targets.append((id, value.pid, nil))
        }
        let windows: [[String: Any]] = targets.map { target in
            guard FixtureProbe.isFixture(target.pid) else { return ["id": target.id, "valid": false, "frame": [], "visible": false] }
            if let frame = cg[target.id], frame.pid == target.pid {
                return ["id": target.id, "valid": true, "frame": frame.frame, "source": "CG"]
            }
            guard let element = target.element else { return ["id": target.id, "valid": false, "frame": [], "visible": false] }
            var position: CFTypeRef?, size: CFTypeRef?, point = CGPoint.zero, dimensions = CGSize.zero
            let a = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
            let b = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
            let valid = a == .success && b == .success && position.map { CFGetTypeID($0) == AXValueGetTypeID() } == true && size.map { CFGetTypeID($0) == AXValueGetTypeID() } == true
            if valid {
                AXValueGetValue(unsafeBitCast(position!, to: AXValue.self), .cgPoint, &point)
                AXValueGetValue(unsafeBitCast(size!, to: AXValue.self), .cgSize, &dimensions)
            }
            return ["id": target.id, "valid": valid, "frame": [point.x,point.y,dimensions.width,dimensions.height], "source": "AX"]
        }
        // Read order after geometry. Otherwise the first moving positions can
        // be paired with preparation's earlier, unfinished AXRaise sequence.
        // CG order is restricted to targets before crossing the socket.
        let ids = Set(targets.map(\.id))
        let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        let observed = windows.map { window in
            var window = window
            window["visible"] = (window["id"] as? UInt32).map { order.contains($0) } ?? false
            return window
        }
        var sample: [String: Any] = ["at": display.timestamp, "startedAt": started, "frame": frameCount,
            "windows": observed, "order": order.filter { ids.contains($0) }, "frontmost": frontmost]
        if capturesFocus, FixtureProbe.isFixture(frontmost) {
            let application = AXUIElementCreateApplication(frontmost)
            AXUIElementSetMessagingTimeout(application, 0.002)
            var value: CFTypeRef?, focused: UInt32 = 0
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
               fixtureWindowID(unsafeBitCast(value, to: AXUIElement.self), &focused) == .success, ids.contains(focused) {
                sample["focused"] = focused
            }
        }
        sample["sampledAt"] = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        samples.append(sample)
    }
}

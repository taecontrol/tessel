import AppKit
import ApplicationServices
import Darwin

struct FixtureContractError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Raw native facts for simulator contracts. This observer never links policy
/// or the app's adapters, and revalidates each target before touching AX.
@MainActor
final class FixtureContracts: NSObject {
    private let motionProbe = FixtureMotionProbe()
    private let stage = FixtureStage()
    private let instantRecording = FixtureInstantRecording()
    private var handles: [UInt32: AXUIElement] = [:]
    private var bars: [AXUIElement] = []
    private var captured: [String: CFTypeRef] = [:]
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    /// The window handle a `watch` registered, compared with each notified element.
    private var watched: AXUIElement?
    private var events: [[String: Any]] = []
    /// Each event's notified element, matched against retained handles when read.
    private var eventElements: [AXUIElement] = []
    private var lifecycle: [[String: Any]] = []
    private var knownProcesses = Set<pid_t>()
    private var knownApplications: [pid_t: NSRunningApplication] = [:]
    private var lifecycleCounts: [String: Int] = [:]
    var spaces: FixtureSpaces?
    var moved = Set<UInt32>()

    func perform(_ command: [String: Any]) throws -> [String: Any] {
        let operation = command["operation"] as? String ?? "snapshot"
        switch operation {
        case "reset":
            motionProbe.reset()
            stage.hideOverlay()
            stopObserving()
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            spaces?.stop(returning: liveMovedWindows())
            spaces = nil
            moved.removeAll()
            handles.removeAll(); bars.removeAll(); captured.removeAll()
            events.removeAll(); eventElements.removeAll(); lifecycle.removeAll(); knownProcesses.removeAll()
            knownApplications.removeAll(); lifecycleCounts.removeAll()
            return [:]
        case "lifecycleStart":
            let names = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                         NSWorkspace.didUnhideApplicationNotification]
            for name in names {
                NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
            }
            return [:]
        case "lifecycle": return ["lifecycle": lifecycle, "lifecycleCounts": lifecycleCounts]
        case "events":
            // A window ID lookup can fail on a notified element mid-transition.
            // Identity with a retained window handle still names the window.
            let retained = handles.sorted { $0.key < $1.key }
            return ["events": zip(events, eventElements).map { event, element in
                var event = event
                event["handleID"] = retained.first { CFEqual($0.value, element) }?.key as Any? ?? NSNull()
                return event
            }]
        case "clearEvents": events.removeAll(); eventElements.removeAll(); return [:]
        case "finder", "activateFinder": return try finder(activate: operation == "activateFinder")
        case "foreground":
            // What holds the screen when a journey loses focus: the frontmost
            // app and the owners of on-screen windows, without titles.
            let front = NSWorkspace.shared.frontmostApplication
            let owners = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { window -> String? in
                    guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 0 else { return nil }
                    return "\(window[kCGWindowOwnerName as String] as? String ?? "?")@\(layer)"
                }
            return ["foreground": ["front \(front?.bundleIdentifier ?? front?.localizedName ?? "none")"] + owners]
        case "instantRecordingStart", "instantRecordingStop":
            guard let pids = command["pids"] as? [pid_t], !pids.isEmpty, pids.allSatisfy({ FixtureProbe.isFixture($0) }) else {
                throw FixtureContractError("instant recording accepts signed fixture processes only")
            }
            return try instantRecording.command(command)
        case "screenRecording": return stage.preflight()
        case "stageOverlayShow": return stage.showOverlay()
        case "stageOverlayHide": stage.hideOverlay(); return [:]
        case "screen":
            guard let screen = NSScreen.screens.first else { throw FixtureContractError("primary screen unavailable") }
            let full = screen.frame, visible = screen.visibleFrame, cg = CGDisplayBounds(CGMainDisplayID())
            return ["screen": rect(full), "visibleFrame": rect(visible), "cgDisplay": rect(cg),
                    "axVisibleFrame": [visible.minX, full.maxY - visible.maxY, visible.width, visible.height]]
        default: break
        }
        guard let pid = command["pid"] as? pid_t, FixtureProbe.isFixture(pid) else {
            throw FixtureContractError("contracts accept signed fixture processes only")
        }
        knownProcesses.insert(pid)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, FixtureProbe.observationTimeout)
        switch operation {
        case "metadata":
            let app = NSRunningApplication(processIdentifier: pid)
            knownApplications[pid] = app
            return ["alive": kill(pid, 0) == 0, "listed": NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == pid },
                    "bundleMatches": app?.bundleIdentifier == "com.taecontrol.tessel.fixture",
                    "regular": app?.activationPolicy == .regular, "prohibited": app?.activationPolicy == .prohibited,
                    "terminated": app?.isTerminated ?? true]
        case "activate":
            NSRunningApplication(processIdentifier: pid)?.activate()
            return [:]
        case "cgFrames":
            return ["cgFrames": Dictionary(uniqueKeysWithValues: fixtureCGFrames([pid]).map { (String($0.key), $0.value.frame) })]
        case "activateSelecting":
            // tessel's focus burst: activate the app, then make the window
            // main and raise it without waiting for the activation.
            let window = try retained(command, pid: pid)
            let results = [AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue),
                           AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue),
                           AXUIElementPerformAction(window, kAXRaiseAction as CFString)]
            return ["results": results.map(\.rawValue)]
        case "stageCapture":
            guard let id = command["id"] as? UInt32 else { throw FixtureContractError("a stage capture needs a window") }
            _ = try retained(["id": id], pid: pid)
            return try stage.capture(id, pid: pid, display: command["display"] as? Bool == true)
        case "motionStart": try motionProbe.start(command); return motionProbe.facts()
        case "motionStop": motionProbe.stop(); return motionProbe.facts()
        case "motionSamples": return motionProbe.facts(draining: command["drain"] as? Bool == true)
        case "motionSetPreference":
            guard let value = command["enabled"] as? Bool else { throw FixtureContractError("Reduce Motion needs a boolean") }
            try motionProbe.setReduceMotion(value); return motionProbe.preferences()
        case "motionPreferences": return motionProbe.preferences()
        case "pointerStart": motionProbe.startPointer(); return motionProbe.facts()
        case "pointerSamples": return motionProbe.facts()
        case "pointerPress":
            guard FixtureProbe.frontmostPID() == pid, let id = command["id"] as? UInt32, let window = handles[id],
                  let position = FixtureProbe.value(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = FixtureProbe.value(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID(),
                  (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).contains(where: {
                      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
                          && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                  }) else {
                throw FixtureContractError("pointer presses require a retained frontmost fixture window")
            }
            var point = CGPoint.zero, dimensions = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point); AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
            let oldPointer = CGEvent(source: nil)?.location
            var target = CGPoint(x: point.x + dimensions.width / 2, y: point.y + 12)
            if let requested = command["point"] as? [Double] {
                guard requested.count == 2, CGRect(origin: point, size: dimensions).contains(CGPoint(x: requested[0], y: requested[1])) else {
                    throw FixtureContractError("a pointer target must be inside the retained frontmost fixture")
                }
                target = CGPoint(x: requested[0], y: requested[1])
            }
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            if let oldPointer { CGWarpMouseCursorPosition(oldPointer) }
            return [:]
        case "enhancedUI":
            let attribute = "AXEnhancedUserInterface" as CFString
            var writeResult: AXError?
            if let enabled = command["enabled"] as? Bool {
                writeResult = AXUIElementSetAttributeValue(application, attribute, enabled ? kCFBooleanTrue : kCFBooleanFalse)
            }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, attribute, &value)
            // AppKit may apply this private attribute while answering
            // notImplemented. The readback, not that status, proves the Given.
            if let enabled = command["enabled"] as? Bool, (value as? Bool) != enabled {
                throw FixtureContractError("enhanced UI readback differs after write: \(writeResult?.rawValue ?? result.rawValue)")
            }
            return ["result": writeResult?.rawValue ?? result.rawValue, "enhancedUI": value as Any? ?? NSNull()]
        case "dragResize":
            let window = try retained(command, pid: pid)
            let values = frame(position: read(window, kAXPositionAttribute).value, size: read(window, kAXSizeAttribute).value)
            guard values.count == 4, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  fixtureCGFrames([pid])[id(window)] != nil else { throw FixtureContractError("drag needs a visible frontmost fixture") }
            let delta = command["delta"] as? Double ?? -100
            let start = CGPoint(x: values[0] + values[2] - 1, y: values[1] + values[3] / 2)
            let pointer = CGEvent(source: nil)?.location
            Task { @MainActor in
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
                for step in 1...20 {
                    try? await Task.sleep(for: .milliseconds(20))
                    let point = CGPoint(x: start.x + delta * Double(step) / 20, y: start.y)
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                let end = CGPoint(x: start.x + delta, y: start.y)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
                if let pointer { CGWarpMouseCursorPosition(pointer) }
            }
            return [:]
        case "windowListing":
            let window = try retained(command, pid: pid)
            guard let listed = PlacementSampler.windowServer(id(window)) else { return [:] }
            let frame = listed.bounds
            return ["windowListing": ["frame": [frame.minX, frame.minY, frame.width, frame.height], "onScreen": listed.onScreen]]
        case "placementGap": return try placementGap(command, application: application, pid: pid)
        case "snapshot": return snapshot(application, pid: pid)
        case "barOwner":
            guard let index = command["bar"] as? Int, bars.indices.contains(index) else { throw FixtureContractError("retain a native bar before reading its owner") }
            let owner = read(bars[index], kAXWindowAttribute)
            guard let window = element(owner.value) else { return ["readError": owner.error.rawValue] }
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(window, &ownerPID) == .success, ownerPID == pid else { throw FixtureContractError("native bar belongs to a different fixture") }
            return ["readError": owner.error.rawValue, "window": describe(window)]
        case "chrome", "publication", "activateAX":
            return try scenario(operation, command, application: application, pid: pid)
        case "retained":
            let window = try retained(command, pid: pid)
            return ["window": describe(window)]
        case "reacquire":
            let previous = try retained(command, pid: pid)
            guard let current = (read(application, kAXWindowsAttribute).value as? [AXUIElement])?.first(where: { CFEqual($0, previous) }) else {
                throw FixtureContractError("the retained fixture window is no longer listed")
            }
            handles[id(current)] = current
            return ["window": describe(current), "equal": CFEqual(current, previous)]
        case "capture":
            let window = try retained(command, pid: pid)
            captured = ["position": read(window, kAXPositionAttribute).value,
                        "size": read(window, kAXSizeAttribute).value,
                        "focused": read(application, kAXFocusedWindowAttribute).value].compactMapValues { $0 }
            return ["capturedCount": captured.count]
        case "readCapture":
            return ["capturedFrame": frame(position: captured["position"], size: captured["size"]),
                    "capturedFocus": element(captured["focused"]).map(id) ?? 0]
        case "writeSizeThenPosition":
            let window = try retained(command, pid: pid)
            guard let target = command["frame"] as? [Double], target.count == 4 else { throw FixtureContractError("paired geometry needs a native frame") }
            var point = CGPoint(x: target[0], y: target[1]), size = CGSize(width: target[2], height: target[3])
            let position = AXValueCreate(.cgPoint, &point)!, dimensions = AXValueCreate(.cgSize, &size)!
            let enhanced = "AXEnhancedUserInterface" as CFString
            let restore = command["disableEnhancedUI"] as? Bool == true && (read(application, enhanced as String).value as? Bool) == true
            if restore { _ = AXUIElementSetAttributeValue(application, enhanced, kCFBooleanFalse) }
            defer { if restore { _ = AXUIElementSetAttributeValue(application, enhanced, kCFBooleanTrue) } }
            // Keep both writes in one client burst, as in the app. Another
            // command/reply between them gives AppKit time to finish resizing.
            let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
            let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            // Match the app's readback before restoring the enhanced flag.
            return ["results": [sized.rawValue, moved.rawValue], "window": describe(window)]
        case "write":
            let window = try retained(command, pid: pid)
            let attribute = command["attribute"] as? String ?? ""
            let error: AXError
            switch attribute {
            case kAXMainAttribute: error = AXUIElementSetAttributeValue(window, attribute as CFString, kCFBooleanTrue)
            case kAXRaiseAction: error = AXUIElementPerformAction(window, attribute as CFString)
            case kAXPositionAttribute, kAXSizeAttribute:
                guard let values = command["value"] as? [Double], values.count == 2 else { throw FixtureContractError("geometry write requires two numbers") }
                var point = CGPoint(x: values[0], y: values[1]), size = CGSize(width: values[0], height: values[1])
                let value = attribute == kAXPositionAttribute ? AXValueCreate(.cgPoint, &point)! : AXValueCreate(.cgSize, &size)!
                error = AXUIElementSetAttributeValue(window, attribute as CFString, value)
            default: throw FixtureContractError("unsupported contract write")
            }
            let returnedAt = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
            return ["result": error.rawValue, "writeReturnedAt": returnedAt]
        case "timeout":
            let window = try retained(command, pid: pid)
            let timeout = command["seconds"] as? Float ?? FixtureProbe.observationTimeout
            let result = AXUIElementSetMessagingTimeout(window, timeout)
            return ["result": result.rawValue, "readError": read(window, kAXRoleAttribute).error.rawValue]
        case "watch":
            stopObserving()
            observedPID = pid
            watched = command["id"] == nil ? nil : try retained(command, pid: pid)
            var created: AXObserver?
            let status = AXObserverCreate(pid, { _, element, name, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<FixtureContracts>.fromOpaque(context).takeUnretainedValue().received(name as String, element: element)
                }
            }, &created)
            guard status == .success, let created else { return ["result": status.rawValue] }
            observer = created
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            return try registrations(command, application: application, pid: pid, removing: false)
        case "add", "remove": return try registrations(command, application: application, pid: pid, removing: operation == "remove")
        case "identity":
            let window = try retained(command, pid: pid)
            let current = (read(application, kAXWindowsAttribute).value as? [AXUIElement] ?? []).first { id($0) == id(window) }
            return ["equal": current.map { CFEqual(window, $0) && CFHash(window) == CFHash($0) } ?? false]
        case "spaces", "closetStart", "closetHide", "closetShow", "closetStop":
            if spaces == nil { spaces = try FixtureSpaces() }
            let ids = command["ids"] as? [UInt32] ?? []
            // Foreign CG IDs are rejected even when a signed target PID was supplied.
            for number in ids {
                let window = try retained(["id": number], pid: pid)
                guard id(window) == number, read(window, kAXRoleAttribute).error == .success else {
                    throw FixtureContractError("native Space operations require a live fixture window")
                }
            }
            guard let spaces else { throw FixtureContractError("native Space probe unavailable") }
            switch operation {
            case "closetStart": try spaces.start()
            case "closetHide": spaces.move(ids, to: spaces.closet); moved.formUnion(ids)
            case "closetShow": spaces.move(ids, to: spaces.active); moved.subtract(ids)
            case "closetStop": spaces.stop(returning: liveMovedWindows()); moved.removeAll()
            default: break
            }
            return ["activeSpace": spaces.active, "closetSpace": spaces.closet,
                    "memberships": ids.map { ["id": $0, "ordinary": spaces.memberships($0, mask: 7), "all": spaces.memberships($0, mask: 0xF)] as [String: Any] }]
        default: throw FixtureContractError("unknown native contract operation")
        }
    }

    @objc private func applicationChanged(_ notification: Notification) {
        lifecycleCounts[notification.name.rawValue, default: 0] += 1
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        let known = knownApplications.keys.sorted().first { knownApplications[$0]?.isEqual(app) == true }
        guard known != nil || knownProcesses.contains(pid) || app.bundleIdentifier == "com.taecontrol.tessel.fixture" && FixtureProbe.isFixture(pid) else { return }
        knownProcesses.insert(pid)
        if known == nil { knownApplications[pid] = app }
        lifecycle.append(["name": notification.name.rawValue, "pid": pid, "knownPID": known ?? pid, "mainThread": Thread.isMainThread,
                          "alivePIDs": knownProcesses.sorted().filter { kill($0, 0) == 0 }])
    }

    private func received(_ name: String, element: AXUIElement) {
        guard FixtureProbe.isFixture(observedPID) else { return }
        let application = AXUIElementCreateApplication(observedPID)
        AXUIElementSetMessagingTimeout(application, FixtureProbe.observationTimeout)
        let focused = read(application, kAXFocusedWindowAttribute), focus = self.element(focused.value)
        // A window ID lookup can fail on the notified element mid-transition;
        // record the error and the element's identity separately from the ID.
        var number: UInt32 = 0
        let idError = fixtureWindowID(element, &number)
        events.append(["name": name, "id": number, "idError": idError.rawValue,
                       "registered": watched.map { CFEqual($0, element) } as Any? ?? NSNull(), "mainThread": Thread.isMainThread,
                       "focusedID": focus.map(id) as Any? ?? NSNull(), "focusedError": focused.error.rawValue,
                       "minimized": read(element, kAXMinimizedAttribute).value as? Bool as Any? ?? NSNull()])
        eventElements.append(element)
    }

    private func registrations(_ command: [String: Any], application: AXUIElement, pid: pid_t, removing: Bool) throws -> [String: Any] {
        guard let observer, observedPID == pid else { throw FixtureContractError("no observer for the requested fixture") }
        let allowed = [kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXFocusedWindowChangedNotification,
                       kAXMainWindowChangedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                       kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                       kAXLayoutChangedNotification, kAXValueChangedNotification]
        let names = command["notifications"] as? [String] ?? []
        guard !names.isEmpty, names.allSatisfy(allowed.contains) else { throw FixtureContractError("unsupported contract notification") }
        let target: AXUIElement
        if command["id"] == nil { target = application }
        else {
            let original = try retained(command, pid: pid)
            if command["operation"] as? String == "watch" { target = original }
            else {
                guard let equal = (read(application, kAXWindowsAttribute).value as? [AXUIElement])?.first(where: { CFEqual($0, original) }) else {
                    throw FixtureContractError("the registered fixture window is no longer listed")
                }
                target = equal
            }
        }
        let results = names.map { name in
            removing ? AXObserverRemoveNotification(observer, target, name as CFString).rawValue
                : AXObserverAddNotification(observer, target, name as CFString, Unmanaged.passUnretained(self).toOpaque()).rawValue
        }
        return ["results": results]
    }

    private func stopObserving() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observedPID = 0
        watched = nil
    }

    private func liveMovedWindows() -> [UInt32] {
        moved.sorted().filter { number in
            guard let window = handles[number] else { return false }
            var pid: pid_t = 0
            return AXUIElementGetPid(window, &pid) == .success && FixtureProbe.isFixture(pid)
                && id(window) == number && read(window, kAXRoleAttribute).error == .success
        }
    }

    func retained(_ command: [String: Any], pid: pid_t) throws -> AXUIElement {
        guard let number = command["id"] as? UInt32, let window = handles[number] else { throw FixtureContractError("retain a fixture window snapshot before this operation") }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { throw FixtureContractError("retained window belongs to a different fixture") }
        return window
    }

    func snapshot(_ application: AXUIElement, pid: pid_t) -> [String: Any] {
        let list = read(application, kAXWindowsAttribute)
        let roots = list.value as? [AXUIElement] ?? []
        let focused = read(application, kAXFocusedWindowAttribute), focus = element(focused.value)
        let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { item -> UInt32? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
            return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return ["listError": list.error.rawValue, "listIsArray": list.value is [AXUIElement],
                "windows": roots.map(describe), "focused": focus.map(describe) as Any? ?? NSNull(), "focusedError": focused.error.rawValue,
                "hidden": read(application, kAXHiddenAttribute).value as? Bool as Any? ?? NSNull(),
                "frontmost": read(application, kAXFrontmostAttribute).value as? Bool as Any? ?? NSNull(),
                "visibleIDs": visible]
    }

    func describe(_ window: AXUIElement) -> [String: Any] {
        AXUIElementSetMessagingTimeout(window, FixtureProbe.observationTimeout)
        var number: UInt32 = 0
        let idError = fixtureWindowID(window, &number)
        if number != 0, handles[number] == nil { handles[number] = window }
        let role = read(window, kAXRoleAttribute), subrole = read(window, kAXSubroleAttribute)
        var owner: pid_t = 0
        let ownerError = AXUIElementGetPid(window, &owner)
        let layer: Int?
        if idError == .success, number != 0, ownerError == .success {
            // Read the requested ID through the same CG API as production,
            // independently of the on-screen list and current native Space.
            var pointer = UnsafeRawPointer(bitPattern: UInt(number))
            let ids = CFArrayCreate(nil, &pointer, 1, nil)
            let descriptions = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] ?? []
            layer = descriptions.first { info in
                (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner
                    && (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number
            }.flatMap { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue }
        } else {
            layer = nil
        }
        let position = read(window, kAXPositionAttribute), size = read(window, kAXSizeAttribute)
        let minimized = read(window, kAXMinimizedAttribute), fullscreen = read(window, "AXFullScreen"), main = read(window, kAXMainAttribute)
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
        let children = read(window, kAXChildrenAttribute).value as? [AXUIElement] ?? []
        let native = FixtureProbe.tabGroups(window).compactMap { group -> (AXUIElement, [AXUIElement])? in
            let tabs = read(group, kAXTabsAttribute).value as? [AXUIElement] ?? []
            let contents = read(group, kAXContentsAttribute).value as? [AXUIElement] ?? []
            return !tabs.isEmpty && tabs.allSatisfy { tab in contents.contains { CFEqual(tab, $0) } } ? (group, tabs) : nil
        }.first
        var bar: Int?
        if let native {
            if let index = bars.firstIndex(where: { CFEqual($0, native.0) }) { bar = index }
            else { bar = bars.count; bars.append(native.0) }
        }
        return ["id": number, "idError": idError.rawValue,
                "role": role.value as? String as Any? ?? NSNull(), "roleError": role.error.rawValue,
                "subrole": subrole.value as? String as Any? ?? NSNull(), "subroleError": subrole.error.rawValue,
                "layer": layer as Any? ?? NSNull(),
                "frame": frame(position: position.value, size: size.value), "frameError": position.error.rawValue,
                "minimized": minimized.value as? Bool as Any? ?? NSNull(), "minimizedError": minimized.error.rawValue,
                "fullscreen": fullscreen.value as? Bool as Any? ?? NSNull(), "fullscreenError": fullscreen.error.rawValue,
                "main": main.value as? Bool as Any? ?? NSNull(), "mainError": main.error.rawValue,
                "sizeSettable": settable.boolValue, "settableError": settableError.rawValue,
                "bar": bar as Any? ?? NSNull(), "tabs": native?.1.count ?? 0,
                "sheets": children.filter { read($0, kAXRoleAttribute).value as? String == kAXSheetRole }.map(describe)]
    }

    private func finder(activate: Bool) throws -> [String: Any] {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              FixtureProbe.hasSignature(finder.processIdentifier, identifier: "com.apple.finder") else { throw FixtureContractError("signed Finder unavailable") }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, FixtureProbe.observationTimeout)
        let list = read(application, kAXWindowsAttribute)
        let windows = list.value as? [AXUIElement] ?? []
        let desktops = windows.filter { read($0, kAXRoleAttribute).value as? String == kAXScrollAreaRole }
        let safe = list.error == .success && list.value is [AXUIElement] && windows.count == desktops.count
        if activate && safe { finder.activate() }
        let desktop = desktops.first
        let focus = element(read(application, kAXFocusedWindowAttribute).value)
        return ["finderSafe": safe, "desktopRole": desktop.flatMap { read($0, kAXRoleAttribute).value as? String } as Any? ?? NSNull(),
                "desktopID": desktop.map(id) as Any? ?? NSNull(),
                "desktopSubroleError": desktop.map { read($0, kAXSubroleAttribute).error.rawValue } as Any? ?? NSNull(),
                "finderFocused": desktop.flatMap { desktop in focus.map { CFEqual(desktop, $0) } } ?? false,
                "finderFrontmost": FixtureProbe.frontmostPID() == finder.processIdentifier]
    }

    func read(_ element: AXUIElement, _ attribute: String) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }
    func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func id(_ window: AXUIElement) -> UInt32 {
        var number: UInt32 = 0
        _ = fixtureWindowID(window, &number)
        return number
    }
    private func frame(position: CFTypeRef?, size: CFTypeRef?) -> [Double] {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return [] }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return [] }
        return [point.x, point.y, dimensions.width, dimensions.height]
    }
    private func rect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
}

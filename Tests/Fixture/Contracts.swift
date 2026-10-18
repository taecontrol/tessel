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
    private var handles: [UInt32: AXUIElement] = [:]
    private var bars: [AXUIElement] = []
    private var captured: [String: CFTypeRef] = [:]
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var events: [[String: Any]] = []
    private var lifecycle: [[String: Any]] = []
    private var knownProcesses = Set<pid_t>()
    private var knownApplications: [pid_t: NSRunningApplication] = [:]
    private var lifecycleCounts: [String: Int] = [:]
    private var spaces: FixtureSpaces?
    private var moved = Set<UInt32>()

    func perform(_ command: [String: Any]) throws -> [String: Any] {
        let operation = command["operation"] as? String ?? "snapshot"
        switch operation {
        case "reset":
            stopObserving()
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            spaces?.stop(returning: liveMovedWindows())
            spaces = nil
            moved.removeAll()
            handles.removeAll(); bars.removeAll(); captured.removeAll()
            events.removeAll(); lifecycle.removeAll(); knownProcesses.removeAll()
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
        case "events": return ["events": events]
        case "clearEvents": events.removeAll(); return [:]
        case "finder", "activateFinder": return try finder(activate: operation == "activateFinder")
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
        case "snapshot": return snapshot(application, pid: pid)
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
            return ["result": error.rawValue]
        case "timeout":
            let window = try retained(command, pid: pid)
            let timeout = command["seconds"] as? Float ?? FixtureProbe.observationTimeout
            let result = AXUIElementSetMessagingTimeout(window, timeout)
            return ["result": result.rawValue, "readError": read(window, kAXRoleAttribute).error.rawValue]
        case "watch":
            stopObserving()
            observedPID = pid
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
        lifecycle.append(["name": notification.name.rawValue, "pid": pid, "knownPID": known ?? pid, "mainThread": Thread.isMainThread])
    }

    private func received(_ name: String, element: AXUIElement) {
        guard FixtureProbe.isFixture(observedPID) else { return }
        events.append(["name": name, "id": id(element), "mainThread": Thread.isMainThread,
                       "minimized": read(element, kAXMinimizedAttribute).value as? Bool as Any? ?? NSNull()])
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
    }

    private func liveMovedWindows() -> [UInt32] {
        moved.sorted().filter { number in
            guard let window = handles[number] else { return false }
            var pid: pid_t = 0
            return AXUIElementGetPid(window, &pid) == .success && FixtureProbe.isFixture(pid)
                && id(window) == number && read(window, kAXRoleAttribute).error == .success
        }
    }

    private func retained(_ command: [String: Any], pid: pid_t) throws -> AXUIElement {
        guard let number = command["id"] as? UInt32, let window = handles[number] else { throw FixtureContractError("retain a fixture window snapshot before this operation") }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { throw FixtureContractError("retained window belongs to a different fixture") }
        return window
    }

    private func snapshot(_ application: AXUIElement, pid: pid_t) -> [String: Any] {
        let list = read(application, kAXWindowsAttribute)
        let roots = list.value as? [AXUIElement] ?? []
        let focus = element(read(application, kAXFocusedWindowAttribute).value)
        let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { item -> UInt32? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
            return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return ["listError": list.error.rawValue, "listIsArray": list.value is [AXUIElement],
                "windows": roots.map(describe), "focused": focus.map(describe) as Any? ?? NSNull(),
                "hidden": read(application, kAXHiddenAttribute).value as? Bool as Any? ?? NSNull(),
                "frontmost": read(application, kAXFrontmostAttribute).value as? Bool as Any? ?? NSNull(),
                "visibleIDs": visible]
    }

    private func describe(_ window: AXUIElement) -> [String: Any] {
        AXUIElementSetMessagingTimeout(window, FixtureProbe.observationTimeout)
        var number: UInt32 = 0
        let idError = fixtureWindowID(window, &number)
        if number != 0, handles[number] == nil { handles[number] = window }
        let role = read(window, kAXRoleAttribute), subrole = read(window, kAXSubroleAttribute)
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

    private func read(_ element: AXUIElement, _ attribute: String) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func id(_ window: AXUIElement) -> UInt32 {
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

import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
final class WindowCatalog: NSObject {
    private let store: SnapshotStore
    private var apps: [pid_t: AppWindows] = [:]

    init(store: SnapshotStore) {
        self.store = store
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(self, selector: #selector(appChanged(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        for app in NSWorkspace.shared.runningApplications { observe(app) }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid(), !app.isTerminated, app.activationPolicy != .prohibited else { return }
        if let existing = apps[pid] { existing.refresh(hidden: app.isHidden); return }
        let generation = UUID()
        let worker = AppWindows(pid: pid, name: app.localizedName ?? "Application", bundleId: app.bundleIdentifier ?? "",
                                hidden: app.isHidden, generation: generation) { [weak self] rows in
            DispatchQueue.main.async {
                guard let self, self.apps[pid]?.generation == generation else { return }
                self.store.update(pid: pid, windows: rows)
            }
        }
        apps[pid] = worker
        worker.start()
    }

    @objc private func appChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { observe(app) }
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        apps.removeValue(forKey: app.processIdentifier)?.stop()
        store.update(pid: app.processIdentifier, windows: nil)
    }
}

private enum AXReadError: Error { case unresponsive, gone }

private struct WindowFacts {
    let id: UInt32
    let minimized: Bool
    let subrole: String
    let resizable: Bool
    let tabs: Int

    func record(app: String, bundleId: String, hidden: Bool) -> WindowRecord {
        let state: WindowState
        var reason: String
        if minimized { state = .minimized; reason = "minimized" }
        else if hidden { state = .hidden; reason = "application hidden" }
        else if subrole != kAXStandardWindowSubrole { state = .floats; reason = subrole }
        else if !resizable { state = .floats; reason = "fixed size" }
        else { state = .tiled; reason = "standard window" }
        if tabs > 1 { reason += "; \(tabs) native tabs" }
        return WindowRecord(id: id, app: app, bundleId: bundleId, state: state, reason: reason, tabs: tabs)
    }
}

/// Each app owns a serial AX queue. A timeout or partial read preserves its last
/// complete snapshot, while other apps and the CLI continue independently.
private final class AppWindows: @unchecked Sendable {
    let generation: UUID
    private let pid: pid_t
    private let name: String
    private let bundleId: String
    private let queue: DispatchQueue
    private let publish: @Sendable ([WindowRecord]) -> Void
    // All mutable state below belongs to queue, including AX handles.
    private let application: AXUIElement
    private var observer: AXObserver?
    private var observed: [AXUIElement] = []
    private var appNotifications: Set<String> = []
    private var facts: [WindowFacts] = []
    private var hidden: Bool
    private var stopped = false
    private var pending: DispatchWorkItem?

    init(pid: pid_t, name: String, bundleId: String, hidden: Bool, generation: UUID,
         publish: @escaping @Sendable ([WindowRecord]) -> Void) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
        self.hidden = hidden
        self.generation = generation
        self.publish = publish
        application = AXUIElementCreateApplication(pid)
        queue = DispatchQueue(label: "tessel.ax.\(pid)", qos: .userInitiated)
    }

    func start() {
        queue.async { [self] in
            AXUIElementSetMessagingTimeout(application, 0.05)
            var value: AXObserver?
            let result = AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<AppWindows>.fromOpaque(context).takeUnretainedValue().refresh()
            }, &value)
            if result == .success, let value {
                observer = value
                let source = AXObserverGetRunLoopSource(value)
                // Keep the owner alive until the source has been removed at stop.
                DispatchQueue.main.async { [self] in
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                    withExtendedLifetime(self) {}
                }
            }
            readSnapshot()
            // A launched app can expose AX only after its first AppKit turn.
            for milliseconds in [50, 150, 300, 450] { settle(after: milliseconds) }
        }
    }

    func refresh(hidden: Bool? = nil) {
        queue.async { [self] in
            guard !stopped else { return }
            if let hidden { self.hidden = hidden }
            pending?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.readSnapshot() }
            pending = item
            queue.asyncAfter(deadline: .now() + .milliseconds(10), execute: item)
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending?.cancel()
            if let observer {
                let source = AXObserverGetRunLoopSource(observer)
                DispatchQueue.main.async { [self] in
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                    withExtendedLifetime(self) {}
                }
            }
            observer = nil
            observed.removeAll()
        }
    }

    private func settle(after milliseconds: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in self?.readSnapshot() }
    }

    private func readSnapshot() {
        guard !stopped else { return }
        registerApplicationNotifications()
        do {
            guard let windows = try value(application, kAXWindowsAttribute) as? [AXUIElement] else { return }
            var next: [WindowFacts] = []
            var elements: [AXUIElement] = []
            for window in windows {
                do {
                    try inspect(window, into: &next, elements: &elements)
                } catch AXReadError.gone { continue }
            }
            let oldIDs = Set(facts.map(\.id))
            let newIDs = Set(next.map(\.id))
            facts = next
            updateWindowNotifications(elements)
            publish(facts.map { $0.record(app: name, bundleId: bundleId, hidden: hidden) })
            if !newIDs.subtracting(oldIDs).isEmpty {
                for milliseconds in [100, 250, 450] { settle(after: milliseconds) }
            }
        } catch {
            // A failed read is not a classification signal, nor proof of closure.
            publish(facts.map { $0.record(app: name, bundleId: bundleId, hidden: hidden) })
        }
    }

    private func inspect(_ window: AXUIElement, into result: inout [WindowFacts], elements: inout [AXUIElement]) throws {
        var id: CGWindowID = 0
        try check(axWindowID(window, &id))
        guard id != 0, !result.contains(where: { $0.id == id }) else { return }
        AXUIElementSetMessagingTimeout(window, 0.05)
        let minimized = try value(window, kAXMinimizedAttribute) as? Bool ?? false
        let subrole = try value(window, kAXSubroleAttribute) as? String ?? "AXUnknown"
        var resizable = DarwinBoolean(false)
        try check(AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable))
        var sheets: [AXUIElement] = []
        var tabGroups: [AXUIElement] = []
        var visited = 0
        let tabs = try chrome(window, depth: 0, visited: &visited, sheets: &sheets, groups: &tabGroups)
        result.append(WindowFacts(id: id, minimized: minimized, subrole: subrole, resizable: resizable.boolValue, tabs: max(1, tabs)))
        elements.append(window)
        elements.append(contentsOf: tabGroups)
        for sheet in sheets { try inspect(sheet, into: &result, elements: &elements) }
    }

    /// Read roles and tab counts in the window chrome, never text or titles.
    /// Bound the walk and skip content trees such as web areas and text fields.
    private func chrome(_ element: AXUIElement, depth: Int, visited: inout Int,
                        sheets: inout [AXUIElement], groups: inout [AXUIElement]) throws -> Int {
        guard depth < 5, visited < 64 else { return 0 }
        visited += 1
        let role = try value(element, kAXRoleAttribute) as? String ?? ""
        if role == kAXTabGroupRole {
            groups.append(element)
            return (try value(element, kAXTabsAttribute) as? [AXUIElement])?.count ?? 0
        }
        if depth > 0, role == kAXSheetRole { sheets.append(element); return 0 }
        guard !["AXWebArea", "AXScrollArea", "AXTextArea", "AXTextField", "AXTable", "AXOutline"].contains(role) else { return 0 }
        let children = try value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var count = 0
        for child in children.prefix(64 - visited) {
            count = max(count, try chrome(child, depth: depth + 1, visited: &visited, sheets: &sheets, groups: &groups))
        }
        return count
    }

    private func registerApplicationNotifications() {
        guard let observer else { return }
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXSheetCreatedNotification] {
            guard !appNotifications.contains(name) else { continue }
            if AXObserverAddNotification(observer, application, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success {
                appNotifications.insert(name)
            }
        }
    }

    private func updateWindowNotifications(_ elements: [AXUIElement]) {
        guard let observer else { return }
        let names = [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXWindowResizedNotification, kAXLayoutChangedNotification, kAXValueChangedNotification]
        for old in observed where !elements.contains(where: { CFEqual(old, $0) }) {
            for name in names { AXObserverRemoveNotification(observer, old, name as CFString) }
        }
        for element in elements where !observed.contains(where: { CFEqual(element, $0) }) {
            for name in names { AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque()) }
        }
        observed = elements
    }

    private func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        var result: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(element, attribute as CFString, &result))
        return result
    }

    private func check(_ error: AXError) throws {
        if error == .cannotComplete || error == .apiDisabled { throw AXReadError.unresponsive }
        if error == .invalidUIElement { throw AXReadError.gone }
    }
}

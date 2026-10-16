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
    private var windowSubscriptions = AXSubscriptions([
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXWindowResizedNotification, kAXLayoutChangedNotification, kAXValueChangedNotification
    ])
    private var appSubscriptions = AXSubscriptions([
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification, kAXSheetCreatedNotification
    ])
    private var facts: [WindowFacts] = []
    private var hidden: Bool
    private var stopped = false
    private var pending: DispatchWorkItem?
    private var settleGeneration: UInt64 = 0

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
            let result = AXObserverCreate(pid, { _, _, notification, context in
                guard let context else { return }
                Unmanaged<AppWindows>.fromOpaque(context).takeUnretainedValue().changed(notification as String)
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
            beginSettling()
        }
    }

    private func changed(_ notification: String) {
        let needsSettling = [kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXMainWindowChangedNotification].contains(notification)
        refresh(settle: needsSettling)
    }

    func refresh(hidden: Bool? = nil, settle: Bool = false) {
        queue.async { [self] in
            guard !stopped else { return }
            if let hidden { self.hidden = hidden }
            if settle { beginSettling() }
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
            windowSubscriptions.removeAll()
            appSubscriptions.removeAll()
        }
    }

    private func beginSettling() {
        settleGeneration += 1
        let generation = settleGeneration
        for milliseconds in [50, 150, 300, 450] {
            queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
                guard let self, !self.stopped, self.settleGeneration == generation else { return }
                self.readSnapshot()
            }
        }
    }

    private func readSnapshot() {
        guard !stopped else { return }
        updateSubscriptions([application], using: &appSubscriptions)
        do {
            guard let windows = try value(application, kAXWindowsAttribute) as? [AXUIElement] else { return }
            var next: [WindowFacts] = []
            var elements = windows
            // Subscribe even if an animation makes this snapshot incomplete.
            // Otherwise a newly created window can finish minimizing unseen.
            defer { updateSubscriptions(elements, using: &windowSubscriptions) }
            for window in windows {
                do {
                    try inspect(window, into: &next, elements: &elements)
                } catch AXReadError.gone { continue }
            }
            let oldIDs = Set(facts.map(\.id))
            let newIDs = Set(next.map(\.id))
            facts = next
            publish(facts.map { $0.record(app: name, bundleId: bundleId, hidden: hidden) })
            if !newIDs.subtracting(oldIDs).isEmpty {
                beginSettling()
            }
        } catch {
            // A failed read is not a classification signal, nor proof of closure.
            publish(facts.map { $0.record(app: name, bundleId: bundleId, hidden: hidden) })
        }
    }

    private func inspect(_ window: AXUIElement, into result: inout [WindowFacts], elements: inout [AXUIElement]) throws {
        if !elements.contains(where: { CFEqual($0, window) }) { elements.append(window) }
        AXUIElementSetMessagingTimeout(window, 0.05)
        var id: CGWindowID = 0
        try check(axWindowID(window, &id))
        guard id != 0, !result.contains(where: { $0.id == id }) else { return }
        let minimized = try value(window, kAXMinimizedAttribute) as? Bool ?? false
        let subrole = try value(window, kAXSubroleAttribute) as? String ?? "AXUnknown"
        var resizable = DarwinBoolean(false)
        try check(AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable))
        var sheets: [AXUIElement] = []
        var tabGroups: [AXUIElement] = []
        var visited = 0
        let tabs = try chrome(window, depth: 0, visited: &visited, sheets: &sheets, groups: &tabGroups)
        result.append(WindowFacts(id: id, minimized: minimized, subrole: subrole, resizable: resizable.boolValue, tabs: max(1, tabs)))
        elements.append(contentsOf: tabGroups)
        for sheet in sheets { try inspect(sheet, into: &result, elements: &elements) }
    }

    /// Read roles and tab counts in the window chrome, never text or titles.
    /// Bound the walk and skip content trees such as web areas and text fields.
    private func chrome(_ element: AXUIElement, depth: Int, visited: inout Int,
                        sheets: inout [AXUIElement], groups: inout [AXUIElement]) throws -> Int {
        guard depth < 5, visited < 64 else { return 0 }
        visited += 1
        AXUIElementSetMessagingTimeout(element, 0.05)
        let role = try value(element, kAXRoleAttribute) as? String ?? ""
        if role == kAXTabGroupRole {
            let tabs = try value(element, kAXTabsAttribute) as? [AXUIElement] ?? []
            guard !tabs.isEmpty else { return 0 }
            let contents = try value(element, kAXContentsAttribute) as? [AXUIElement] ?? []
            // AppKit's native tab bar includes its tab buttons in AXContents.
            // NSTabView instead publishes the selected page's content there.
            // A native New Tab button may also occur, so count only AXTabs.
            guard tabs.allSatisfy({ tab in contents.contains { CFEqual(tab, $0) } }) else { return 0 }
            groups.append(element)
            return tabs.count
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

    private func updateSubscriptions(_ elements: [AXUIElement], using subscriptions: inout AXSubscriptions) {
        guard let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        subscriptions.update(elements, add: { element, name in
            AXObserverAddNotification(observer, element, name as CFString, context)
        }, remove: { element, name in
            AXObserverRemoveNotification(observer, element, name as CFString)
        })
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

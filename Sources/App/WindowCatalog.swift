import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowObservation: Sendable {
    var record: WindowRecord
    let frame: CGRect
    let parent: UInt32?
    var replaces: UInt32? = nil
}

enum CatalogChange: Sendable, Equatable { case snapshot, activation, focus, restored }

@MainActor
final class WindowCatalog: NSObject {
    private let workspaces: Workspaces
    private let fixtureOnly: Bool
    private var apps: [pid_t: AppWindows] = [:]

    init(workspaces: Workspaces, fixtureOnly: Bool) {
        self.workspaces = workspaces
        self.fixtureOnly = fixtureOnly
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
        guard !fixtureOnly || app.bundleIdentifier == "com.taecontrol.tessel.fixture" else { return }
        if let existing = apps[pid] { existing.refresh(hidden: app.isHidden); return }
        let generation = UUID()
        let worker = AppWindows(pid: pid, name: app.localizedName ?? "Application", bundleId: app.bundleIdentifier ?? "",
                                hidden: app.isHidden, generation: generation) { [weak self] rows, focused, frontmost, change in
            DispatchQueue.main.async {
                guard let self, self.apps[pid]?.generation == generation else { return }
                self.workspaces.update(pid: pid, observations: rows, focused: focused, frontmost: frontmost, change: change)
            }
        }
        apps[pid] = worker
        worker.start()
    }

    @objc private func appChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            if notification.name == NSWorkspace.didHideApplicationNotification { apps[app.processIdentifier]?.cancelPresentation() }
            observe(app)
            if notification.name == NSWorkspace.didActivateApplicationNotification {
                apps[app.processIdentifier]?.refresh(change: .activation)
            }
        }
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        apps.removeValue(forKey: app.processIdentifier)?.stop()
        workspaces.remove(pid: app.processIdentifier)
    }

    func present(pid: pid_t, id: UInt32, area: CGRect?, focus: Bool,
                 completion: @escaping @MainActor @Sendable () -> Void) {
        apps[pid]?.present(id: id, area: area, focus: focus, completion: completion)
    }

    func cancelPresentations() { apps.values.forEach { $0.cancelPresentation() } }
}

private enum AXReadError: Error { case unresponsive, gone, changed }

/// Retain the callback's immutable handle while handing it to its app's queue.
private struct AXNotificationElement: @unchecked Sendable { let value: AXUIElement }

private struct WindowFacts {
    let id: UInt32
    let minimized: Bool
    let fullscreen: Bool
    let subrole: String
    let resizable: Bool
    let tabs: Int
    let frame: CGRect
    let parent: UInt32?
    let nativeTabGroups: [AXUIElement]

    func sharesNativeTabs(with other: WindowFacts) -> Bool {
        nativeTabGroups.contains { group in other.nativeTabGroups.contains { CFEqual(group, $0) } }
    }

    func record(app: String, bundleId: String, hidden: Bool) -> WindowRecord {
        let state: WindowState
        var reason: String
        if fullscreen { state = .fullscreen; reason = "native fullscreen" }
        else if minimized { state = .minimized; reason = "minimized" }
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
    private let publish: @Sendable ([WindowObservation], UInt32?, Bool, CatalogChange) -> Void
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
    private var hiddenHint: Bool
    private var stopped = false
    private var pending: DispatchWorkItem?
    private var settleGeneration: UInt64 = 0
    private var failedReads = 0
    private var elementsByID: [UInt32: AXUIElement] = [:]
    private var change = CatalogChange.snapshot
    private let presentationLock = NSLock()
    private var presentation = UUID()
    private var constrained = Set<UInt32>()
    private struct Validation {
        let area: CGRect
        let token: UUID
        let completion: @MainActor @Sendable () -> Void
    }
    private var validations: [UInt32: Validation] = [:]

    init(pid: pid_t, name: String, bundleId: String, hidden: Bool, generation: UUID,
         publish: @escaping @Sendable ([WindowObservation], UInt32?, Bool, CatalogChange) -> Void) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
        self.hidden = hidden
        self.hiddenHint = hidden
        self.generation = generation
        self.publish = publish
        application = AXUIElementCreateApplication(pid)
        queue = DispatchQueue(label: "tessel.ax.\(pid)", qos: .userInitiated, autoreleaseFrequency: .workItem)
    }

    func start() {
        queue.async { [self] in
            AXUIElementSetMessagingTimeout(application, 0.05)
            var value: AXObserver?
            let result = AXObserverCreate(pid, { _, element, notification, context in
                guard let context else { return }
                Unmanaged<AppWindows>.fromOpaque(context).takeUnretainedValue().changed(notification as String, element: element)
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

    private func changed(_ notification: String, element: AXUIElement) {
        // A closing window can still be listed by the read that follows its event.
        let needsSettling = [kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXMainWindowChangedNotification,
                             kAXUIElementDestroyedNotification].contains(notification)
        let change: CatalogChange = notification == kAXWindowDeminiaturizedNotification ? .restored
            : [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification].contains(notification) ? .focus : .snapshot
        if notification == kAXWindowResizedNotification {
            let handle = AXNotificationElement(value: element)
            queue.async { [self] in
                guard !validations.isEmpty else { return }
                AXUIElementSetMessagingTimeout(handle.value, 0.05)
                var id: UInt32 = 0
                _ = axWindowID(handle.value, &id)
                validatePresentation(id: id)
            }
        }
        refresh(settle: needsSettling, change: change)
    }

    func refresh(hidden: Bool? = nil, settle: Bool = false, change: CatalogChange = .snapshot) {
        queue.async { [self] in
            guard !stopped else { return }
            if let hidden { self.hiddenHint = hidden }
            if change == .activation || self.change != .activation && change != .snapshot { self.change = change }
            if settle { beginSettling() }
            failedReads = 0
            scheduleRead(after: 10)
        }
    }

    private func scheduleRead(after milliseconds: Int) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.readSnapshot() }
        pending = item
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
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
            var handles: [UInt32: AXUIElement] = [:]
            var elements = windows
            // Subscribe even if an animation makes this snapshot incomplete.
            // Otherwise a newly created window can finish minimizing unseen.
            defer { updateSubscriptions(elements, using: &windowSubscriptions) }
            // Read hide state alongside the windows; NSWorkspace's notification
            // can lag behind AX. Its cached value is a fallback for missing AXHidden.
            hidden = try value(application, kAXHiddenAttribute) as? Bool ?? hiddenHint
            for window in windows {
                do {
                    try inspect(window, into: &next, elements: &elements, handles: &handles)
                } catch AXReadError.gone { continue }
            }
            // AppKit can omit live windows during Space moves, fullscreen and
            // app hide/unhide. Revalidate known handles; a different native tab
            // front is identified by the bar retained from its previous root.
            var omitted: [AXUIElement] = []
            var focusedElement: AXUIElement?
            if let focused = try value(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = focused as! AXUIElement
                focusedElement = element
                omitted.append(element)
            }
            omitted += elementsByID.values
            for window in omitted where !elements.contains(where: { CFEqual($0, window) }) {
                let cached = facts.first { fact in elementsByID[fact.id].map { CFEqual($0, window) } == true }
                if let cached, next.contains(where: { $0.id != cached.id && $0.sharesNativeTabs(with: cached) }) { continue }
                // AppKit publishes every minimized tab, then only the selected
                // window after restore. Its focused window is checked above.
                let isFocused = focusedElement.map { CFEqual($0, window) } == true
                if cached?.minimized == true && !hidden && !isFocused { continue }
                do {
                    try inspect(window, into: &next, elements: &elements, handles: &handles, parent: cached?.parent)
                } catch AXReadError.gone { continue }
            }
            // Tab selection and insertion can replace AXWindows while the
            // focused window is being inspected. Never commit a mixed read:
            // its intermediate tab root would look like an ordinary window.
            guard let confirmed = try value(application, kAXWindowsAttribute) as? [AXUIElement],
                  windows.count == confirmed.count,
                  windows.allSatisfy({ window in confirmed.contains { CFEqual(window, $0) } }) else {
                throw AXReadError.changed
            }
            // AXWindows may still include the former tab root before the
            // focused replacement is read. Retire it using the previous bar
            // identity, before the new snapshot loses that relationship.
            let retired = Set(facts.filter { cached in
                next.contains { $0.id != cached.id && !$0.minimized && $0.sharesNativeTabs(with: cached) }
            }.map(\.id))
            next.removeAll { retired.contains($0.id) }
            let replacements = Dictionary(uniqueKeysWithValues: next.compactMap { window -> (UInt32, UInt32)? in
                guard let previous = facts.first(where: { retired.contains($0.id) && window.sharesNativeTabs(with: $0) }) else { return nil }
                return (window.id, previous.id)
            })
            let oldIDs = Set(facts.map(\.id))
            let newIDs = Set(next.map(\.id))
            facts = next
            elementsByID = handles.filter { newIDs.contains($0.key) }
            constrained.formIntersection(newIDs)
            validations = validations.filter { newIDs.contains($0.key) }
            failedReads = 0
            publishSnapshot(replacing: replacements)
            if !newIDs.subtracting(oldIDs).isEmpty {
                beginSettling()
            }
        } catch {
            // A failed read is not a classification signal, nor proof of closure.
            if !facts.isEmpty { publishSnapshot() }
            // A busy app can time out the only read after its last event. Back off
            // a few times, then wait for the next event so a hung app costs nothing.
            if failedReads < 4 {
                failedReads += 1
                scheduleRead(after: 50 << failedReads)
            }
        }
    }

    private func inspect(_ window: AXUIElement, into result: inout [WindowFacts], elements: inout [AXUIElement],
                         handles: inout [UInt32: AXUIElement], parent: UInt32? = nil) throws {
        if !elements.contains(where: { CFEqual($0, window) }) { elements.append(window) }
        AXUIElementSetMessagingTimeout(window, 0.05)
        var id: CGWindowID = 0
        try check(axWindowID(window, &id))
        guard id != 0, !result.contains(where: { $0.id == id }) else { return }
        let minimized = try value(window, kAXMinimizedAttribute) as? Bool ?? false
        let fullscreen = try value(window, "AXFullScreen") as? Bool ?? false
        let subrole = try value(window, kAXSubroleAttribute) as? String ?? "AXUnknown"
        var resizable = DarwinBoolean(false)
        try check(AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable))
        var sheets: [AXUIElement] = []
        var tabGroups: [AXUIElement] = []
        var visited = 0
        let tabs = try chrome(window, depth: 0, visited: &visited, sheets: &sheets, groups: &tabGroups)
        let frame = try frame(window)
        handles[id] = window
        result.append(WindowFacts(id: id, minimized: minimized, fullscreen: fullscreen, subrole: subrole,
                                  resizable: resizable.boolValue, tabs: max(1, tabs), frame: frame, parent: parent, nativeTabGroups: tabGroups))
        elements.append(contentsOf: tabGroups)
        for sheet in sheets { try inspect(sheet, into: &result, elements: &elements, handles: &handles, parent: id) }
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

    private func publishSnapshot(replacing replacements: [UInt32: UInt32] = [:]) {
        var focused: UInt32 = 0
        if let element = try? value(application, kAXFocusedWindowAttribute), CFGetTypeID(element) == AXUIElementGetTypeID() {
            _ = axWindowID(element as! AXUIElement, &focused)
        }
        let frontmost = (try? value(application, kAXFrontmostAttribute) as? Bool) == true
        let observations = facts.map { fact in
            var record = fact.record(app: name, bundleId: bundleId, hidden: hidden)
            if record.state == .tiled, constrained.contains(fact.id) {
                record.state = .floats
                record.reason = "cannot fill the screen"
            }
            return WindowObservation(record: record, frame: fact.frame, parent: fact.parent, replaces: replacements[fact.id])
        }
        publish(observations, focused == 0 ? nil : focused, frontmost, change)
        change = .snapshot
    }

    private func frame(_ window: AXUIElement) throws -> CGRect {
        var point = CGPoint.zero, size = CGSize.zero
        if let value = try value(window, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            _ = AXValueGetValue(value as! AXValue, .cgPoint, &point)
        }
        if let value = try value(window, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            _ = AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: point, size: size)
    }

    func cancelPresentation() {
        presentationLock.withLock { presentation = UUID() }
    }

    func present(id: UInt32, area: CGRect?, focus: Bool, completion: @escaping @MainActor @Sendable () -> Void) {
        let token = presentationLock.withLock { presentation }
        queue.async { [self] in
            guard !stopped, presentationLock.withLock({ presentation == token }), let window = elementsByID[id] else { return }
            do {
                guard try canPresent(window) else { return }
                if let area {
                    var origin = area.origin, size = area.size
                    try check(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!))
                    try check(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!))
                    if try checkSize(window, area: area) { constrained.insert(id) } else { constrained.remove(id) }
                    validations[id] = Validation(area: area, token: token, completion: completion)
                    queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.validatePresentation(id: id, token: token) }
                }
                guard presentationLock.withLock({ presentation == token }), try canPresent(window) else { return }
                if focus {
                    try check(AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue))
                    guard presentationLock.withLock({ presentation == token }) else { return }
                    try check(AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue))
                    guard presentationLock.withLock({ presentation == token }) else { return }
                    try check(AXUIElementPerformAction(window, kAXRaiseAction as CFString))
                }
                publishSnapshot()
                DispatchQueue.main.async { completion() }
            } catch { /* Keep the last complete classification when the app is busy. */ }
        }
    }

    private func checkSize(_ window: AXUIElement, area: CGRect) throws -> Bool {
        let accepted = try frame(window)
        guard accepted.width > 0, accepted.height > 0 else { throw AXReadError.unresponsive }
        let cannotFill = abs(accepted.width - area.width) > 2 || abs(accepted.height - area.height) > 2
        if cannotFill {
            var center = CGPoint(x: area.midX - accepted.width / 2, y: area.midY - accepted.height / 2)
            try check(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &center)!))
        }
        return cannotFill
    }

    private func validatePresentation(id: UInt32, token: UUID? = nil) {
        guard let pending = validations[id], token == nil || token == pending.token else { return }
        validations[id] = nil
        guard presentationLock.withLock({ presentation == pending.token }), let window = elementsByID[id],
              (try? canPresent(window)) == true,
              let cannotFill = try? checkSize(window, area: pending.area) else { return }
        if cannotFill { constrained.insert(id) } else { constrained.remove(id) }
        publishSnapshot()
        DispatchQueue.main.async { pending.completion() }
    }

    /// Native hide, minimize, and fullscreen can begin between a snapshot and a
    /// queued write. Never let an old presentation undo the user's operation.
    private func canPresent(_ window: AXUIElement) throws -> Bool {
        guard !hidden, try value(application, kAXHiddenAttribute) as? Bool != true,
              try value(window, kAXMinimizedAttribute) as? Bool != true,
              try value(window, "AXFullScreen") as? Bool != true else { return false }
        return true
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

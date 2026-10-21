import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

struct WindowObservation: Sendable {
    var record: WindowRecord
    let frame: CGRect
    let parent: UInt32?
    var replaces: UInt32? = nil
}

enum CatalogChange: Sendable, Equatable { case snapshot, activation, focus, restored }

@MainActor
final class WindowCatalog {
    private let workspaces: Workspaces
    private let fixtureBundleID: String?
    private let applications: any ApplicationPort
    private let ax: any AccessibilityPort
    private let scheduler: any SchedulingPort
    private var lifecycle: (any ApplicationObservation)?
    private var apps: [Int32: AppWindows] = [:]

    init(workspaces: Workspaces, applications: any ApplicationPort, ax: any AccessibilityPort,
         scheduler: any SchedulingPort, fixtureBundleID: String? = nil) {
        self.workspaces = workspaces
        self.applications = applications
        self.ax = ax
        self.scheduler = scheduler
        self.fixtureBundleID = fixtureBundleID
        lifecycle = applications.observe { [weak self] event, app in self?.appChanged(event, app: app) }
        for app in applications.runningApplications { observe(app) }
    }

    private func observe(_ app: RunningApplication) {
        let pid = app.pid
        guard pid != applications.ownPID, !app.terminated, !app.prohibited else { return }
        guard fixtureBundleID == nil || app.bundleID == fixtureBundleID else { return }
        if let existing = apps[pid] { existing.refresh(hidden: app.hidden); return }
        let generation = UUID()
        let worker = AppWindows(pid: pid, name: app.name ?? "Application", bundleId: app.bundleID ?? "",
                                hidden: app.hidden, generation: generation, ax: ax, scheduler: scheduler) { [weak self, scheduler] rows, focused, frontmost, change, activation in
            scheduler.main.async {
                guard let self, let worker = self.apps[pid], worker.generation == generation else { return }
                // An activation can wait behind a newer keyboard selection in
                // either queue. Its facts remain valid; its old intent does not.
                let received: CatalogChange = change == .activation && !worker.ownsFocusIntent(activation) ? .snapshot : change
                self.workspaces.update(pid: pid, observations: rows, focused: focused, frontmost: frontmost, change: received)
            }
        }
        apps[pid] = worker
        worker.start()
    }

    private func appChanged(_ event: ApplicationEvent, app: RunningApplication) {
        if event == .terminated {
            apps.removeValue(forKey: app.pid)?.stop()
            workspaces.remove(pid: app.pid)
            return
        }
        if event == .hidden { apps[app.pid]?.cancelPresentation() }
        observe(app)
        if event == .activated { apps[app.pid]?.refresh(change: .activation) }
    }

    func present(pid: Int32, id: UInt32, area: CGRect?, focus: Bool,
                 completion: @escaping @MainActor @Sendable () -> Void) {
        guard let app = apps[pid] else { completion(); return }
        app.present(id: id, area: area, focus: focus, completion: completion)
    }

    func presentRail(pid: Int32, id: UInt32, frame: CGRect?, position: Bool, resize: Bool, focus: Bool, screenRight: CGFloat,
                     completion: @escaping @MainActor @Sendable (CGRect?) -> Void) {
        guard let app = apps[pid] else { completion(nil); return }
        app.presentRail(id:id,target:frame,position:position,resize:resize,focus:focus,screenRight:screenRight,completion:completion)
    }

    func windowIsGone(pid: Int32, id: UInt32, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let app = apps[pid] else { completion(false); return }
        app.windowIsGone(id: id, completion: completion)
    }

    func returnInside(ids: Set<UInt32>, area: CGRect) { apps.keys.sorted().compactMap { apps[$0] }.forEach { $0.returnInside(ids:ids,area:area) } }

    func cancelPresentations(invalidatingFocus: Bool = true) {
        apps.keys.sorted().compactMap { apps[$0] }.forEach { $0.cancelPresentation(invalidatingFocus: invalidatingFocus) }
    }
}

private enum AXReadError: Error { case unresponsive, gone, changed }

private struct WindowFacts {
    let id: UInt32
    let minimized: Bool
    var fullscreen: Bool
    let subrole: String
    let resizable: Bool
    let tabs: Int
    var frame: CGRect
    let parent: UInt32?
    let nativeTabGroups: [AXElement]

    func shares(_ groups: [AXElement]) -> Bool {
        nativeTabGroups.contains { group in groups.contains { group == $0 } }
    }

    func record(app: String, bundleId: String, hidden: Bool) -> WindowRecord {
        let state: WindowState
        var reason: String
        if fullscreen { state = .fullscreen; reason = "native fullscreen" }
        else if minimized { state = .minimized; reason = "minimized" }
        else if hidden { state = .hidden; reason = "application hidden" }
        else if subrole != "AXStandardWindow" { state = .floats; reason = subrole }
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
    private let pid: Int32
    private let name: String
    private let bundleId: String
    private let queue: any SerialLane
    private let ax: any AccessibilityPort
    private let scheduler: any SchedulingPort
    private let publish: @Sendable ([WindowObservation], UInt32?, Bool, CatalogChange, UUID?) -> Void
    // All mutable state below belongs to queue, including AX handles.
    private let application: AXElement
    private var observer: (any AXObservation)?
    private var windowSubscriptions = ElementSubscriptions<AXElement, AXNotification>([
        .destroyed, .minimized, .restored,
        .moved, .resized, .layoutChanged, .valueChanged
    ])
    private var appSubscriptions = ElementSubscriptions<AXElement, AXNotification>([
        .windowCreated, .focusedWindowChanged,
        .mainWindowChanged, .sheetCreated
    ])
    private var facts: [WindowFacts] = []
    // The last native bar of each listed root, kept for an unfocused root that
    // lost it and for a retired root while a listed window still holds it.
    private var nativeBars: [UInt32: [AXElement]] = [:]
    private var hidden: Bool
    private var hiddenHint: Bool
    private var stopped = false
    private var pending: (any ScheduledWork)?
    private var settleGeneration: UInt64 = 0
    private var failedReads = 0
    private var elementsByID: [UInt32: AXElement] = [:]
    private var change = CatalogChange.snapshot
    private var activationToken: UUID?
    private let presentationLock: any PolicyLock
    private var presentation = UUID()
    // Geometry can supersede queued writes without superseding a native
    // selection whose activation facts have not arrived yet.
    private var focusIntent = UUID()
    private var railActivationCheck: (token: UUID, work: any ScheduledWork)?
    // AppKit can finish an activation after AX accepted it and then make the
    // app's previous key window key again over tessel's request.
    private var awaitedActivation: (intent: UUID, id: UInt32, expiry: any ScheduledWork)?
    private var constrained = Set<UInt32>()
    private struct Validation {
        let area: CGRect
        let token: UUID
        let completion: @MainActor @Sendable () -> Void
    }
    private var validations: [UInt32: Validation] = [:]

    init(pid: Int32, name: String, bundleId: String, hidden: Bool, generation: UUID,
         ax: any AccessibilityPort, scheduler: any SchedulingPort,
         publish: @escaping @Sendable ([WindowObservation], UInt32?, Bool, CatalogChange, UUID?) -> Void) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
        self.hidden = hidden
        self.hiddenHint = hidden
        self.generation = generation
        self.publish = publish
        self.ax = ax
        self.scheduler = scheduler
        presentationLock = scheduler.makeLock()
        application = ax.application(pid)
        queue = scheduler.serialLane(label: "tessel.ax.\(pid)")
    }

    func start() {
        queue.async { [self] in
            ax.setMessagingTimeout(application, seconds: 0.05)
            let result = ax.observer(pid) { [weak self] notification, element in
                self?.changed(notification, element: element)
            }
            if result.status == .success, let value = result.value {
                observer = value
                // Keep the owner alive until the source has been removed at stop.
                scheduler.main.async { [self] in
                    value.start()
                    withExtendedLifetime(self) {}
                }
            }
            readSnapshot()
            // A launched app can expose AX only after its first AppKit turn.
            beginSettling()
        }
    }

    private func changed(_ notification: AXNotification, element: AXElement) {
        queue.async { [self] in
            guard !stopped else { return }
            handleChange(notification, element: element)
        }
    }

    private func handleChange(_ notification: AXNotification, element: AXElement) {
        // A closing window can still be listed by the read that follows its event.
        let needsSettling = [.windowCreated, .sheetCreated, .mainWindowChanged,
                             .destroyed].contains(notification)
        let change: CatalogChange = notification == .restored ? .restored
            : [.focusedWindowChanged, .mainWindowChanged].contains(notification) ? .focus : .snapshot
        if notification == .resized {
            let handle = element
            queue.async { [self] in
                guard !validations.isEmpty else { return }
                ax.setMessagingTimeout(handle, seconds: 0.05)
                let id = ax.windowID(handle).value ?? 0
                validatePresentation(id: id)
            }
        }
        refresh(settle: needsSettling, change: change)
    }

    func refresh(hidden: Bool? = nil, settle: Bool = false, change: CatalogChange = .snapshot) {
        let activation = change == .activation ? presentationLock.withLock { focusIntent } : nil
        queue.async { [self] in
            guard !stopped else { return }
            if let hidden { self.hiddenHint = hidden }
            if change == .activation {
                self.activationToken = activation
                self.railActivationCheck?.work.cancel()
                self.railActivationCheck = nil
            }
            if change == .activation || self.change != .activation && change != .snapshot { self.change = change }
            if settle { beginSettling() }
            failedReads = 0
            scheduleRead(after: 10)
        }
    }

    private func scheduleRead(after milliseconds: Int) {
        pending?.cancel()
        pending = queue.after(milliseconds: milliseconds) { [weak self] in self?.readSnapshot() }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            railActivationCheck?.work.cancel()
            railActivationCheck = nil
            pending?.cancel()
            if let observer {
                scheduler.main.async { [self] in
                    observer.stop()
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
            queue.after(milliseconds: milliseconds) { [weak self] in
                guard let self, !self.stopped, self.settleGeneration == generation else { return }
                self.readSnapshot()
            }
        }
    }

    private func readSnapshot() {
        guard !stopped else { return }
        updateSubscriptions([application], using: &appSubscriptions)
        do {
            guard let windows = try value(application, .windows)?.elements else { return }
            var next: [WindowFacts] = []
            var handles: [UInt32: AXElement] = [:]
            var elements = windows
            // Subscribe even if an animation makes this snapshot incomplete.
            // Otherwise a newly created window can finish minimizing unseen.
            defer { updateSubscriptions(elements, using: &windowSubscriptions) }
            // Read hide state alongside the windows; NSWorkspace's notification
            // can lag behind AX. Its cached value is a fallback for missing AXHidden.
            hidden = try value(application, .hidden)?.bool ?? hiddenHint
            for window in windows {
                do {
                    try inspect(window, into: &next, elements: &elements, handles: &handles)
                } catch AXReadError.gone { continue }
            }
            // AppKit can omit live windows during Space moves, fullscreen and
            // app hide/unhide. Revalidate known handles; a different native tab
            // front is identified by the bar retained from its previous root.
            var omitted: [AXElement] = []
            var focusedElement: AXElement?
            if let element = try value(application, .focusedWindow)?.element {
                focusedElement = element
                omitted.append(element)
            }
            omitted += elementsByID.keys.sorted().compactMap { elementsByID[$0] }
            for window in omitted where !elements.contains(where: { $0 == window }) {
                let cached = facts.first { fact in elementsByID[fact.id].map { $0 == window } == true }
                if let cached, next.contains(where: { $0.id != cached.id && $0.shares(cached.nativeTabGroups) }) { continue }
                // AppKit publishes every minimized tab, then only the selected
                // window after restore. Its focused window is checked above.
                let isFocused = focusedElement.map { $0 == window } == true
                do {
                    // Only restored background tabs disappear from AXWindows.
                    // A still-minimized omitted handle remains a live window.
                    if cached?.minimized == true && !hidden && !isFocused,
                       try value(window, .minimized)?.bool == false { continue }
                    try inspect(window, into: &next, elements: &elements, handles: &handles, parent: cached?.parent)
                } catch AXReadError.gone { continue }
            }
            // Tab selection and insertion can replace AXWindows while the
            // focused window is being inspected. Never commit a mixed read:
            // its intermediate tab root would look like an ordinary window.
            guard let confirmed = try value(application, .windows)?.elements,
                  windows.count == confirmed.count,
                  windows.allSatisfy({ window in confirmed.contains { window == $0 } }) else {
                throw AXReadError.changed
            }
            // AXWindows may still include the former tab root before the
            // focused replacement is read. Retire it using the previous bar
            // identity, before the new snapshot loses that relationship.
            let oldIDs = Set(facts.map(\.id))
            // A root without a bar remembers the bar it last showed, until it is
            // focused: a background tab cannot be, but a detached window can.
            let focusedID = focusedElement.flatMap { element in handles.first { $0.value == element }?.key }
            func lastBar(_ id: UInt32) -> [AXElement] { id == focusedID ? [] : nativeBars[id] ?? [] }
            let retired = Set(facts.filter { cached in
                let bar = cached.nativeTabGroups.isEmpty ? lastBar(cached.id) : cached.nativeTabGroups
                return next.contains { $0.id != cached.id && !$0.minimized && $0.shares(bar) }
            }.map(\.id))
            // AXWindows can keep listing a retired root after its successor's
            // read. It stays retired while another window holds its last bar.
            let stillRetired = Set(next.filter { window in
                !oldIDs.contains(window.id) && !window.minimized && window.nativeTabGroups.isEmpty
                    && next.contains { $0.id != window.id && !$0.minimized && $0.shares(lastBar(window.id)) }
            }.map(\.id))
            next.removeAll { retired.contains($0.id) || stillRetired.contains($0.id) }
            let replacements = Dictionary(uniqueKeysWithValues: next.compactMap { window -> (UInt32, UInt32)? in
                guard let previous = facts.first(where: {
                    retired.contains($0.id) && window.shares($0.nativeTabGroups.isEmpty ? lastBar($0.id) : $0.nativeTabGroups)
                })
                else { return nil }
                return (window.id, previous.id)
            })
            let newIDs = Set(next.map(\.id))
            // A former root can also lose its bar in a read that cannot identify
            // its successor yet, because focus or the moved bar is unpublished.
            // Keep each root's last bar while its group is listed.
            var bars: [UInt32: [AXElement]] = [:]
            for fact in next where !fact.minimized {
                let bar = fact.nativeTabGroups.isEmpty ? lastBar(fact.id) : fact.nativeTabGroups
                if !bar.isEmpty { bars[fact.id] = bar }
            }
            for (id, groups) in nativeBars where !newIDs.contains(id) && next.contains(where: { !$0.minimized && $0.shares(groups) }) {
                bars[id] = groups
            }
            nativeBars = bars
            facts = next
            elementsByID = handles.filter { newIDs.contains($0.key) }
            // The last fill result belongs to the continuing native group.
            // Selecting a tab preserves it until the next ordinary show retries.
            for (id, previous) in replacements where constrained.contains(previous) {
                constrained.insert(id)
            }
            constrained.formIntersection(newIDs)
            validations = validations.filter { newIDs.contains($0.key) }
            failedReads = 0
            publishSnapshot(replacing: replacements)
            if !newIDs.subtracting(oldIDs).isEmpty {
                beginSettling()
            }
        } catch {
            // A failed read is not a classification signal, nor proof of closure.
            // Keep the published snapshot and pending change. Republishing it
            // would query the same busy app for focus and frontmost state again.
            // A busy app can time out the only read after its last event. Back off
            // a few times, then wait for the next event so a hung app costs nothing.
            if failedReads < 4 {
                failedReads += 1
                scheduleRead(after: 50 << failedReads)
            }
        }
    }

    private func inspect(_ window: AXElement, into result: inout [WindowFacts], elements: inout [AXElement],
                         handles: inout [UInt32: AXElement], parent: UInt32? = nil) throws {
        if !elements.contains(where: { $0 == window }) { elements.append(window) }
        ax.setMessagingTimeout(window, seconds: 0.05)
        let identifier = ax.windowID(window)
        try check(identifier.status)
        let id = identifier.value ?? 0
        if id == 0 {
            if elementsByID.values.contains(where: { $0 == window }) {
                // A closed AppKit handle's ID lookup can report illegalArgument.
                // Revalidate it before treating a zero ID as an incomplete read.
                _ = try value(window, .role)
                throw AXReadError.changed
            }
            return
        }
        guard !result.contains(where: { $0.id == id }) else { return }
        let minimized = try value(window, .minimized)?.bool ?? false
        let fullscreen = try value(window, .fullscreen)?.bool ?? false
        let subrole = try value(window, .subrole)?.string ?? "AXUnknown"
        let resizable = ax.isSettable(.size, of: window)
        try check(resizable.status)
        var sheets: [AXElement] = []
        var tabGroups: [AXElement] = []
        var visited = 0
        let tabs = try chrome(window, depth: 0, visited: &visited, sheets: &sheets, groups: &tabGroups)
        let frame = try frame(window)
        handles[id] = window
        result.append(WindowFacts(id: id, minimized: minimized, fullscreen: fullscreen, subrole: subrole,
                                  resizable: resizable.value ?? false, tabs: max(1, tabs), frame: frame, parent: parent, nativeTabGroups: tabGroups))
        elements.append(contentsOf: tabGroups)
        for sheet in sheets { try inspect(sheet, into: &result, elements: &elements, handles: &handles, parent: id) }
    }

    /// Read roles and tab counts in the window chrome, never text or titles.
    /// Bound the walk and skip content trees such as web areas and text fields.
    private func chrome(_ element: AXElement, depth: Int, visited: inout Int,
                        sheets: inout [AXElement], groups: inout [AXElement]) throws -> Int {
        guard depth < 5, visited < 64 else { return 0 }
        visited += 1
        ax.setMessagingTimeout(element, seconds: 0.05)
        let role = try value(element, .role)?.string ?? ""
        if role == "AXTabGroup" {
            let tabs = try value(element, .tabs)?.elements ?? []
            guard !tabs.isEmpty else { return 0 }
            let contents = try value(element, .contents)?.elements ?? []
            // AppKit's native tab bar includes its tab buttons in AXContents.
            // NSTabView instead publishes the selected page's content there.
            // A native New Tab button may also occur, so count only AXTabs.
            guard tabs.allSatisfy({ tab in contents.contains { tab == $0 } }) else { return 0 }
            groups.append(element)
            return tabs.count
        }
        if depth > 0, role == "AXSheet" { sheets.append(element); return 0 }
        guard !["AXWebArea", "AXScrollArea", "AXTextArea", "AXTextField", "AXTable", "AXOutline"].contains(role) else { return 0 }
        let children = try value(element, .children)?.elements ?? []
        var count = 0
        for child in children.prefix(64 - visited) {
            count = max(count, try chrome(child, depth: depth + 1, visited: &visited, sheets: &sheets, groups: &groups))
        }
        return count
    }

    private func updateSubscriptions(_ elements: [AXElement], using subscriptions: inout ElementSubscriptions<AXElement, AXNotification>) {
        guard let observer else { return }
        subscriptions.update(elements, equal: { $0 == $1 }, add: { element, name in
            let result = observer.add(name, to: element)
            return result == .success || result == .notificationAlreadyRegistered || result == .notificationUnsupported
        }, remove: { element, name in
            observer.remove(name, from: element)
        })
    }

    private func publishSnapshot(replacing replacements: [UInt32: UInt32] = [:]) {
        var focused = focusedWindow()
        if change == .activation, let awaited = awaitedActivation {
            awaited.expiry.cancel()
            awaitedActivation = nil
            // The activation tessel requested made another window key: select
            // the requested one again, now that the app is active.
            if focused != awaited.id, presentationLock.withLock({ focusIntent == awaited.intent }),
               let window = elementsByID[awaited.id], (try? canPresent(window, id: awaited.id)) == true,
               (try? check(ax.set(.main, of: window, to: .bool(true)))) != nil,
               (try? check(ax.perform(.raise, on: window))) != nil {
                focused = focusedWindow()
            }
        }
        let frontmost = (try? value(application, .frontmost)?.bool) == true
        if frontmost {
            railActivationCheck?.work.cancel()
            railActivationCheck = nil
        }
        let observations = facts.map { fact in
            var record = fact.record(app: name, bundleId: bundleId, hidden: hidden)
            if record.state == .tiled, constrained.contains(fact.id) {
                record.state = .floats
                record.reason = "cannot fill the screen"
            }
            return WindowObservation(record: record, frame: fact.frame, parent: fact.parent, replaces: replacements[fact.id])
        }
        publish(observations, focused == 0 ? nil : focused, frontmost, change, activationToken)
        change = .snapshot
        activationToken = nil
    }

    private func focusedWindow() -> UInt32 {
        guard let window = try? value(application, .focusedWindow)?.element else { return 0 }
        // Equal AX handles do not inherit each other's messaging timeout.
        ax.setMessagingTimeout(window, seconds: 0.05)
        return ax.windowID(window).value ?? 0
    }

    private func frame(_ window: AXElement) throws -> CGRect {
        let point = try value(window, .position)?.point ?? .zero
        let size = try value(window, .size)?.size ?? .zero
        return CGRect(origin: point, size: size)
    }

    func cancelPresentation(invalidatingFocus: Bool = true) {
        presentationLock.withLock {
            presentation = UUID()
            if invalidatingFocus { focusIntent = UUID() }
        }
    }

    func ownsFocusIntent(_ token: UUID?) -> Bool {
        presentationLock.withLock { token == focusIntent }
    }

    func windowIsGone(id: UInt32, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let intent = presentationLock.withLock { focusIntent }
        queue.async { [self] in
            var gone = false
            if !stopped, let window = elementsByID[id] {
                ax.setMessagingTimeout(window, seconds: 0.05)
                // A timeout leaves liveness unanswered; only the closed-handle
                // error can reject an otherwise healthy external activation.
                gone = ax.copy(.role, of: window).status == .invalidUIElement
            }
            let result = gone
            scheduler.main.async { [self] in
                guard ownsFocusIntent(intent) else { return }
                completion(result)
            }
        }
    }

    func present(id: UInt32, area: CGRect?, focus: Bool, completion: @escaping @MainActor @Sendable () -> Void) {
        let token = presentationLock.withLock { presentation }
        queue.async { [self] in
            // The caller's focus intent lasts only while this write is pending,
            // including when an AX read fails or a newer render cancels it.
            defer { scheduler.main.async { completion() } }
            guard !stopped, presentationLock.withLock({ presentation == token }), let window = elementsByID[id] else { return }
            do {
                guard try canPresent(window, id: id) else { return }
                if let area {
                    let origin = area.origin, size = area.size
                    try check(ax.set(.position, of: window, to: .point(origin)))
                    try check(ax.set(.size, of: window, to: .size(size)))
                    if try checkSize(window, area: area) { constrained.insert(id) } else { constrained.remove(id) }
                    validations[id] = Validation(area: area, token: token, completion: completion)
                    queue.after(milliseconds: 100) { [weak self] in self?.validatePresentation(id: id, token: token) }
                }
                guard presentationLock.withLock({ presentation == token }), try canPresent(window, id: id) else { return }
                if focus {
                    try check(ax.set(.frontmost, of: application, to: .bool(true)))
                    guard presentationLock.withLock({ presentation == token }), isNativeFront(window, id: id) else { return }
                    try check(ax.set(.main, of: window, to: .bool(true)))
                    // AXMain leaves a completed minimize alone; AXRaise restores it.
                    guard presentationLock.withLock({ presentation == token }), try value(window, .minimized)?.bool != true,
                          isNativeFront(window, id: id) else { return }
                    try check(ax.perform(.raise, on: window))
                }
                publishSnapshot()
            } catch { /* Keep the last complete classification when the app is busy. */ }
        }
    }

    func presentRail(id: UInt32, target: CGRect?, position: Bool, resize: Bool, focus: Bool, screenRight: CGFloat,
                     completion: @escaping @MainActor @Sendable (CGRect?) -> Void) {
        let token = presentationLock.withLock { presentation }
        queue.async { [self] in
            presentRail(id:id,target:target,position:position,resize:resize,focus:focus,screenRight:screenRight,token:token,failures:0,completion:completion)
        }
    }

    private func presentRail(id: UInt32, target: CGRect?, position: Bool, resize: Bool, focus: Bool, screenRight: CGFloat, token: UUID,
                             failures: Int, completion: @escaping @MainActor @Sendable (CGRect?) -> Void) {
        var accepted: CGRect?, retrying = false
        defer {
            if !retrying { let result = accepted; scheduler.main.async { completion(result) } }
        }
        guard !stopped, presentationLock.withLock({ presentation == token }), let window = elementsByID[id] else { return }
        do {
            guard try canPresent(window,id:id) else { return }
            if let target {
                // Both orders use one position write. Resize at the old
                // origin when it fits; otherwise establish the new origin.
                var current = facts.first { $0.id == id }?.frame ?? target
                if resize, let point = try value(window, .position)?.point { current.origin = point }
                guard presentationLock.withLock({ presentation == token }) else { return }
                let order = resizeOrder(current: current, target: target, screenRight: screenRight)
                let positionFirst = resize && position && order == true
                if positionFirst { try check(ax.set(.position, of: window, to: .point(target.origin))) }
                // Resizing at the current origin: AX bounds the height by the
                // current top, so a window growing taller rises first, at an x
                // that still fits its width.
                if resize && position && order == false && target.height > current.height && target.minY < current.minY {
                    try check(ax.set(.position, of: window, to: .point(CGPoint(x: current.minX, y: target.minY))))
                }
                guard presentationLock.withLock({ presentation == token }) else { return }
                if resize && order != nil {
                    let size = target.size
                    try check(ax.set(.size, of: window, to: .size(size)))
                    constrained.remove(id)
                    validations[id] = nil
                }
                guard presentationLock.withLock({ presentation == token }) else { return }
                if position && !positionFirst {
                    let origin = target.origin
                    try check(ax.set(.position, of: window, to: .point(origin)))
                }
                accepted = try frame(window)
                if let index = facts.firstIndex(where: { $0.id == id }), let accepted { facts[index].frame = accepted }
            }
            guard presentationLock.withLock({ presentation == token }) else { return }
            if focus {
                guard try canPresent(window,id:id) else { return }
                let active = try value(application, .frontmost)?.bool == true
                try check(ax.set(.frontmost, of: application, to: .bool(true)))
                guard presentationLock.withLock({ presentation == token }), isNativeFront(window,id:id) else { return }
                try check(ax.set(.main, of: window, to: .bool(true)))
                guard presentationLock.withLock({ presentation == token }), try value(window, .minimized)?.bool != true,
                      isNativeFront(window,id:id) else { return }
                try check(ax.perform(.raise, on: window))
                awaitedActivation?.expiry.cancel()
                awaitedActivation = nil
                if !active {
                    let intent = presentationLock.withLock { focusIntent }
                    let expiry = queue.after(milliseconds: 1000) { [weak self] in
                        guard let self, self.awaitedActivation?.intent == intent else { return }
                        self.awaitedActivation = nil
                    }
                    awaitedActivation = (intent, id, expiry)
                }
                // AX accepts an activation request before it necessarily
                // becomes active. Retry once only while it is unconfirmed.
                railActivationCheck?.work.cancel()
                let check = queue.after(milliseconds: 50) { [weak self] in
                    guard let self, self.railActivationCheck?.token == token else { return }
                    self.railActivationCheck = nil
                    guard !self.stopped, self.presentationLock.withLock({ self.presentation == token }),
                          (try? self.canPresent(window,id:id)) == true,
                          (try? self.value(self.application,.frontmost)?.bool) != true else { return }
                    do {
                        try self.check(self.ax.set(.frontmost, of: self.application, to: .bool(true)))
                        guard self.presentationLock.withLock({ self.presentation == token }), self.isNativeFront(window,id:id) else { return }
                        try self.check(self.ax.set(.main, of: window, to: .bool(true)))
                        guard self.presentationLock.withLock({ self.presentation == token }), try self.value(window, .minimized)?.bool != true,
                              self.isNativeFront(window,id:id) else { return }
                        try self.check(self.ax.perform(.raise, on: window))
                        self.publishSnapshot()
                    } catch { /* Another app and newer focus intents remain independent. */ }
                }
                railActivationCheck = (token,check)
            }
            publishSnapshot()
        } catch AXReadError.unresponsive where target != nil && accepted == nil && failures < 4 {
            // A busy or briefly hung app can time out every write of the
            // render that moved it, leaving a stale frame over its
            // neighbors once it answers. Back off like failed reads, while
            // no newer render supersedes this one; a hung app then costs nothing.
            retrying = true
            queue.after(milliseconds: 50 << (failures+1)) { [weak self] in
                self?.presentRail(id:id,target:target,position:position,resize:resize,focus:focus,screenRight:screenRight,token:token,
                                  failures:failures+1,completion:completion)
            }
        } catch { /* Another app's queue and the CLI remain independent. */ }
    }

    /// A right-clipped window cannot accept its width at either origin. Keep
    /// its current size until it is shown far enough inside the screen again.
    private func resizeOrder(current: CGRect, target: CGRect, screenRight: CGFloat) -> Bool? {
        let fitsCurrent = current.minX + target.width <= screenRight && current.minX + target.width >= 1
        let fitsTarget = target.maxX <= screenRight && target.maxX >= 1
        if fitsCurrent { return fitsTarget && target.height > current.height && target.minY < current.minY }
        if fitsTarget { return true }
        return nil
    }

    /// Shutdown is synchronous so a terminating process cannot abandon its
    /// partial windows. Only caller-owned IDs are eligible; no size is written.
    func returnInside(ids: Set<UInt32>, area: CGRect) {
        queue.sync {
            for id in ids.sorted() {
                guard let window = elementsByID[id], (try? canPresent(window,id:id)) == true,
                      let frame = try? frame(window) else { continue }
                let point = CGPoint(x:max(area.minX,min(frame.minX,area.maxX-frame.width)),
                                    y:max(area.minY,min(frame.minY,area.maxY-frame.height)))
                _ = ax.set(.position, of: window, to: .point(point))
            }
        }
    }

    private func checkSize(_ window: AXElement, area: CGRect) throws -> Bool {
        let accepted = try frame(window)
        guard accepted.width > 0, accepted.height > 0 else { throw AXReadError.unresponsive }
        let cannotFill = abs(accepted.width - area.width) > 2 || abs(accepted.height - area.height) > 2
        if cannotFill {
            let center = CGPoint(x: area.midX - accepted.width / 2, y: area.midY - accepted.height / 2)
            try check(ax.set(.position, of: window, to: .point(center)))
        }
        return cannotFill
    }

    private func validatePresentation(id: UInt32, token: UUID? = nil) {
        guard let pending = validations[id], token == nil || token == pending.token else { return }
        validations[id] = nil
        guard presentationLock.withLock({ presentation == pending.token }), let window = elementsByID[id],
              (try? canPresent(window, id: id)) == true,
              let cannotFill = try? checkSize(window, area: pending.area) else { return }
        if cannotFill { constrained.insert(id) } else { constrained.remove(id) }
        publishSnapshot()
        scheduler.main.async { pending.completion() }
    }

    /// Native hide, minimize, and fullscreen can begin between a snapshot and a
    /// queued write. Never let an old presentation undo the user's operation.
    private func canPresent(_ window: AXElement, id: UInt32) throws -> Bool {
        guard !hidden, try value(application, .hidden)?.bool != true,
              try value(window, .minimized)?.bool != true,
              try value(window, .fullscreen)?.bool != true else { return false }
        return isNativeFront(window, id: id)
    }

    /// Selecting another native tab moves the group's bar to that window.
    /// Raising or making the former front main would select it again over the
    /// user's choice. Focus writes repeat this check: each can take long enough
    /// on a busy system for the user to select another tab in between.
    /// Windows without a native tab bar need no AX read.
    private func isNativeFront(_ window: AXElement, id: UInt32) -> Bool {
        let groups = facts.first(where: { $0.id == id })?.nativeTabGroups ?? []
        // Its bar can leave the former root before the successor is published.
        // The retained group still identifies the real selected native window.
        for bar in groups.isEmpty ? (nativeBars[id] ?? []) : groups {
            ax.setMessagingTimeout(bar, seconds: 0.05)
            if let front = try? value(bar, .window)?.element,
               front != window { return false }
        }
        return true
    }

    private func value(_ element: AXElement, _ attribute: AXAttribute) throws -> AXValue? {
        let result = ax.copy(attribute, of: element)
        try check(result.status)
        return result.value
    }

    private func check(_ error: AXStatus) throws {
        if error == .cannotComplete || error == .apiDisabled { throw AXReadError.unresponsive }
        if error == .invalidUIElement { throw AXReadError.gone }
    }
}

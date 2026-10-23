import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

struct WindowObservation: Sendable {
    var record: WindowRecord
    let frame: CGRect
    let parent: UInt32?
    var resizable = true
    var replaces: UInt32? = nil
}

enum CatalogChange: Sendable, Equatable { case snapshot, activation, focus, restored }

struct WindowFocusObservation: Sendable {
    let window: UInt32?
    let frontmost: Bool
}

enum BackgroundRaise: Sendable, Equatable {
    case finished
    /// The app may still hold an activation tessel requested; raising it now
    /// could complete that activation (deferred-ax-activation).
    case awaitingActivation
}

struct RailPresentationResult: Sendable {
    /// How a request ended. Only a presented placement says where its window
    /// is. A withdrawn window was read as minimized, hidden, fullscreen, behind
    /// another native tab or gone, and its own event's snapshot says so to
    /// Policy. An unanswered app timed out through every retry. A superseded
    /// request was cancelled by a newer render, its app's hide or quit.
    enum Outcome: Sendable { case presented, withdrawn, unanswered, superseded }
    var outcome: Outcome
    var frame: CGRect?
    /// Nil when presentation stopped before publishing a fresh native read.
    var focus: WindowFocusObservation?
}

@MainActor
final class WindowCatalog {
    private let workspaces: Workspaces
    private let fixtureBundleID: String?
    private let applications: any ApplicationPort
    private let ax: any AccessibilityPort
    private let windowOrder: any WindowOrderPort
    private let scheduler: any SchedulingPort
    private var lifecycle: (any ApplicationObservation)?
    private var apps: [Int32: AppWindows] = [:]

    init(workspaces: Workspaces, applications: any ApplicationPort, ax: any AccessibilityPort, windowOrder: any WindowOrderPort,
         scheduler: any SchedulingPort, fixtureBundleID: String? = nil) {
        self.workspaces = workspaces
        self.applications = applications
        self.ax = ax
        self.windowOrder = windowOrder
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
                                hidden: app.hidden, generation: generation, ax: ax, windowOrder: windowOrder, scheduler: scheduler) { [weak self, scheduler] rows, focused, frontmost, activationPending, change, activation in
            scheduler.main.async {
                guard let self, let worker = self.apps[pid], worker.generation == generation else { return }
                // An activation can wait behind a newer keyboard selection in
                // either queue. Its facts remain valid; its old intent does not.
                let received: CatalogChange = change == .activation && !worker.ownsFocusIntent(activation) ? .snapshot : change
                self.workspaces.update(pid: pid, observations: rows, focused: focused, frontmost: frontmost,
                                       activationPending: activationPending, change: received)
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

    func presentRail(pid: Int32, id: UInt32, frame: CGRect?, position: Bool, resize: Bool, focus: Bool, screenRight: CGFloat,
                     completion: @escaping @MainActor @Sendable (RailPresentationResult) -> Void) {
        guard let app = apps[pid] else { completion(RailPresentationResult(outcome: .withdrawn)); return }
        app.presentRail(id:id,target:frame,position:position,resize:resize,focus:focus,screenRight:screenRight,completion:completion)
    }

    func windowIsGone(pid: Int32, id: UInt32, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let app = apps[pid] else { completion(false); return }
        app.windowIsGone(id: id, completion: completion)
    }

    func refreshFrame(pid: Int32, id: UInt32, completion: @escaping @MainActor @Sendable (CGRect?) -> Void) {
        guard let app = apps[pid] else { completion(nil); return }
        app.refreshFrame(id: id, completion: completion)
    }

    func raiseBackground(pid: Int32, id: UInt32, completion: @escaping @MainActor @Sendable (BackgroundRaise) -> Void) {
        guard let app = apps[pid] else { completion(.finished); return }
        app.raiseBackground(id: id, completion: completion)
    }

    func returnInside(ids: Set<UInt32>, area: CGRect) { apps.keys.sorted().compactMap { apps[$0] }.forEach { $0.returnInside(ids:ids,area:area) } }

    func refreshFrames(reconciled: @escaping @MainActor @Sendable (Int32) -> Void,
                       completion: @escaping @MainActor @Sendable () -> Void) {
        var remaining = apps.count
        guard remaining > 0 else { completion(); return }
        for pid in apps.keys.sorted() {
            apps[pid]?.refreshForPointerRelease(reconciled: { reconciled(pid) }) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    func cancelPresentations(invalidatingFocus: Bool = true) {
        apps.keys.sorted().compactMap { apps[$0] }.forEach { $0.cancelPresentation(invalidatingFocus: invalidatingFocus) }
    }
}

private enum AXReadError: Error { case unresponsive, gone, changed }

private struct WindowFacts {
    // Layer 3 holds apps' own floating utility panels, inspectors and palettes.
    private static let managedWindowLevels: Set<Int> = [0, 3]

    let id: UInt32
    let minimized: Bool
    var fullscreen: Bool
    let subrole: String
    let level: Int
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
        if !Self.managedWindowLevels.contains(level) { state = .ignored; reason = "window level \(level)" }
        // AXFullScreen remains authoritative while a native transition exposes
        // a temporary root with an unknown subrole.
        else if fullscreen { state = .fullscreen; reason = "native fullscreen" }
        else if !["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(subrole) {
            state = .ignored; reason = subrole
        }
        else if minimized { state = .minimized; reason = "minimized" }
        else if hidden { state = .hidden; reason = "application hidden" }
        else if subrole != "AXStandardWindow" { state = .floats; reason = subrole }
        else if !resizable { state = .floats; reason = "fixed size" }
        else { state = .tiled; reason = "standard window" }
        if tabs > 1 && state != .ignored { reason += "; \(tabs) native tabs" }
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
    private let windowOrder: any WindowOrderPort
    private let scheduler: any SchedulingPort
    private let publish: @Sendable ([WindowObservation], UInt32?, Bool, Bool, CatalogChange, UUID?) -> Void
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
    private var pointerReleaseCompletion: (@MainActor @Sendable () -> Void)?
    private var enhancedUIRestorePending = false
    private var enhancedUIRestoreRetry: (any ScheduledWork)?
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
    // AX can accept AXFrontmost and leave the activation pending until a main
    // or raise write, an asynchronous completion, or another activation request
    // (deferred-ax-activation). A newer selection cancels the writes that
    // follow a request, not the request, and nothing reports one abandoned;
    // the app becoming active by other means is not known to consume it.
    // A background raise could then complete it over the user's selection.
    // It is resolved once tessel's own focus writes have followed its latest
    // request and the app has been read frontmost, or when the read that
    // follows an unfollowed request, in the sequence that issued it, already
    // finds the app frontmost (`requestActivation`).
    private enum ActivationRequest { case resolved, unfollowed, followed }
    private var activationRequest = ActivationRequest.resolved

    init(pid: Int32, name: String, bundleId: String, hidden: Bool, generation: UUID,
         ax: any AccessibilityPort, windowOrder: any WindowOrderPort, scheduler: any SchedulingPort,
         publish: @escaping @Sendable ([WindowObservation], UInt32?, Bool, Bool, CatalogChange, UUID?) -> Void) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
        self.hidden = hidden
        self.hiddenHint = hidden
        self.generation = generation
        self.publish = publish
        self.ax = ax
        self.windowOrder = windowOrder
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
            restoreEnhancedUI()
            enhancedUIRestoreRetry?.cancel()
            stopped = true
            railActivationCheck?.work.cancel()
            railActivationCheck = nil
            pending?.cancel()
            finishPointerRelease()
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
        if enhancedUIRestorePending, enhancedUIRestoreRetry == nil { restoreEnhancedUI() }
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
            failedReads = 0
            publishSnapshot(replacing: replacements)
            finishPointerRelease()
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
        // Reinspection owns this native fact, rather than layout reconciliation.
        // A missing CG description is an incomplete read, never layer zero.
        guard let level = windowOrder.windowLevels([id])[id] else { throw AXReadError.changed }
        handles[id] = window
        result.append(WindowFacts(id: id, minimized: minimized, fullscreen: fullscreen, subrole: subrole, level: level,
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

    @discardableResult
    private func publishSnapshot(replacing replacements: [UInt32: UInt32] = [:]) -> WindowFocusObservation {
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
            if activationRequest == .followed { activationRequest = .resolved }
            railActivationCheck?.work.cancel()
            railActivationCheck = nil
        }
        let observations = facts.map { fact in
            let record = fact.record(app: name, bundleId: bundleId, hidden: hidden)
            return WindowObservation(record: record, frame: fact.frame, parent: fact.parent, resizable: fact.resizable, replaces: replacements[fact.id])
        }
        publish(observations, focused == 0 ? nil : focused, frontmost, activationRequest != .resolved, change, activationToken)
        change = .snapshot
        activationToken = nil
        return WindowFocusObservation(window: focused == 0 ? nil : focused, frontmost: frontmost)
    }

    /// Request activation, then `follow` it with tessel's own focus writes,
    /// returning whether they all ran. When they stop early, the frontmost read
    /// that follows this request tells whether it is pending. A presentation
    /// that issued no request learns nothing about an older one from that read.
    private func requestActivation(followedBy follow: () throws -> Bool) throws -> Bool {
        activationRequest = .unfollowed
        defer {
            if activationRequest == .unfollowed, (try? value(application, .frontmost)?.bool) == true { activationRequest = .resolved }
        }
        try check(ax.set(.frontmost, of: application, to: .bool(true)))
        guard try follow() else { return false }
        activationRequest = .followed
        return true
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

    func refreshForPointerRelease(reconciled: @escaping @MainActor @Sendable () -> Void,
                                  completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            guard !stopped else { scheduler.main.async { completion() }; return }
            // A later gesture supersedes the earlier callback, but keeps the
            // unresolved baseline. Repeated clicks cannot grow a hung app's queue.
            pointerReleaseCompletion = reconciled
            readSnapshot()
            // Only this first attempt gates the shared layout and queued keys.
            // A failed app keeps its own baseline until a later successful read.
            scheduler.main.async { completion() }
        }
    }

    private func finishPointerRelease() {
        // Publication is queued first, so release reconciliation sees the fresh
        // geometry. Failed reads retain the baseline until retry or notification.
        guard let completion = pointerReleaseCompletion else { return }
        pointerReleaseCompletion = nil
        scheduler.main.async { completion() }
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

    /// Publish fresh geometry before the caller changes membership. Earlier
    /// snapshots on this lane reach main first, while the window still floats.
    func refreshFrame(id: UInt32, completion: @escaping @MainActor @Sendable (CGRect?) -> Void) {
        queue.async { [self] in
            var observed: CGRect?
            defer {
                let result = observed
                scheduler.main.async { completion(result) }
            }
            guard !stopped, let window = elementsByID[id] else { return }
            do {
                guard try canPresent(window, id: id) else { return }
                let current = try frame(window)
                guard current.width > 0, current.height > 0, try canPresent(window, id: id),
                      let index = facts.firstIndex(where: { $0.id == id }) else { return }
                facts[index].frame = current
                publishSnapshot()
                observed = current
            } catch { /* An unanswered read cannot choose a preset from stale geometry. */ }
        }
    }

    /// AXRaise on a frontmost app's root may select it (ax-focus). A background
    /// raise only reorders below the active window (ax-raise-across-applications),
    /// unless it completes an activation still pending in that app.
    func raiseBackground(id: UInt32, completion: @escaping @MainActor @Sendable (BackgroundRaise) -> Void) {
        let token = presentationLock.withLock { presentation }
        queue.async { [self] in
            var result = BackgroundRaise.finished
            defer {
                let outcome = result
                scheduler.main.async { completion(outcome) }
            }
            guard !stopped, presentationLock.withLock({ presentation == token }), let window = elementsByID[id] else { return }
            guard activationRequest == .resolved else { result = .awaitingActivation; return }
            do {
                guard try canPresent(window, id: id), try value(application, .frontmost)?.bool == false,
                      presentationLock.withLock({ presentation == token }) else { return }
                try check(ax.perform(.raise, on: window))
            } catch { /* A busy or newly frontmost app keeps its native order. */ }
        }
    }

    func presentRail(id: UInt32, target: CGRect?, position: Bool, resize: Bool, focus: Bool, screenRight: CGFloat,
                     completion: @escaping @MainActor @Sendable (RailPresentationResult) -> Void) {
        let token = presentationLock.withLock { presentation }
        queue.async { [self] in
            presentRail(id:id,target:target,position:position,resize:resize,focus:focus,screenRight:screenRight,token:token,failures:0,completion:completion)
        }
    }

    private func presentRail(id: UInt32, target: CGRect?, position: Bool, resize: Bool, focus: Bool, screenRight: CGFloat, token: UUID,
                             failures: Int, completion: @escaping @MainActor @Sendable (RailPresentationResult) -> Void) {
        var accepted: CGRect?, retrying = false
        var observedFocus: WindowFocusObservation?
        var outcome = RailPresentationResult.Outcome.superseded
        defer {
            if !retrying {
                let result = RailPresentationResult(outcome: accepted == nil ? outcome : .presented, frame: accepted, focus: observedFocus)
                scheduler.main.async { completion(result) }
            }
        }
        guard !stopped, presentationLock.withLock({ presentation == token }) else { return }
        guard let window = elementsByID[id] else { outcome = .withdrawn; return }
        do {
            guard try canPresent(window,id:id) else { outcome = .withdrawn; return }
            if let target {
                let enhanced = try enhancedUIRestorePending || value(application, .enhancedUserInterface)?.bool == true
                if enhanced { enhancedUIRestorePending = true }
                defer { if enhanced { restoreEnhancedUI() } }
                if enhanced { try check(ax.set(.enhancedUserInterface, of: application, to: .bool(false))) }
                var current = facts.first { $0.id == id }?.frame ?? target
                if resize { current = try frame(window) }
                guard presentationLock.withLock({ presentation == token }) else { return }
                let order = resizeOrder(current: current, target: target, screenRight: screenRight)
                let positionFirst = resize && position && order == true
                if positionFirst { try check(ax.set(.position, of: window, to: .point(target.origin))) }
                // Initial discovery can find a short, low window whose final
                // x is clipped. Rise at its fitting origin before growing.
                if resize && position && order == false && target.height > current.height && target.minY < current.minY {
                    try check(ax.set(.position, of: window, to: .point(CGPoint(x: current.minX, y: target.minY))))
                }
                guard presentationLock.withLock({ presentation == token }) else { return }
                if resize, order != nil {
                    try check(ax.set(.size, of: window, to: .size(target.size)))
                }
                guard presentationLock.withLock({ presentation == token }) else { return }
                if position && !positionFirst { try check(ax.set(.position, of: window, to: .point(target.origin))) }
                accepted = try frame(window)
                if let index = facts.firstIndex(where: { $0.id == id }), let accepted { facts[index].frame = accepted }
            }
            guard presentationLock.withLock({ presentation == token }) else { return }
            if focus {
                guard try canPresent(window,id:id) else { return }
                let active = try value(application, .frontmost)?.bool == true
                guard presentationLock.withLock({ presentation == token }) else { return }
                let followed = try requestActivation {
                    guard presentationLock.withLock({ presentation == token }), isNativeFront(window,id:id) else { return false }
                    try check(ax.set(.main, of: window, to: .bool(true)))
                    guard presentationLock.withLock({ presentation == token }), try value(window, .minimized)?.bool != true,
                          isNativeFront(window,id:id) else { return false }
                    try check(ax.perform(.raise, on: window))
                    return true
                }
                guard followed else { return }
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
                        let followed = try self.requestActivation {
                            guard self.presentationLock.withLock({ self.presentation == token }), self.isNativeFront(window,id:id) else { return false }
                            try self.check(self.ax.set(.main, of: window, to: .bool(true)))
                            guard self.presentationLock.withLock({ self.presentation == token }), try self.value(window, .minimized)?.bool != true,
                                  self.isNativeFront(window,id:id) else { return false }
                            try self.check(self.ax.perform(.raise, on: window))
                            return true
                        }
                        if followed { self.publishSnapshot() }
                    } catch { /* Another app and newer focus intents remain independent. */ }
                }
                railActivationCheck = (token,check)
            }
            observedFocus = publishSnapshot()
            outcome = .presented
        } catch AXReadError.unresponsive where (target != nil || focus) && accepted == nil && failures < 4 {
            // A busy or briefly hung app can time out every write of the
            // render that moved it, or the separate focus request that
            // releases its visibility handoff. Back off like failed reads, while
            // no newer render supersedes this one; a hung app then costs nothing.
            retrying = true
            queue.after(milliseconds: 50 << (failures+1)) { [weak self] in
                self?.presentRail(id:id,target:target,position:position,resize:resize,focus:focus,screenRight:screenRight,token:token,
                                  failures:failures+1,completion:completion)
            }
        } catch AXReadError.gone {
            outcome = .withdrawn
        } catch {
            // The app timed out through every retry. Another app's queue and
            // the CLI remain independent.
            outcome = .unanswered
        }
    }

    private func restoreEnhancedUI(failures: Int = 0) {
        guard enhancedUIRestorePending, !stopped else { return }
        enhancedUIRestoreRetry?.cancel()
        enhancedUIRestoreRetry = nil
        let result = ax.set(.enhancedUserInterface, of: application, to: .bool(true))
        // AppKit can apply this flag while returning notImplemented. Readback
        // also distinguishes that reply from a restore that never happened.
        if result == .success || (try? value(application, .enhancedUserInterface)?.bool) == true {
            enhancedUIRestorePending = false
        } else if failures < 4 {
            enhancedUIRestoreRetry = queue.after(milliseconds: 100 << failures) { [weak self] in
                self?.restoreEnhancedUI(failures: failures + 1)
            }
        }
        // Exhaustion leaves the obligation intact. The next native snapshot
        // or placement retries it without keeping a hung app on a timer.
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

    /// Native hide, minimize, and fullscreen can begin between a snapshot and a
    /// queued write. Never let an old presentation undo the user's operation.
    private func canPresent(_ window: AXElement, id: UInt32) throws -> Bool {
        guard facts.first(where: { $0.id == id })?.record(app: name, bundleId: bundleId, hidden: hidden).state != .ignored,
              !hidden, try value(application, .hidden)?.bool != true,
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

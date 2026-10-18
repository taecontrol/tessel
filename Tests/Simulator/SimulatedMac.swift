import Foundation
import CoreGraphics
import Ports
import Assumptions

package enum PositionAcceptance: String, CaseIterable, Sendable { case requested, rightEdgeStrip }
package enum OffDisplayMembership: String, CaseIterable, Sendable { case included, omitted }

package struct WindowSpec: Sendable {
    package var frame: CGRect
    package var subrole: String
    package var resizable: Bool
    package var minimumSize: CGSize
    package var maximumSize: CGSize
    package var parent: UInt32?
    package var positionAcceptance: PositionAcceptance
    package var offDisplayMembership: OffDisplayMembership
    package init(frame: CGRect = CGRect(x: 40, y: 60, width: 451, height: 400), subrole: String = "AXStandardWindow",
                 resizable: Bool = true, minimumSize: CGSize = CGSize(width: 1, height: 1),
                 maximumSize: CGSize = CGSize(width: 100_000, height: 100_000), parent: UInt32? = nil,
                 positionAcceptance: PositionAcceptance = .rightEdgeStrip, offDisplayMembership: OffDisplayMembership = .included) {
        self.frame = frame; self.subrole = subrole; self.resizable = resizable
        self.minimumSize = minimumSize; self.maximumSize = maximumSize; self.parent = parent
        self.positionAcceptance = positionAcceptance
        self.offDisplayMembership = offDisplayMembership
    }
}

package enum WindowListReply: Sendable {
    case complete, omitting([UInt32]), zeroIDs([UInt32]), failure(AXStatus), nonArray, includingClosed([UInt32])
}
package enum NotificationOrder: Sendable { case focusThenMain, mainThenFocus }
package enum ProhibitedNotifications: String, CaseIterable, Sendable {
    case delivered, launchOnly, terminationOnly, omitted
}

package struct SimulatedApp: Sendable {
    package let pid: Int32
    package let alias: String
    let mac: SimulatedMac
    @MainActor package var windows: [UInt32] { mac.appWindows(pid) }
    @MainActor package func select(_ window: UInt32, notifications: NotificationOrder = .focusThenMain) {
        mac.select(window, notifications: notifications)
    }
    @MainActor @discardableResult package func open(_ spec: WindowSpec = WindowSpec(), background: Bool = false) -> UInt32 {
        mac.open(pid, spec: spec, background: background)
    }
    @MainActor package func close(_ window: UInt32, selecting successor: UInt32? = nil) { mac.close(window, successor: successor) }
    @MainActor package func minimize(_ window: UInt32, selecting successor: UInt32? = nil) { mac.minimize(window, successor: successor) }
    @MainActor package func restore(_ window: UInt32) { mac.restore(window) }
    @MainActor package func hide(omitWindows: Bool = false) { mac.visibility(pid, hidden: true, omitWindows: omitWindows) }
    @MainActor package func unhide() { mac.visibility(pid, hidden: false, omitWindows: false) }
    @MainActor package func hang() { mac.setHung(pid, true) }
    @MainActor package func busy(forMilliseconds duration: Int) { mac.setBusy(pid, duration: duration) }
    @MainActor package func resume() { mac.setHung(pid, false) }
    @MainActor package func quit() { mac.terminate(pid, crash: false) }
    @MainActor package func crash() { mac.terminate(pid, crash: true) }
    @MainActor package func publishNextWindowLists(_ replies: [WindowListReply]) { mac.publishWindowLists(pid, replies) }
    @MainActor package func enterFullscreen(_ window: UInt32) { mac.fullscreen(window, enabled: true) }
    @MainActor package func leaveFullscreen(_ window: UInt32) { mac.fullscreen(window, enabled: false) }
    @MainActor package func drag(_ window: UInt32, to point: CGPoint) { mac.drag(window, point: point) }
    @MainActor package func resize(_ window: UInt32, to size: CGSize) { mac.resize(window, size: size) }
    @MainActor package func groupTabs(_ windows: [UInt32], selected: UInt32) { mac.groupTabs(windows, selected: selected) }
    @MainActor package func selectTab(_ window: UInt32) { mac.selectTab(window) }
    @MainActor package func detachTab(_ window: UInt32) { mac.detachTab(window) }
}

extension PausePoint {
    package static func read(_ app: SimulatedApp) -> Self { .read(app.pid) }
    package static func delivery(_ app: SimulatedApp) -> Self { .delivery(app.pid) }
}

/// This object owns OS facts only. The production catalog interprets every AX
/// result; the simulator never classifies a window or chooses a workspace.
package final class SimulatedMac: @unchecked Sendable {
    package let scheduler: BatonScheduler
    var apps: [Int32: AppState] = [:]
    var windows: [UInt32: Window] = [:]
    var groups: [Int: TabGroup] = [:]
    var fullscreenRoots: [UInt32: UInt32] = [:]
    var front: Int32?
    var zOrder: [UInt32] = []
    var active: UInt64 = 1
    var closet: UInt64 = 2
    var closetStarted = false
    var nextPID: Int32 = 100
    var nextWindow: UInt32 = 0
    var nextGroup = 0
    var lifecycle: [WeakLifecycle] = []
    var observers: [WeakObservation] = []
    var geometry = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 737))
    var usedAssumptions: Set<Assumption> = []
    var foundation = FoundationState()

    struct AppState {
        let pid: Int32, alias: String, bundleID: String
        var hidden = false, terminated = false, prohibited = false, hung = false
        var prohibitedNotifications = ProhibitedNotifications.omitted
        var busyUntil = 0
        var omitHiddenWindows = false
        var key: UInt32?, main: UInt32?
        var windowLists: [WindowListReply] = []
        var zeroIDs: Set<UInt32> = []
        var publishedWindows: [UInt32]?
        var publishesFocus = true
        var deferredActivations = 0
        var activationPending = false
        var activationCompletion = DeferredActivationCompletion.focusWrite
    }
    struct Window {
        let id: UInt32, pid: Int32
        var spec: WindowSpec
        var minimized = false, fullscreen = false, closed = false
        var minimizing = false
        var spaces: Set<UInt64> = [1]
        var group: Int?
    }
    struct TabGroup { var windows: [UInt32]; var selected: UInt32 }
    struct WeakLifecycle { weak var value: Lifecycle? }
    struct WeakObservation { weak var value: Observation? }

    @MainActor package init(scheduler: BatonScheduler = BatonScheduler()) {
        self.scheduler = scheduler
        apps[10] = AppState(pid: 10, alias: "app-desktop", bundleID: "com.apple.finder")
    }

    func assume(_ assumption: Assumption) { usedAssumptions.insert(assumption) }
    package var ax: any AccessibilityPort { Accessibility(mac: self) }
    @MainActor package var applications: any ApplicationPort { Applications(mac: self) }
    @MainActor package var screens: any ScreenPort { Applications(mac: self) }
    @MainActor package var windowOrder: any WindowOrderPort { Applications(mac: self) }
    @MainActor package var closetPort: any ClosetPort {
        closetPort(retainingShownMembership: true)
    }
    @MainActor package func closetPort(retainingShownMembership: Bool) -> any ClosetPort {
        let space = closet
        closet += 1
        return Closet(mac: self, space: space, retainingShownMembership: retainingShownMembership)
    }
    @MainActor package var focusedWindow: UInt32? { front.flatMap { apps[$0]?.key } }
    @MainActor package var frontmostApp: Int32? { front }
    @MainActor package var finder: SimulatedApp { app(10) }
    @MainActor package func frame(_ id: UInt32) -> CGRect? { windows[id]?.spec.frame }
    @MainActor package func isVisible(_ id: UInt32) -> Bool { visibleIDs().contains(id) }
    @MainActor package func isFullyOnScreen(_ id: UInt32) -> Bool {
        guard isVisible(id), let frame = frame(id) else { return false }
        return CGRect(x: geometry.frame.minX, y: 0, width: geometry.frame.width, height: geometry.frame.height).contains(frame)
    }
    @MainActor package func action(_ label: String) { scheduler.note("user \(label)") }
    @MainActor @discardableResult package func settle() -> RunOutcome { scheduler.resume(); return scheduler.run() }
    @MainActor @discardableResult package func pause(after point: PausePoint) -> RunOutcome {
        scheduler.run(until: point)
    }
    @MainActor @discardableResult package func deliver(_ app: SimulatedApp) -> RunOutcome {
        scheduler.resume(); return scheduler.run(until: .delivery(app.pid))
    }
    @MainActor package func shutdown() { scheduler.shutdown() }

    @MainActor @discardableResult package func launch(windows count: Int = 0, prohibited: Bool = false,
                                                     prohibitedNotifications: ProhibitedNotifications = .omitted) -> SimulatedApp {
        assume(.applicationLifecycle)
        let pid = nextPID; nextPID += 1
        let alias = "app-" + String(UnicodeScalar(65 + Int(pid - 100))!)
        var state = AppState(pid: pid, alias: alias, bundleID: "org.example.\(alias.lowercased())")
        state.prohibited = prohibited
        state.prohibitedNotifications = prohibitedNotifications
        apps[pid] = state
        action("launch \(alias) pid=\(pid)")
        for _ in 0..<count { _ = open(pid, spec: WindowSpec()) }
        if !prohibited || [.delivered, .launchOnly].contains(prohibitedNotifications) { post(.launched, pid: pid) }
        return app(pid)
    }
    @MainActor func app(_ pid: Int32) -> SimulatedApp { SimulatedApp(pid: pid, alias: apps[pid]!.alias, mac: self) }
    @MainActor func appWindows(_ pid: Int32) -> [UInt32] { windows.values.filter { $0.pid == pid && !$0.closed }.map(\.id).sorted() }

    @MainActor @discardableResult func open(_ pid: Int32, spec: WindowSpec, background: Bool = false) -> UInt32 {
        assume(.axApplicationWindows)
        nextWindow += 1
        let id = nextWindow
        windows[id] = Window(id: id, pid: pid, spec: spec, spaces: [active])
        action("\(apps[pid]!.alias) open window \(id)")
        if background { assume(.backgroundWindowCreation); zOrder.append(id) }
        else { focus(id) }
        notify(spec.parent == nil ? .windowCreated : .sheetCreated, node: .application(pid))
        return id
    }
    @MainActor func select(_ id: UInt32, notifications: NotificationOrder) {
        assume(.axFocus)
        guard let window = windows[id], !window.closed else { scheduler.failUnmodeled("user.select missing window \(id)"); return }
        action("select window \(id) \(apps[window.pid]!.alias)")
        focus(id, notifications: notifications)
    }
    func focus(_ id: UInt32, notifications: NotificationOrder = .focusThenMain, activating: Bool = true) {
        guard let window = windows[id], !window.closed else { return }
        if let sheet = windows.keys.sorted().first(where: { windows[$0]?.spec.parent == id && windows[$0]?.closed == false }) {
            assume(.sheetFocusOwnership)
            focus(sheet, notifications: notifications)
            return
        }
        if let group = window.group { groups[group]?.selected = id }
        let activated = activating && front != window.pid
        if activating { front = window.pid }
        apps[window.pid]?.key = id
        apps[window.pid]?.main = window.spec.parent ?? id
        zOrder.removeAll { $0 == id }; zOrder.insert(id, at: 0)
        if activated { post(.activated, pid: window.pid) }
        let events: [AXNotification] = notifications == .focusThenMain ? [.focusedWindowChanged, .mainWindowChanged] : [.mainWindowChanged, .focusedWindowChanged]
        for event in events { notify(event, node: .application(window.pid)) }
    }
    @MainActor func close(_ id: UInt32, successor: UInt32?) {
        assume(.closedWindowHandles)
        guard let window = windows[id] else { return }
        action("close window \(id) \(apps[window.pid]!.alias)")
        windows[id]?.closed = true
        if let group = window.group {
            groups[group]?.windows.removeAll { $0 == id }
            if groups[group]?.selected == id, let next = groups[group]?.windows.first { groups[group]?.selected = next }
        }
        if apps[window.pid]?.key == id {
            apps[window.pid]?.key = nil; apps[window.pid]?.main = nil
            if let successor { assume(.closeFocusPromotion); focus(successor) }
        }
        notify(.destroyed, node: .window(id))
    }
    @MainActor func minimize(_ id: UInt32, successor: UInt32?) {
        assume(.minimizeRestore)
        guard let window = windows[id] else { return }
        action("minimize window \(id)")
        for member in groupMembers(id) { windows[member]?.minimized = true }
        if apps[window.pid]?.key == id {
            apps[window.pid]?.key = nil; apps[window.pid]?.main = nil
            if let successor { focus(successor) }
        }
        notify(.minimized, node: .window(id))
    }
    @MainActor func restore(_ id: UInt32) {
        assume(.minimizeRestore)
        action("restore window \(id)")
        for member in groupMembers(id) { windows[member]?.minimized = false }
        focus(id)
        notify(.restored, node: .window(id))
    }
    @MainActor func visibility(_ pid: Int32, hidden: Bool, omitWindows: Bool) {
        assume(.applicationVisibility)
        action("\(hidden ? "hide" : "unhide") \(apps[pid]!.alias)")
        apps[pid]?.hidden = hidden; apps[pid]?.omitHiddenWindows = omitWindows
        post(hidden ? .hidden : .unhidden, pid: pid)
    }
    @MainActor func setHung(_ pid: Int32, _ hung: Bool) {
        assume(.axMessagingTimeout)
        action("\(apps[pid]!.alias) \(hung ? "hang" : "resume")")
        apps[pid]?.hung = hung
        if !hung { apps[pid]?.busyUntil = 0 }
    }
    @MainActor func setBusy(_ pid: Int32, duration: Int) {
        assume(.axMessagingTimeout)
        action("\(apps[pid]!.alias) busy for \(duration)ms")
        apps[pid]?.busyUntil = scheduler.now + max(0, duration)
    }
    @MainActor func terminate(_ pid: Int32, crash: Bool) {
        assume(.applicationLifecycle)
        action("\(crash ? "crash" : "quit") \(apps[pid]!.alias)")
        apps[pid]?.terminated = true
        for id in windows.keys.sorted() where windows[id]?.pid == pid { windows[id]?.closed = true }
        if front == pid { front = nil }
        if apps[pid]?.prohibited == false || [.delivered, .terminationOnly].contains(apps[pid]!.prohibitedNotifications) {
            post(.terminated, pid: pid)
        }
    }
    @MainActor func fullscreen(_ id: UInt32, enabled: Bool) {
        assume(.nativeFullscreen)
        action("window \(id) fullscreen=\(enabled)")
        windows[id]?.fullscreen = enabled
        windows[id]?.spaces = [enabled ? 10_000 + UInt64(id) : 1]
        active = enabled ? 10_000 + UInt64(id) : 1
        notify(.layoutChanged, node: .window(id))
    }
    @MainActor func drag(_ id: UInt32, point: CGPoint) {
        assume(.windowGeometryWrites)
        action("drag window \(id) to \(point.x),\(point.y)")
        applyPosition(id, point)
    }
    @MainActor func resize(_ id: UInt32, size: CGSize) {
        assume(.axSizeConstraints)
        action("resize window \(id) to \(size.width),\(size.height)")
        applySize(id, size)
    }
    @MainActor func publishWindowLists(_ pid: Int32, _ replies: [WindowListReply]) {
        assume(.transientWindowLists)
        action("\(apps[pid]!.alias) publish AXWindows choices count=\(replies.count)")
        apps[pid]?.windowLists = replies
        notify(.layoutChanged, node: .application(pid))
    }
    @MainActor func groupTabs(_ ids: [UInt32], selected: UInt32) {
        assume(.nativeTabIdentity)
        guard !ids.isEmpty, ids.contains(selected), Set(ids.compactMap { windows[$0]?.pid }).count == 1 else {
            scheduler.failUnmodeled("app.groupTabs invalid window group"); return
        }
        nextGroup += 1
        groups[nextGroup] = TabGroup(windows: ids, selected: selected)
        let frame = windows[selected]!.spec.frame
        for id in ids { windows[id]?.group = nextGroup; windows[id]?.spec.frame = frame }
        action("group native tabs \(ids) selected=\(selected)")
        focus(selected)
        notify(.layoutChanged, node: .window(selected))
    }
    @MainActor func selectTab(_ id: UInt32) { select(id, notifications: .focusThenMain) }
    @MainActor func detachTab(_ id: UInt32) {
        assume(.nativeTabIdentity)
        guard let group = windows[id]?.group else { return }
        groups[group]?.windows.removeAll { $0 == id }
        if groups[group]?.selected == id, let next = groups[group]?.windows.first { groups[group]?.selected = next }
        windows[id]?.group = nil
        action("detach native tab window \(id)")
        focus(id)
        notify(.layoutChanged, node: .window(id))
    }
    func groupMembers(_ id: UInt32) -> [UInt32] { windows[id]?.group.flatMap { groups[$0]?.windows } ?? [id] }

    func visibleIDs() -> [UInt32] {
        assume(.cgOnScreenOrder)
        let bounds = CGRect(x: geometry.frame.minX, y: 0, width: geometry.frame.width, height: geometry.frame.height)
        return zOrder.filter { id in
            guard let w = windows[id], !w.closed, !w.minimized, w.spaces.contains(active),
                  apps[w.pid]?.hidden == false, apps[w.pid]?.terminated == false,
                  w.spec.frame.intersects(bounds) || w.spec.offDisplayMembership == .included else { return false }
            return w.group.flatMap { groups[$0]?.selected == id } ?? true
        }
    }
    func applySize(_ id: UInt32, _ size: CGSize) {
        guard let spec = windows[id]?.spec else { return }
        let accepted = CGSize(width: max(spec.minimumSize.width, min(spec.maximumSize.width, size.width)),
                              height: max(spec.minimumSize.height, min(spec.maximumSize.height, size.height)))
        for member in groupMembers(id) { windows[member]?.spec.frame.size = accepted }
        notify(.resized, node: .window(id))
    }
    func applyPosition(_ id: UInt32, _ point: CGPoint) {
        for member in groupMembers(id) { windows[member]?.spec.frame.origin = point }
        notify(.layoutChanged, node: .window(id))
    }
}

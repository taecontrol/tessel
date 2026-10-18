import AppKit

// SPIKE (deterministic policy). Not production code; see README.md.
// A simulated macOS for the real Workspaces/Rails policy: windows, per-app key
// windows, the frontmost app, a closet, per-app AX write queues, AX reads whose
// delivery the scenario schedules, and a virtual clock.

// Stand-ins for the app types Workspaces.swift references. Same names and
// signatures, no system access.
struct WindowObservation: Sendable {
    var record: WindowRecord
    let frame: CGRect
    let parent: UInt32?
    var replaces: UInt32? = nil
}
enum CatalogChange: Sendable, Equatable { case snapshot, activation, focus, restored }
enum LaunchOptions { static var fixtureOnly: Bool { false } }

final class SnapshotStore: @unchecked Sendable {
    var windows: [pid_t: [WindowRecord]] = [:]
    func update(pid: pid_t, windows: [WindowRecord]?) { self.windows[pid] = windows }
}

@MainActor final class Hotkeys {
    init(keys: [String: String], perform: @escaping (WorkspaceCommand) -> Void) throws { World.current.perform = perform }
    func stop() {}
}

@MainActor final class WindowCloset {
    struct Unavailable: Error { let reason: String }
    init(simulateMissing: Bool, simulateFailedHide: Bool) throws {}
    func start() throws {}
    func hide(_ windows: [UInt32]) { for id in windows { World.current.windows[id]?.hidden = true } }
    func show(_ windows: [UInt32]) { for id in windows { World.current.windows[id]?.hidden = false } }
    func recover(_ windows: [UInt32], offscreen: Set<UInt32>) {}
    func stop(returning windows: [UInt32]) { show(windows) }
}

/// The AX presenter. Each write waits in its app's queue until the scenario
/// executes it, as a real app answers AX messages one after another.
@MainActor final class WindowCatalog {
    func present(pid: pid_t, id: UInt32, area: CGRect?, focus: Bool,
                 completion: @escaping @MainActor @Sendable () -> Void) {
        World.current.enqueue(pid: pid, id: id, frame: area, focus: focus) { _ in completion() }
    }
    func presentRail(pid: pid_t, id: UInt32, frame: CGRect?, position: Bool, resize: Bool, focus: Bool,
                     completion: @escaping @MainActor @Sendable (CGRect?) -> Void) {
        World.current.enqueue(pid: pid, id: id, frame: frame, focus: focus, completion: completion)
    }
    func returnInside(ids: Set<UInt32>, area: CGRect) {}
    /// Approximation of WindowCatalog: a new presentation supersedes queued
    /// geometry; a focus-invalidating one also drops queued focus requests.
    func cancelPresentations(invalidatingFocus: Bool = true) {
        let world: World = World.current
        world.writes = world.writes.compactMap { write in
            var write = write
            write.frame = nil
            if invalidatingFocus { write.focus = false }
            return write.focus ? write : nil
        }
    }
}

@MainActor final class World: WorkspaceSystem {
    static var current: World!
    struct Window { var pid: pid_t; var frame: CGRect; var hidden = false }
    struct Write {
        let pid: pid_t, id: UInt32
        var frame: CGRect?, focus: Bool
        let completion: @MainActor (CGRect?) -> Void
    }
    struct Read { let pid: pid_t; let observations: [WindowObservation]; let focused: UInt32?; let frontmost: Bool; let change: CatalogChange }

    var windows: [UInt32: Window] = [:]
    var keyWindow: [pid_t: UInt32] = [:]
    var front: pid_t?
    var zOrder: [UInt32] = []
    var writes: [Write] = []
    var captured: [Read] = []
    var notifications: [(pid_t, CatalogChange)] = []
    var timers: [(due: Int, order: Int, item: DispatchWorkItem)] = []
    var now = 0, timerOrder = 0
    var focusWrites: [UInt32] = []
    var perform: ((WorkspaceCommand) -> Void)?
    var workspaces: Workspaces!
    let catalog = WindowCatalog()
    let store = SnapshotStore()

    // WorkspaceSystem
    var frontmostPID: pid_t? { front }
    var runningPIDs: [pid_t] { Array(Set(windows.values.map(\.pid))) }
    var screen: (frame: CGRect, visibleFrame: CGRect)? { (CGRect(x: 0, y: 0, width: 1024, height: 768), CGRect(x: 0, y: 0, width: 1024, height: 737)) }
    func onScreenOrder() -> [UInt32] { zOrder.filter { windows[$0]?.hidden == false } }
    func isRunning(_ pid: pid_t) -> Bool { true }
    func after(milliseconds: Int, _ item: DispatchWorkItem) {
        timerOrder += 1
        timers.append((now + milliseconds, timerOrder, item))
    }
    func activateDesktop(_ activate: () -> Void) {}

    // Native effects. A key window change posts the app's AX focus notification.
    func focus(_ id: UInt32) {
        guard let pid = windows[id]?.pid else { return }
        keyWindow[pid] = id
        front = pid
        zOrder.removeAll { $0 == id }; zOrder.insert(id, at: 0)
        notifications.append((pid, .focus))
    }
    func enqueue(pid: pid_t, id: UInt32, frame: CGRect?, focus: Bool, completion: @escaping @MainActor (CGRect?) -> Void) {
        writes.append(Write(pid: pid, id: id, frame: frame, focus: focus, completion: completion))
    }
    func executeWrite() {
        let write = writes.removeFirst()
        if let frame = write.frame { windows[write.id]?.frame = frame }
        if write.focus { focusWrites.append(write.id); focus(write.id) }
        write.completion(write.frame ?? windows[write.id]?.frame)
    }
    /// The catalog reads the app's current AX state; delivery happens later.
    func read(_ pid: pid_t, change: CatalogChange) {
        let observations = windows.filter { $0.value.pid == pid }.sorted { $0.key < $1.key }.map { id, window in
            WindowObservation(record: WindowRecord(id: id, app: "Fixture", bundleId: "com.example.fixture", state: .tiled,
                                                   reason: "standard window", tabs: 1),
                              frame: window.frame, parent: nil)
        }
        captured.append(Read(pid: pid, observations: observations, focused: keyWindow[pid], frontmost: front == pid, change: change))
    }
    func deliver() {
        let read = captured.removeFirst()
        workspaces.update(pid: read.pid, observations: read.observations, focused: read.focused, frontmost: read.frontmost, change: read.change)
    }
    func fireNextTimer() {
        timers.sort { ($0.due, $0.order) < ($1.due, $1.order) }
        let timer = timers.removeFirst()
        now = max(now, timer.due)
        if !timer.item.isCancelled { timer.item.perform() }
    }

    /// Runs everything pending until nothing changes. `writesFirst` chooses
    /// whether queued AX writes or notification reads go first at each step.
    func settle(writesFirst: Bool) {
        for _ in 0..<10_000 {
            if writesFirst, !writes.isEmpty { executeWrite(); continue }
            if let (pid, change) = notifications.first { notifications.removeFirst(); read(pid, change: change); deliver(); continue }
            if !writes.isEmpty { executeWrite(); continue }
            if !timers.isEmpty { fireNextTimer(); continue }
            return
        }
        fatalError("the simulation did not settle")
    }
}

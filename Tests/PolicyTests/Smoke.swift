import Foundation
import CoreGraphics
import Ports
import Testing
@testable import Policy

@Suite struct Smoke {
    @MainActor @Test("Production catalog and workspaces run without macOS adapters")
    func catalogAndWorkspacesRunHeadless() {
        let desktop = EmptyDesktop()
        let ax = EmptyAccessibility()
        let scheduler = InlineScheduling()
        let rows = Rows()
        let configuration = Configuration(experiments: ["workspaces": true])
        let workspaces = Workspaces(store: rows, trusted: true, configuration: configuration,
                                    applications: desktop, ax: ax, screens: desktop, windowOrder: desktop,
                                    scheduler: scheduler, hotkeys: desktop, diagnostics: SilentDiagnostics()) { desktop }
        let catalog = WindowCatalog(workspaces: workspaces, applications: desktop, ax: ax, windowOrder: desktop,
                                    scheduler: scheduler, diagnostics: SilentDiagnostics())
        workspaces.catalog = catalog
        #expect(workspaces.status.enabled)
        #expect(rows.windows[101]?.isEmpty == true)
        #expect(ax.readWindows)
        withExtendedLifetime(catalog) {}
    }
}

private struct SilentDiagnostics: DiagnosticsPort { func record(_ diagnostic: Diagnostic) {} }

@MainActor
private final class Rows: WindowPublishing {
    var windows: [Int32: [WindowRecord]] = [:]
    func update(pid: Int32, windows: [WindowRecord]?) { self.windows[pid] = windows }
}

@MainActor
private final class EmptyDesktop: ApplicationPort, ScreenPort, WindowOrderPort, HotkeyInstalling, ClosetPort {
    nonisolated func listings(_ windows: Set<UInt32>) -> [UInt32: WindowListing] { [:] }
    nonisolated func windowLevels(_ windows: Set<UInt32>) -> [UInt32: Int] { [:] }
    let ownPID: Int32 = 100
    let runningApplications = [RunningApplication(pid: 101, bundleID: "example.fixture", name: "Example",
                                                   hidden: false, terminated: false, prohibited: false)]
    var frontmostPID: Int32? { nil }
    var primaryScreen: ScreenGeometry? {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        return ScreenGeometry(frame: frame, visibleFrame: frame)
    }
    func application(_ pid: Int32) -> RunningApplication? { runningApplications.first { $0.pid == pid } }
    func applications(bundleID: String) -> [RunningApplication] { [] }
    func observe(_ receive: @escaping @MainActor (ApplicationEvent, RunningApplication) -> Void) -> any ApplicationObservation { Observation() }
    func activate(_ pid: Int32) { Issue.record("Unexpected application activation") }
    func isAlive(_ pid: Int32) -> Bool { true }
    func onScreenOrder() -> [UInt32] { [] }
    func install(keys: [String: String], perform: @escaping (WorkspaceCommand) -> Void) throws -> any HotkeyRegistration { Keys() }
    func start() throws {}
    func hide(_ windows: [UInt32]) { #expect(windows.isEmpty) }
    func show(_ windows: [UInt32]) { #expect(windows.isEmpty) }
    func stop(returning windows: [UInt32]) { #expect(windows.isEmpty) }
    func memberships(_ window: UInt32, scope: SpaceScope) -> [SpaceToken] { [] }
    func activeSpace() -> SpaceToken { SpaceToken(adapterValue: 1) }
    var closetSpace: SpaceToken { SpaceToken(adapterValue: 2) }
    private final class Observation: ApplicationObservation {}
    private final class Keys: HotkeyRegistration { func stop() {} }
}

private struct EmptyHandle: AXElementIdentity {
    let pid: Int32
    func isEqual(to other: any AXElementIdentity) -> Bool { (other as? Self)?.pid == pid }
    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
}

private final class EmptyAccessibility: AccessibilityPort, @unchecked Sendable {
    var readWindows = false
    func application(_ pid: Int32) -> AXElement { AXElement(EmptyHandle(pid: pid)) }
    func setMessagingTimeout(_ element: AXElement, seconds: Float) -> AXStatus { .success }
    func copy(_ attribute: AXAttribute, of element: AXElement) -> AXResult<AXValue> {
        switch attribute {
        case .windows: readWindows = true; return AXResult(.success, .elements([]))
        case .hidden, .frontmost: return AXResult(.success, .bool(false))
        case .focusedWindow: return AXResult(.noValue)
        default: preconditionFailure("Unexpected AX attribute in empty-catalog smoke test: \(attribute)")
        }
    }
    func set(_ attribute: AXAttribute, of element: AXElement, to value: AXValue) -> AXStatus { preconditionFailure("Unexpected AX write") }
    func isSettable(_ attribute: AXAttribute, of element: AXElement) -> AXResult<Bool> { preconditionFailure("Unexpected window") }
    func perform(_ action: AXAction, on element: AXElement) -> AXStatus { preconditionFailure("Unexpected AX action") }
    func windowID(_ element: AXElement) -> AXResult<UInt32> { preconditionFailure("Unexpected window") }
    func observer(_ pid: Int32, callback: @escaping @Sendable (AXNotification, AXElement) -> Void) -> AXResult<any AXObservation> { AXResult(.other(-1)) }
}

// These stubs execute immediate work inline and discard timers. They only prove
// that production objects link and start; schedule verification belongs to S2.
private struct InlineScheduling: SchedulingPort {
    var main: any MainLane { Main() }
    func serialLane(label: String) -> any SerialLane { Lane() }
    func backgroundAsync(_ work: @escaping @Sendable () -> Void) { work() }
    func makeLock() -> any PolicyLock { Lock() }
    private struct Work: ScheduledWork { func cancel() {} }
    private struct Lock: PolicyLock { func lock() {}; func unlock() {} }
    private struct Lane: SerialLane {
        func async(_ work: @escaping @Sendable () -> Void) { work() }
        func after(milliseconds: Int, _ work: @escaping @Sendable () -> Void) -> any ScheduledWork { Work() }
        func sync(_ work: @Sendable () -> Void) { work() }
    }
    private struct Main: MainLane {
        func async(_ work: @escaping @MainActor @Sendable () -> Void) { MainActor.assumeIsolated { work() } }
        func after(milliseconds: Int, _ work: @escaping @MainActor @Sendable () -> Void) -> any ScheduledWork { Work() }
    }
}

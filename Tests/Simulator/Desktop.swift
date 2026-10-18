import Foundation
import CoreGraphics
import Ports

extension SimulatedMac {
    @MainActor final class Lifecycle: ApplicationObservation {
        let receive: @MainActor (ApplicationEvent, RunningApplication) -> Void
        init(_ receive: @escaping @MainActor (ApplicationEvent, RunningApplication) -> Void) { self.receive = receive }
    }
    func post(_ event: ApplicationEvent, pid: Int32) {
        guard let app = info(pid) else { return }
        for box in lifecycle {
            guard let token = box.value else { continue }
            scheduler.nativeEvent { [weak token] in
                self.scheduler.note("ApplicationEvent.\(event) \(app.name!) pid=\(pid)")
                token?.receive(event, app)
            }
        }
    }
    @MainActor struct Applications: ApplicationPort, ScreenPort, WindowOrderPort {
        let mac: SimulatedMac
        var ownPID: Int32 { mac.scheduler.call("ApplicationPort.ownPID"); return 1 }
        var runningApplications: [RunningApplication] {
            mac.assume(.applicationLifecycle)
            mac.scheduler.call("ApplicationPort.runningApplications")
            return mac.apps.keys.sorted().compactMap { mac.info($0) }.filter { !$0.terminated }
        }
        var frontmostPID: Int32? {
            mac.assume(.applicationActivation)
            mac.scheduler.call("ApplicationPort.frontmostPID")
            return mac.front
        }
        func application(_ pid: Int32) -> RunningApplication? {
            mac.assume(.applicationLifecycle)
            mac.scheduler.call("ApplicationPort.application pid=\(pid)")
            return mac.info(pid)
        }
        func applications(bundleID: String) -> [RunningApplication] {
            mac.assume(.applicationLifecycle)
            mac.scheduler.call("ApplicationPort.applications bundleID=\(bundleID)")
            return mac.apps.keys.sorted().compactMap { mac.info($0) }.filter { !$0.terminated && $0.bundleID == bundleID }
        }
        func observe(_ receive: @escaping @MainActor (ApplicationEvent, RunningApplication) -> Void) -> any ApplicationObservation {
            mac.assume(.applicationLifecycle)
            mac.scheduler.call("ApplicationPort.observe")
            let token = Lifecycle(receive)
            mac.lifecycle.append(WeakLifecycle(value: token))
            return token
        }
        func activate(_ pid: Int32) {
            mac.assume(.applicationActivation)
            mac.scheduler.call("ApplicationPort.activate \(mac.apps[pid]?.alias ?? "app-unknown") pid=\(pid)")
            guard mac.scheduler.isActive, mac.apps[pid]?.terminated == false else { return }
            mac.front = pid
            mac.post(.activated, pid: pid)
        }
        func isAlive(_ pid: Int32) -> Bool {
            mac.assume(.applicationLifecycle)
            mac.scheduler.call("ApplicationPort.isAlive pid=\(pid)")
            return mac.apps[pid]?.terminated == false
        }
        var primaryScreen: ScreenGeometry? {
            mac.assume(.primaryScreenGeometry)
            mac.scheduler.call("ScreenPort.primaryScreen")
            return mac.geometry
        }
        func onScreenOrder() -> [UInt32] {
            mac.assume(.cgOnScreenOrder)
            mac.scheduler.call("WindowOrderPort.onScreenOrder")
            return mac.visibleIDs()
        }
    }
    @MainActor struct Closet: ClosetPort {
        let mac: SimulatedMac
        let space: UInt64
        func start() throws {
            mac.assume(.closetMoves)
            mac.scheduler.call("ClosetPort.start")
            mac.closetStarted = true
        }
        func hide(_ windows: [UInt32]) {
            mac.assume(.closetMoves)
            mac.scheduler.call("ClosetPort.hide windows=\(windows)")
            move(windows, to: space)
        }
        func show(_ windows: [UInt32]) {
            mac.assume(.closetMoves)
            mac.scheduler.call("ClosetPort.show windows=\(windows)")
            move(windows, to: mac.active)
        }
        func stop(returning windows: [UInt32]) {
            mac.assume(.closetMoves)
            mac.scheduler.call("ClosetPort.stop returning=\(windows)")
            move(windows, to: mac.active)
            mac.closetStarted = false
        }
        private func move(_ ids: [UInt32], to space: UInt64) {
            guard mac.scheduler.isActive else { return }
            for id in ids {
                for member in mac.groupMembers(id) { mac.windows[member]?.space = space }
                for child in mac.windows.keys.sorted() where mac.windows[child]?.spec.parent == id { mac.windows[child]?.space = space }
            }
        }
        func memberships(_ window: UInt32, scope: SpaceScope) -> [SpaceToken] {
            mac.assume(.closetMembership)
            mac.scheduler.call("ClosetPort.memberships window \(window) scope=\(scope)")
            guard let space = mac.windows[window]?.space else { return [] }
            if case .ordinary = scope, space >= 2 && space < 10_000 { return [] }
            return [SpaceToken(adapterValue: space)]
        }
        func activeSpace() -> SpaceToken {
            mac.assume(.closetMembership)
            mac.scheduler.call("ClosetPort.activeSpace")
            return SpaceToken(adapterValue: mac.active)
        }
        var closetSpace: SpaceToken {
            mac.assume(.closetMembership)
            mac.scheduler.call("ClosetPort.closetSpace")
            return SpaceToken(adapterValue: space)
        }
    }
}

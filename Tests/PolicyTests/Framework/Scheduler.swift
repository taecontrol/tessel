import Foundation
import Ports
import Simulator
import Testing

@Suite @MainActor struct SchedulerFramework {
    @Test("E6: an endless poll stops at the virtual-time bound")
    func endlessPoll() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        scheduler.maxMilliseconds = 1_200
        func poll() {
            scheduler.main.after(milliseconds: 500) { poll() }
        }
        poll()
        let outcome = scheduler.run()
        guard case .virtualTimeBound(let pending) = outcome else {
            Issue.record("Expected virtual-time bound with pending poll, got \(outcome)")
            return
        }
        #expect(pending.contains("main"))
    }

    @Test("E6: a zero-time livelock stops at the transition bound")
    func livelock() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        scheduler.maxTransitions = 40
        func again() { scheduler.main.async { again() } }
        again()
        let outcome = scheduler.run()
        guard case .transitionBound(let pending) = outcome else {
            Issue.record("Expected transition bound with pending work, got \(outcome)")
            return
        }
        #expect(pending.contains("main"))
    }

    @Test("E7: unmodeled operations stop and name the call")
    func unmodeled() {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let ax = mac.ax
        let application = ax.application(app.pid)
        let window = ax.copy(.windows, of: application).value!.elements!.first!
        let result = ax.isSettable(.position, of: window)
        #expect(result.status == .cannotComplete)
        #expect(mac.settle() == .unmodeled("AccessibilityPort.isSettable AXPosition window 1 app-A"))
    }
}

import Foundation
import CoreGraphics
import Ports
import Simulator
import Testing

private final class BatonValues: @unchecked Sendable {
    var events: [String] = []
    var status: AXStatus?
}

@Suite @MainActor struct PortScheduling {
    @Test("successful AX reads and writes allow a timer to overtake their replies", arguments: [false, true])
    func successfulAXCallsCostTime(writes: Bool) {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let ax = mac.ax
        let application = ax.application(app.pid)
        let window = ax.copy(.windows, of: application).value!.elements!.first!
        let values = BatonValues()
        let start = mac.scheduler.now
        mac.scheduler.serialLane(label: "test.successful-ax").async {
            for _ in 0..<2 {
                values.status = writes ? ax.set(.position, of: window, to: .point(CGPoint(x: 40, y: 60)))
                    : ax.copy(.position, of: window).status
            }
            values.events.append("AX returned")
        }
        mac.scheduler.main.after(milliseconds: 1) { values.events.append("timer") }
        #expect(mac.settle() == .settled)
        #expect(values.status == .success)
        #expect(values.events == ["timer", "AX returned"])
        #expect(mac.scheduler.now > start + 1)
    }

    @Test("main port calls yield to a ready worker without reentering main")
    func mainYield() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        scheduler.writeOrder = .readsFirst
        scheduler.serialLane(label: "test.main-yield").async { values.events.append("worker") }
        scheduler.main.async {
            scheduler.writeOrder = .writesFirst
            scheduler.call("main port marker")
            values.events.append("main continued")
        }
        #expect(scheduler.run() == .settled)
        #expect(values.events == ["worker", "main continued"])
    }

    @Test("a main port call returns after one worker yield even when that worker stays ready")
    func singleMainStep() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        scheduler.writeOrder = .readsFirst
        scheduler.serialLane(label: "test.single-step").async {
            values.events.append("worker began")
            scheduler.call("first worker port")
            values.events.append("first port returned")
            scheduler.call("second worker port")
            values.events.append("second port returned")
        }
        scheduler.writeOrder = .writesFirst
        scheduler.call("main port")
        values.events.append("main continued")
        #expect(scheduler.run() == .settled)
        #expect(values.events == ["worker began", "main continued", "first port returned", "second port returned"])
    }

    @Test("a main AX wait resumes at its own virtual deadline before the worker's reply")
    func mainReplyDeadline() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        scheduler.writeOrder = .readsFirst
        scheduler.serialLane(label: "test.main-reply").async {
            scheduler.reply("worker reply", cost: 100)
            values.events.append("worker returned at \(scheduler.now)")
        }
        scheduler.main.async {
            scheduler.reply("main reply", cost: 10)
            values.events.append("main returned at \(scheduler.now)")
        }
        #expect(scheduler.run() == .settled)
        #expect(values.events == ["main returned at 10", "worker returned at 100"])
    }

    @Test("a worker drain observes its transition bound and unwinds on shutdown")
    func workerTransitionBound() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        scheduler.writeOrder = .readsFirst
        scheduler.serialLane(label: "test.worker-bound").async {
            for _ in 0..<10 { scheduler.call("worker port") }
            values.events.append(Thread.isMainThread ? "main" : "worker unwound")
        }
        scheduler.maxTransitions = 4
        guard case .transitionBound(let pending) = scheduler.run() else { Issue.record("Expected worker transition bound"); return }
        #expect(scheduler.transitions == 4)
        #expect(pending.contains("test.worker-bound"))
        #expect(scheduler.trace.last?.hasPrefix("[0ms] main STOP transition bound") == true)
        scheduler.shutdown()
        #expect(values.events == ["worker unwound"])
    }

    @Test("a worker reply cannot advance past the virtual-time bound")
    func workerVirtualTimeBound() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        scheduler.writeOrder = .readsFirst
        scheduler.serialLane(label: "test.worker-time-bound").async { scheduler.reply("worker reply", cost: 10) }
        scheduler.maxMilliseconds = 5
        guard case .virtualTimeBound(let pending) = scheduler.run() else { Issue.record("Expected worker virtual-time bound"); return }
        #expect(scheduler.now == 0)
        #expect(pending.contains("test.worker-time-bound"))
        #expect(scheduler.trace.last?.hasPrefix("[0ms] main STOP virtual-time bound") == true)
    }

    @Test("a native event cannot masquerade as captured read delivery")
    func capturedDelivery() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        scheduler.serialLane(label: "tessel.ax.101").async {
            scheduler.reply("read app-A taken", cost: 1, point: .read(101))
            scheduler.nativeEvent { values.events.append("native event") }
            scheduler.main.async { values.events.append("publication") }
        }
        _ = scheduler.run(until: .read(101))
        scheduler.resume()
        let delivered = scheduler.run(until: .delivery(101))
        if case .paused = delivered {} else { Issue.record("Expected captured delivery, got \(delivered)") }
        #expect(values.events == ["native event", "publication"])
    }

    @Test("a frontmost query in another job cannot inherit an earlier focus capture")
    func captureCannotCrossJobs() {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let ax = mac.ax
        let application = ax.application(app.pid)
        let lane = mac.scheduler.serialLane(label: "tessel.ax.100")
        lane.async { _ = ax.copy(.focusedWindow, of: application) }
        lane.async {
            _ = ax.copy(.frontmost, of: application)
            mac.scheduler.main.async {}
        }
        let outcome = mac.scheduler.run(until: .delivery(app))
        guard case .deadlock(let detail) = outcome else { Issue.record("Unrelated hop was called read delivery: \(outcome)"); return }
        #expect(detail.contains("was not reached"))
    }

    @Test("a synchronous main frame never reports a false pause")
    func mainPauseIsUnmodeled() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        scheduler.main.async { scheduler.call("main pause marker") }
        #expect(scheduler.run(until: .call("main pause marker")) == .unmodeled("BatonScheduler.pause main-lane call main pause marker"))
    }

    @Test("sync drains an in-flight lane and its FIFO predecessors without reentering main")
    func synchronousDrain() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        let lane = scheduler.serialLane(label: "test.fifo")
        lane.async {
            values.events.append("began")
            scheduler.call("in-flight marker")
            values.events.append("finished")
        }
        let paused = scheduler.run(until: .call("in-flight marker"))
        if case .paused = paused {} else { Issue.record("Expected in-flight pause, got \(paused)") }
        lane.async { values.events.append("predecessor") }
        scheduler.main.async { values.events.append("main") }
        scheduler.resume()
        lane.sync { values.events.append("sync") }
        #expect(values.events == ["began", "finished", "predecessor", "sync"])
        #expect(scheduler.run() == .settled)
        #expect(values.events.last == "main")
    }

    @Test("a bound unwinds an in-flight sync before its nonescaping body returns")
    func boundDuringSync() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        let lane = scheduler.serialLane(label: "test.sync-bound")
        scheduler.maxTransitions = 3
        lane.sync {
            values.events.append("began")
            for index in 0..<5 { scheduler.call("sync marker \(index)") }
            values.events.append("finished")
        }
        guard case .transitionBound = scheduler.run() else { Issue.record("Expected bounded sync"); return }
        #expect(values.events == ["began", "finished"])
    }

    @Test("a lock wait drains its holder before allowing main to acquire it")
    func lockContention() {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        let values = BatonValues()
        let lock = scheduler.makeLock()
        scheduler.serialLane(label: "test.lock").async {
            lock.lock()
            scheduler.call("lock holder marker")
            values.events.append("worker owns lock")
            lock.unlock()
        }
        _ = scheduler.run(until: .call("lock holder marker"))
        scheduler.resume()
        lock.lock()
        values.events.append("main owns lock")
        lock.unlock()
        #expect(scheduler.run() == .settled)
        #expect(values.events == ["worker owns lock", "main owns lock"])
    }

    @Test("an AX timeout is overtaken by a main timer in virtual time")
    func timeoutIsNotAtomic() {
        let mac = SimulatedMac()
        defer { mac.shutdown() }
        let app = mac.launch(windows: 1)
        let ax = mac.ax
        let application = ax.application(app.pid)
        ax.setMessagingTimeout(application, seconds: 0.05)
        app.hang()
        let values = BatonValues()
        mac.scheduler.serialLane(label: "test.timeout").async {
            values.status = ax.copy(.windows, of: application).status
            values.events.append("AX returned")
        }
        mac.scheduler.main.after(milliseconds: 10) { values.events.append("timer") }
        #expect(mac.settle() == .settled)
        #expect(values.status == .cannotComplete)
        #expect(values.events == ["timer", "AX returned"])
    }
}

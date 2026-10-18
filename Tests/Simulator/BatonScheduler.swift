import Foundation
import CryptoKit
import Ports

package enum RunOutcome: Equatable, Sendable, CustomStringConvertible {
    case settled, paused(String), transitionBound(String), virtualTimeBound(String), unmodeled(String), deadlock(String)

    package var description: String {
        switch self {
        case .settled: "settled"
        case .paused(let detail): "paused: \(detail)"
        case .transitionBound(let detail): "transition bound; pending \(detail)"
        case .virtualTimeBound(let detail): "virtual-time bound; pending \(detail)"
        case .unmodeled(let detail): "unmodeled: \(detail)"
        case .deadlock(let detail): "deadlock: \(detail)"
        }
    }
}

package enum WriteOrder: String, CaseIterable, Sendable {
    case eager, writesFirst, readsFirst
}

package enum PausePoint: Equatable, Sendable {
    case read(Int32), delivery(Int32), call(String)
}

/// Only the baton holder touches state. Semaphore handoffs establish the
/// happens-before edges, including between a lane and the real main actor.
package final class BatonScheduler: SchedulingPort, @unchecked Sendable {
    package var maxTransitions = 100_000
    package var maxMilliseconds = 60_000
    package var writeOrder = WriteOrder.writesFirst
    package private(set) var now = 0
    package private(set) var transitions = 0
    package private(set) var trace: [String] = []
    package private(set) var failure: RunOutcome?
    package var isActive: Bool { failure == nil && !stopped }
    package var currentJobID: Int? {
        if case .lane(let id) = context { lanes[id].current?.id } else { nil }
    }
    package var main: any MainLane { Main(scheduler: self) }
    package var digest: String { Self.digest(trace.joined(separator: "\n") + "\n") }
    package static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum Context: Equatable { case main, lane(Int) }
    private final class Lane: @unchecked Sendable {
        let id: Int
        let label: String
        let wake = DispatchSemaphore(value: 0)
        var queue: [Job] = []
        var current: Job?
        var readyAt = 0
        var held = false
        var capturedRead: Int32?
        var waiting: (() -> Bool)?
        var stopping = false
        init(id: Int, label: String) { self.id = id; self.label = label }
    }
    private struct Job {
        let id: Int
        let body: @Sendable () -> Void
        let cancellation: Cancellation?
    }
    private struct MainJob {
        let id: Int
        let origin: Int32?
        let body: @MainActor @Sendable () -> Void
        let cancellation: Cancellation?
    }
    private enum Target { case lane(Int, Job), main(MainJob) }
    private struct Timer { let due: Int; let id: Int; let target: Target }
    private enum Choice { case lane(Int), main, advance(Int) }
    private final class SyncBox: @unchecked Sendable {
        var body: (@Sendable () -> Void)?
        var done = false
    }
    private var lanes: [Lane] = []
    private var mainQueue: [MainJob] = []
    private var timers: [Timer] = []
    private var running: Int?
    private var lastLane: Int?
    private var sequence = 0
    private var mainDepth = 0
    private var mainBlocked = 0
    private var mainWake: Int?
    private var pauseTarget: PausePoint?
    private var pauseHit: String?
    private var stopped = false
    private var workerDrain: (allowMain: Bool, allowTimers: Bool)?
    private let returned = DispatchSemaphore(value: 0)

    package init() {}

    private var context: Context { if let running { .lane(running) } else { .main } }
    private var contextName: String {
        switch context { case .main: "main"; case .lane(let id): lanes[id].label }
    }
    private func nextID() -> Int { sequence += 1; return sequence }
    package func note(_ text: String) { trace.append("[\(now)ms] \(contextName) \(text)") }

    package func serialLane(label: String) -> any SerialLane {
        call("SchedulingPort.serialLane \(label)")
        let lane = Lane(id: lanes.count, label: label)
        lanes.append(lane)
        let thread = Thread { [self, lane] in
            while true {
                lane.wake.wait()
                if lane.stopping { returned.signal(); return }
                let job = lane.current!
                if job.cancellation?.cancelled != true { job.body() }
                else { note("cancelled #\(job.id)") }
                lane.current = nil
                lane.capturedRead = nil
                lane.waiting = nil
                lane.readyAt = now
                returned.signal()
            }
        }
        thread.name = "simulated.\(label)"
        thread.start()
        return Serial(scheduler: self, id: lane.id)
    }

    package func backgroundAsync(_ work: @escaping @Sendable () -> Void) {
        call("SchedulingPort.backgroundAsync")
        // A global submission has an independent lane: it must not serialize
        // unrelated Finder probes behind another background request.
        serialLane(label: "background.\(sequence + 1)").async(work)
    }

    package func makeLock() -> any PolicyLock {
        call("SchedulingPort.makeLock")
        return Lock(scheduler: self, id: nextID())
    }

    /// Every port operation reaches this point before observing or changing OS
    /// state. Main may pass the baton to a worker without reentering main.
    package func call(_ label: String) {
        guard failure == nil, !stopped else { return }
        note(label)
        checkpoint(.call(label), label: label)
        if context == .main, writeOrder != .readsFirst, failure == nil,
           case .lane = choice(allowMain: false, allowTimers: false) {
            _ = step(allowMain: false, allowTimers: false)
        }
    }

    /// The reply is already captured. While its lane waits for delivery,
    /// timers and other apps can overtake even an AX timeout.
    package func reply(_ label: String, cost: Int, point: PausePoint? = nil) {
        guard failure == nil, !stopped else { return }
        note(label)
        if case .lane(let id) = context {
            if case .read(let pid) = point { lanes[id].capturedRead = pid }
            lanes[id].readyAt = now + max(0, cost)
            checkpoint(point, label: label)
        } else if cost > 0 {
            let deadline = now + cost
            mainWake = deadline
            defer { mainWake = nil }
            waitOnMain("AX reply") { self.now >= deadline }
        }
    }

    private func checkpoint(_ point: PausePoint?, label: String) {
        if let point, point == pauseTarget {
            if context == .main {
                stop(with: .unmodeled("BatonScheduler.pause main-lane call \(label)"))
                return
            }
            pauseTarget = nil
            pauseHit = label
            if case .lane(let id) = context { lanes[id].held = true }
        }
        guard case .lane(let id) = context else { return }
        // A drain would hand the baton straight back to this lane. Keep its
        // stack running, but still make every choice and count every step.
        // Single-step main calls and waits must return to their caller first.
        if let drain = workerDrain {
            draining: while failure == nil, pauseHit == nil, transitions < maxTransitions,
                            let next = choice(allowMain: drain.allowMain, allowTimers: drain.allowTimers) {
                switch next {
                case .lane(let nextID) where nextID == id:
                    transitions += 1
                    return
                case .advance(let time) where time <= maxMilliseconds:
                    transitions += 1
                    advance(to: time, allowTimers: drain.allowTimers)
                default: break draining
                }
            }
        }
        returned.signal()
        lanes[id].wake.wait()
    }

    package func resume() {
        pauseHit = nil
        for lane in lanes { lane.held = false }
    }

    package func failUnmodeled(_ call: String) { stop(with: .unmodeled(call)) }
    private func stop(with outcome: RunOutcome) {
        guard failure == nil else { return }
        note("STOP \(outcome)")
        failure = outcome
    }

    private func pending() -> String {
        var parts = lanes.filter { $0.current != nil || !$0.queue.isEmpty }.map {
            "\($0.label):\($0.queue.count + ($0.current == nil ? 0 : 1))\($0.held ? " held" : "") ready@\($0.readyAt)ms"
        }
        if !mainQueue.isEmpty { parts.append("main:\(mainQueue.count)") }
        if let timer = timers.first {
            let target: String = switch timer.target { case .main: "main"; case .lane(let id, _): lanes[id].label }
            parts.append("timers:\(timers.count) \(target) next@\(timer.due)ms")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }

    private func choice(allowMain: Bool, allowTimers: Bool) -> Choice? {
        // Expired timers enqueue now, even with runnable work. Equal deadlines
        // use submission order; scenarios must never use that as an oracle.
        if allowTimers, let timer = timers.first, timer.due <= now { return .advance(now) }
        let mainReady = allowMain && mainDepth == 0 && mainBlocked == 0 && !mainQueue.isEmpty
        if mainReady && writeOrder == .readsFirst { return .main }
        if let lastLane, ready(lanes[lastLane]) { return .lane(lastLane) }
        for lane in lanes where ready(lane) { return .lane(lane.id) }
        if mainReady { return .main }
        var wake = mainWake
        if allowTimers, let due = timers.first?.due { wake = min(wake ?? due, due) }
        for lane in lanes where !lane.held && (lane.current != nil || !lane.queue.isEmpty) && lane.readyAt > now {
            wake = min(wake ?? lane.readyAt, lane.readyAt)
        }
        if let wake { return .advance(wake) }
        return nil
    }

    private func ready(_ lane: Lane) -> Bool {
        !lane.held && (lane.current != nil || !lane.queue.isEmpty) && lane.readyAt <= now && (lane.waiting?() ?? true)
    }

    private func advance(to time: Int, allowTimers: Bool) {
        now = max(now, time)
        while allowTimers, let timer = timers.first, timer.due <= now {
            timers.removeFirst()
            switch timer.target {
            case .lane(let id, let job): lanes[id].queue.append(job)
            case .main(let job): mainQueue.append(job)
            }
            // Advancing is a main scheduler step, even when a worker retains
            // the baton through it. Keep the trace independent of handoffs.
            trace.append("[\(now)ms] main timer #\(timer.id) ready")
        }
    }

    private func step(allowMain: Bool = true, allowTimers: Bool = true, draining: Bool = false) -> Bool {
        guard failure == nil, pauseHit == nil, let choice = choice(allowMain: allowMain, allowTimers: allowTimers) else { return false }
        if transitions >= maxTransitions { stop(with: .transitionBound("t=\(now)ms; \(pending())")); return false }
        transitions += 1
        switch choice {
        case .advance(let time):
            if time > maxMilliseconds { stop(with: .virtualTimeBound("t=\(now)ms; \(pending())")); return false }
            advance(to: time, allowTimers: allowTimers)
        case .main:
            let job = mainQueue.removeFirst()
            note("main begin #\(job.id)")
            mainDepth += 1
            if job.cancellation?.cancelled != true { MainActor.assumeIsolated { job.body() } }
            else { note("cancelled #\(job.id)") }
            mainDepth -= 1
            if let pid = job.origin, pauseTarget == .delivery(pid) {
                pauseTarget = nil
                pauseHit = "delivery app pid=\(pid)"
            }
        case .lane(let id):
            let lane = lanes[id]
            if lane.current == nil {
                lane.current = lane.queue.removeFirst()
                note("\(lane.label) begin #\(lane.current!.id)")
            }
            running = id
            lastLane = id
            workerDrain = draining ? (allowMain, allowTimers) : nil
            lane.wake.signal()
            returned.wait()
            workerDrain = nil
            running = nil
        }
        return true
    }

    @discardableResult
    package func run(until point: PausePoint? = nil) -> RunOutcome {
        precondition(Thread.isMainThread)
        pauseTarget = point
        pauseHit = nil
        while step(draining: true) {}
        if let failure { return failure }
        if let pauseHit { return .paused(pauseHit) }
        if lanes.contains(where: \.held) { return .paused(pending()) }
        if let point { stop(with: .deadlock("checkpoint \(point) was not reached; \(pending())")); return failure! }
        if lanes.contains(where: { $0.current != nil || !$0.queue.isEmpty }) {
            stop(with: .deadlock(pending())); return failure!
        }
        return .settled
    }

    /// Eager writes run the already submitted serial work after a user step.
    /// Main notifications and future timers remain queued for explicit reads.
    package func runReadyWorkers() {
        pauseHit = nil
        while step(allowMain: false, allowTimers: false, draining: true) {}
    }

    private func waitOnMain(_ name: String, until done: () -> Bool) {
        mainBlocked += 1
        let previousPause = pauseHit
        pauseHit = nil
        defer { mainBlocked -= 1; pauseHit = previousPause ?? pauseHit }
        while !done(), failure == nil {
            if !step(allowMain: false) { stop(with: .deadlock("main waits on \(name); \(pending())")) }
        }
    }

    /// Pending closures are dropped after failure. In-flight production frames
    /// unwind with failed port calls so their retained owners can be released.
    package func shutdown() {
        precondition(Thread.isMainThread)
        guard !stopped else { return }
        stopped = true
        for lane in lanes where lane.current != nil {
            finishInFlight(lane)
        }
        for lane in lanes {
            lane.queue.removeAll()
            lane.stopping = true
            lane.wake.signal()
            returned.wait()
        }
        mainQueue.removeAll()
        timers.removeAll()
    }

    private func enqueue(_ id: Int, work: @escaping @Sendable () -> Void, cancellation: Cancellation? = nil) {
        call("SerialLane.async \(lanes[id].label)")
        guard failure == nil, !stopped else { return }
        lanes[id].queue.append(Job(id: nextID(), body: work, cancellation: cancellation))
    }
    private func enqueueMain(_ work: @escaping @MainActor @Sendable () -> Void, event: Bool = false) {
        call(event ? "MainLane.async native event" : "MainLane.async")
        guard failure == nil, !stopped else { return }
        var pid: Int32?
        if !event, case .lane(let id) = context {
            pid = lanes[id].capturedRead
            lanes[id].capturedRead = nil
        }
        mainQueue.append(MainJob(id: nextID(), origin: pid, body: work, cancellation: nil))
    }
    package func nativeEvent(_ work: @escaping @MainActor @Sendable () -> Void) { enqueueMain(work, event: true) }
    private func after(_ ms: Int, target: Target, cancellation: Cancellation) -> any ScheduledWork {
        call("SchedulingPort.after +\(ms)ms")
        guard failure == nil, !stopped else { return cancellation }
        let timer = Timer(due: now + max(0, ms), id: nextID(), target: target)
        timers.append(timer)
        timers.sort { ($0.due, $0.id) < ($1.due, $1.id) }
        return cancellation
    }
    private func sync(_ id: Int, _ work: @Sendable () -> Void) {
        call("SerialLane.sync \(lanes[id].label)")
        guard context == .main else { stop(with: .unmodeled("SerialLane.sync from a worker")); return }
        guard failure == nil, !stopped else { return }
        withoutActuallyEscaping(work) { escaped in
            let box = SyncBox()
            box.body = escaped
            enqueue(id) { box.body?(); box.done = true }
            waitOnMain("sync \(lanes[id].label)") { box.done }
            if !box.done {
                // Do not let a nonescaping closure survive its caller on abort.
                finishInFlight(lanes[id])
            }
            box.body = nil
        }
    }

    private func finishInFlight(_ lane: Lane) {
        guard lane.current != nil else { return }
        running = lane.id
        lane.wake.signal()
        returned.wait()
        running = nil
    }

    private final class Cancellation: ScheduledWork, @unchecked Sendable {
        unowned let scheduler: BatonScheduler
        var cancelled = false
        init(_ scheduler: BatonScheduler) { self.scheduler = scheduler }
        func cancel() { scheduler.call("ScheduledWork.cancel"); cancelled = true }
    }
    private struct Serial: SerialLane {
        let scheduler: BatonScheduler
        let id: Int
        func async(_ work: @escaping @Sendable () -> Void) { scheduler.enqueue(id, work: work) }
        func after(milliseconds: Int, _ work: @escaping @Sendable () -> Void) -> any ScheduledWork {
            let cancellation = Cancellation(scheduler)
            let job = Job(id: scheduler.nextID(), body: work, cancellation: cancellation)
            return scheduler.after(milliseconds, target: .lane(id, job), cancellation: cancellation)
        }
        func sync(_ work: @Sendable () -> Void) { scheduler.sync(id, work) }
    }
    private struct Main: MainLane {
        let scheduler: BatonScheduler
        func async(_ work: @escaping @MainActor @Sendable () -> Void) { scheduler.enqueueMain(work) }
        func after(milliseconds: Int, _ work: @escaping @MainActor @Sendable () -> Void) -> any ScheduledWork {
            let cancellation = Cancellation(scheduler)
            let job = MainJob(id: scheduler.nextID(), origin: nil, body: work, cancellation: cancellation)
            return scheduler.after(milliseconds, target: .main(job), cancellation: cancellation)
        }
    }
    private final class Lock: PolicyLock, @unchecked Sendable {
        unowned let scheduler: BatonScheduler
        let id: Int
        var owner: Context?
        init(scheduler: BatonScheduler, id: Int) { self.scheduler = scheduler; self.id = id }
        func lock() {
            scheduler.call("PolicyLock.lock #\(id)")
            guard scheduler.failure == nil, !scheduler.stopped else { return }
            let me = scheduler.context
            if owner == me { scheduler.stop(with: .deadlock("recursive PolicyLock #\(id)")); return }
            if owner != nil {
                if case .lane(let lane) = me {
                    scheduler.lanes[lane].waiting = { self.owner == nil }
                    scheduler.checkpoint(nil, label: "lock wait")
                    scheduler.lanes[lane].waiting = nil
                } else { scheduler.waitOnMain("lock #\(id)") { self.owner == nil } }
            }
            if scheduler.failure == nil { owner = me }
        }
        func unlock() { scheduler.call("PolicyLock.unlock #\(id)"); owner = nil }
    }
}

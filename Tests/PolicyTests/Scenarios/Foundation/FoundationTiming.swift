import Foundation
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct FoundationTiming {
    @Test("#1 E11: a stalled connection or reply fails before one virtual second", arguments: [SocketDeadline.Connection.pending, .connected])
    func stalled(_ connection: SocketDeadline.Connection) {
        var now: UInt64 = 4_000_000_000
        let start = now
        let deadline = SocketDeadline.request(now: { now })
        let poll: (Int32) -> SocketDeadline.Readiness = { milliseconds in
            now += UInt64(milliseconds) * 1_000_000
            return .timeout
        }
        #expect(throws: IPCError.timeout) {
            try deadline.connect(connection, poll: poll)
            try deadline.wait(poll: poll)
        }
        #expect(now - start >= 750_000_000 && now - start < 1_000_000_000)
        #expect(IPCError.timeout.cliMessage == "Tessel is not responding")
    }

    @Test("#1 E11: an absent listener or failed readiness reports not running immediately", arguments: [false, true])
    func unavailable(_ readinessFailure: Bool) {
        let now: UInt64 = 4_000_000_000
        let deadline = SocketDeadline.request(now: { now })
        var polls = 0
        let poll: (Int32) -> SocketDeadline.Readiness = { _ in polls += 1; return .unavailable }
        #expect(throws: IPCError.unavailable) {
            try deadline.connect(readinessFailure ? .connected : .unavailable, poll: poll)
            try deadline.wait(poll: poll)
        }
        #expect(polls == (readinessFailure ? 1 : 0))
        #expect(IPCError.unavailable.cliMessage == "Tessel is not running")
    }

    @Test("#1 E11: connect, write and interrupted reads share the original virtual deadline")
    func interrupted() throws {
        var now: UInt64 = 4_000_000_000
        let start = now
        let deadline = SocketDeadline.request(now: { now })
        var waits: [Int32] = []
        try deadline.connect(.pending) { milliseconds in
            waits.append(milliseconds)
            now += 100_000_000
            return .ready
        }
        try deadline.wait { milliseconds in
            waits.append(milliseconds)
            now += 200_000_000
            return .ready
        }
        #expect(throws: IPCError.timeout) {
            try deadline.wait { milliseconds in
                waits.append(milliseconds)
                if waits.count < 5 { now += 200_000_000; return .interrupted }
                now += UInt64(milliseconds) * 1_000_000
                return .timeout
            }
        }
        #expect(waits == [751, 651, 451, 251, 51])
        #expect(now - start < 1_000_000_000)
    }

    @Test("#1 E11: an interrupt at the deadline expires without another poll")
    func expiredAfterInterrupt() {
        var now: UInt64 = 4_000_000_000
        let deadline = SocketDeadline.request(now: { now })
        var polls = 0
        #expect(throws: IPCError.timeout) {
            try deadline.wait { _ in
                polls += 1
                now += 750_000_000
                return polls == 1 ? .interrupted : .unavailable
            }
        }
        #expect(polls == 1)
    }

    @Test("#1 E14: a grant is noticed on the next virtual tick and immediately requests one relaunch", arguments: [1, 751, 801], [false, true])
    func permissionGranted(_ grantAt: Int, _ delayedTimer: Bool) throws {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        scheduler.maxMilliseconds = 4_000
        let timer = PermissionTimer(scheduler: scheduler, delayed: delayedTimer)
        var trusted = false
        var trustedProbeAt: Int?
        var requests: [Int] = []
        let polling = PermissionPolling(startTimer: timer.start, probe: { completed in
            if trusted { trustedProbeAt = scheduler.now }
            completed(trusted)
        }, granted: { requests.append(scheduler.now) })
        polling.start()
        scheduler.main.after(milliseconds: grantAt) { trusted = true }
        withExtendedLifetime(polling) { #expect(scheduler.run() == .settled) }
        let requestedAt = try #require(requests.first)
        // The 3 s promise includes macOS probe/open costs. Tessel owns one
        // 750 ms tick, its existing 50 ms timer tolerance, and no relaunch delay.
        #expect(requestedAt - grantAt <= (delayedTimer ? 800 : 750))
        #expect(requestedAt == trustedProbeAt)
        #expect(requests.count == 1)
    }

    @Test("#1 E14: an outstanding probe never overlaps and a denied result retries on the next tick")
    func outstandingPermissionProbe() throws {
        let scheduler = BatonScheduler()
        defer { scheduler.shutdown() }
        scheduler.maxMilliseconds = 5_000
        let timer = PermissionTimer(scheduler: scheduler)
        var trusted = false
        var probes: [Int] = []
        var completedAt: Int?
        var requests: [Int] = []
        let polling = PermissionPolling(startTimer: timer.start, probe: { completed in
            probes.append(scheduler.now)
            if probes.count == 1 {
                let answer = trusted
                scheduler.main.after(milliseconds: 1_501) { completedAt = scheduler.now; completed(answer) }
            } else {
                completedAt = scheduler.now
                completed(trusted)
            }
        }, granted: { requests.append(scheduler.now) })
        polling.start()
        scheduler.main.after(milliseconds: 751) { trusted = true }
        withExtendedLifetime(polling) { #expect(scheduler.run() == .settled) }
        #expect(probes == [750, 3_000])
        #expect(requests == [3_000])
        #expect(requests.first == completedAt)
    }
}

@MainActor private final class PermissionTimer {
    private let scheduler: BatonScheduler
    private let delayed: Bool
    private var interval = 0
    private var tick: (@MainActor @Sendable () -> Void)?
    private var pending: (any ScheduledWork)?

    init(scheduler: BatonScheduler, delayed: Bool = false) {
        self.scheduler = scheduler
        self.delayed = delayed
    }

    func start(interval: TimeInterval, tolerance: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        self.interval = Int(((interval + (delayed ? tolerance : 0)) * 1_000).rounded())
        self.tick = tick
        schedule()
        return { self.tick = nil; self.pending?.cancel() }
    }

    private func schedule() {
        pending = scheduler.main.after(milliseconds: interval) { [self] in
            tick?()
            if tick != nil { schedule() }
        }
    }
}

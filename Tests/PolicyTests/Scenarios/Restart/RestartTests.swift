import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct RestartTests {
    @Test("overlapping CLI requests that reach the replacement join it; a fresh invocation can restart it")
    func delayedCLIRequestJoinsReplacement() throws {
        let rig = RestartRig(pid: 202)
        rig.request(.cli, name: "delayed", replacing: 101)
        #expect(rig.outcomes["delayed"] == [.restarted(pid: 202)])
        #expect(rig.launches == 0 && rig.quits == 0)
        #expect(rig.diagnostics.isEmpty)
        rig.request(.cli, name: "fresh", replacing: 202)
        #expect(rig.launches == 1)
        try rig.complete(.success(303))
        #expect(rig.outcomes["fresh"] == [.restarted(pid: 303)])
        #expect(rig.outcomes["delayed"] == [.restarted(pid: 202)])
        #expect(rig.quits == 1)
    }

    @Test("#67 E8: simultaneous CLI requests launch once, reply with the same pid, then quit once")
    func concurrentCLIRequestsShareOneLaunch() throws {
        let rig = RestartRig()
        rig.request(.cli, name: "first")
        rig.request(.cli, name: "second")
        #expect(rig.launches == 1)
        #expect(rig.quits == 0)
        #expect(rig.outcomes.isEmpty, "no request succeeds before launch acceptance")
        try rig.complete(.success(202))
        #expect(rig.outcomes["first"] == [.restarted(pid: 202)])
        #expect(rig.outcomes["second"] == [.restarted(pid: 202)])
        #expect(rig.quits == 1)
        #expect(Array(rig.events.prefix(2)) == ["requested cli", "launch"])
        #expect(Set(rig.events.dropFirst(2).dropLast()) == ["reply first", "reply second"])
        #expect(rig.events.last == "quit" && rig.events.count == 5)
        #expect(rig.diagnostics == [.restartRequested(from: .cli)])
        for _ in 0..<2 {
            var wait = RestartWait(oldPID: 101, deadline: rig.now + 10_000_000_000)
            #expect(wait.replied(.success(Reply(restarted: 202))) == .wait)
            #expect(wait.probed(.success(status(101)), now: rig.now) == .wait)
            #expect(wait.probed(.success(status(202)), now: rig.now + 1) == .done(pid: 202))
        }
    }

    @Test("#67 E12: menu and CLI requests join both a pending launch and a restart already quitting",
          arguments: [RestartSource.menu, .cli])
    func joinsWhileLaunchingAndQuitting(_ source: RestartSource) throws {
        let rig = RestartRig()
        rig.request(source, name: "first")
        rig.request(source == .menu ? .cli : .menu, name: "joining")
        #expect(rig.launches == 1)
        try rig.complete(.success(202))
        rig.restart.quitting()
        rig.request(source, name: "late")
        #expect(rig.launches == 1, "quitting for restart retains its accepted pid")
        #expect(rig.quits == 1)
        for name in ["first", "joining", "late"] {
            #expect(rig.outcomes[name] == [.restarted(pid: 202)])
        }
        #expect(rig.diagnostics == [.restartRequested(from: source)])
    }

    @Test("#67 E12: a request after ordinary Quit is refused without launching or quitting again",
          arguments: [RestartSource.menu, .cli])
    func ordinaryQuitRefusesRestart(_ source: RestartSource) {
        let rig = RestartRig()
        rig.restart.quitting()
        rig.request(source, name: "after quit")
        #expect(rig.outcomes["after quit"] == [.refused("Tessel is quitting")])
        #expect(rig.launches == 0)
        #expect(rig.quits == 0)
        #expect(rig.diagnostics.isEmpty)
    }

    @Test("#67 E12: the CLI preserves starting and quitting refusals verbatim",
          arguments: ["Tessel is starting", "Tessel is quitting"])
    func waitReportsLifecycleRefusal(_ message: String) {
        var wait = RestartWait(oldPID: 101, deadline: 10_000_000_000)
        #expect(wait.replied(.success(Reply(error: message))) == .fail(message))
    }

    @Test("#67 E10: no ready replacement fails at exactly ten virtual seconds, even if it appears later",
          arguments: [IPCError.timeout, .unavailable, .invalidMessage])
    func waitExpiresAtTenSeconds(_ error: IPCError) {
        let start: UInt64 = 4_000_000_000
        let deadline = start + 10_000_000_000
        var wait = RestartWait(oldPID: 101, deadline: deadline)
        #expect(wait.replied(.failure(error)) == .wait)
        #expect(wait.probed(.failure(error), now: start) == .wait)
        #expect(wait.probed(.success(status(101)), now: deadline - 1) == .wait)
        #expect(wait.probed(.failure(error), now: deadline) == .fail("Tessel did not restart within 10 s"))
        #expect(wait.probed(.success(status(202)), now: deadline + 1) == .fail("Tessel did not restart within 10 s"),
                "a late pid cannot turn an already failed command into success")
        // RestartWait has no launch, quit or kill capability: status inputs and
        // virtual time are its entire boundary. No real process is touched.
    }

    @Test("#67 E10: an expired queued CLI request never launches later and does not poison a fresh request")
    func expiredRequestCannotRestartLater() throws {
        let rig = RestartRig()
        let deadline = rig.now + 10_000_000_000
        rig.now = deadline + 1
        rig.request(.cli, name: "expired", deadline: deadline)
        #expect(rig.launches == 0)
        #expect(rig.quits == 0)
        #expect(rig.diagnostics.isEmpty)
        #expect(rig.outcomes["expired"]?.contains(.restarted(pid: 202)) != true)
        // The deadline contract drops the expired request; it does not specify
        // whether the worker is told about a refusal after it has stopped waiting.
        rig.request(.menu, name: "fresh")
        #expect(rig.launches == 1)
        try rig.complete(.success(202))
        #expect(rig.outcomes["fresh"] == [.restarted(pid: 202)])
        #expect(rig.outcomes["expired"]?.contains(.restarted(pid: 202)) != true)
        #expect(rig.quits == 1)
        #expect(rig.diagnostics == [.restartRequested(from: .menu)])
    }

    @Test("#67 E10: an expired request cannot join another launch and later claim that pid")
    func expiredRequestCannotJoinInFlightLaunch() throws {
        let rig = RestartRig()
        rig.request(.menu, name: "owner")
        rig.request(.cli, name: "expired", deadline: rig.now - 1)
        #expect(rig.launches == 1)
        try rig.complete(.success(202))
        #expect(rig.outcomes["owner"] == [.restarted(pid: 202)])
        #expect(rig.outcomes["expired"]?.contains(.restarted(pid: 202)) != true)
        #expect(rig.quits == 1)
    }

    @Test("#67 E10: a launch accepted after every CLI deadline cannot quit the old instance later")
    func expiredLaunchCannotQuitLater() throws {
        let rig = RestartRig()
        let deadline = rig.now + 10_000_000_000
        rig.request(.cli, name: "expired", deadline: deadline)
        rig.now = deadline
        try rig.complete(.success(202))
        #expect(rig.quits == 0)
        #expect(rig.outcomes["expired"] == nil)
        rig.request(.menu, name: "fresh")
        #expect(rig.launches == 2)
        try rig.complete(.success(303))
        #expect(rig.outcomes["fresh"] == [.restarted(pid: 303)])
        #expect(rig.quits == 1)
    }

    @Test("#67 E10: a launch accepted after every CLI deadline cancels only its replacement without quitting")
    func expiredLaunchCancelsReplacement() throws {
        let rig = RestartRig()
        let deadline = rig.now + 10_000_000_000
        rig.request(.cli, name: "first", deadline: deadline - 1)
        rig.request(.cli, name: "second", deadline: deadline)
        rig.now = deadline
        try rig.complete(.success(202))
        #expect(rig.cancellations == [202])
        #expect(rig.quits == 0)
        #expect(rig.outcomes.isEmpty)
    }

    @Test("#67 E12: ordinary Quit during a launch cancels the replacement when it is accepted")
    func quitDuringLaunchCancelsReplacement() throws {
        let rig = RestartRig()
        rig.request(.menu, name: "pending")
        rig.restart.quitting()
        try rig.complete(.success(202))
        #expect(rig.cancellations == [202])
        #expect(rig.quits == 0)
        #expect(rig.outcomes["pending"] == [.refused("Tessel is quitting")])
    }

    @Test("#67 E12: Quit waits for launch completion and cancels an accepted replacement before finishing",
          arguments: [true, false])
    func quitWaitsForLaunchCompletion(accepted: Bool) {
        let rig = RestartRig()
        defer { rig.scheduler.shutdown() }
        rig.request(.menu, name: "pending")
        rig.restart.quitting {
            #expect(rig.cancellations == (accepted ? [202] : []))
            rig.quitCompletions.append(rig.scheduler.now)
        }
        #expect(rig.quitCompletions.isEmpty)
        rig.request(.cli, name: "after quit")
        #expect(rig.outcomes["pending"] == [.refused("Tessel is quitting")])
        #expect(rig.outcomes["after quit"] == [.refused("Tessel is quitting")])
        rig.scheduler.main.after(milliseconds: 500) {
            #expect(rig.quitCompletions.isEmpty)
            let result: Result<Int32, RestartLaunchError> = accepted ? .success(202) : .failure(RestartLaunchError(reason: "Launch denied"))
            #expect(throws: Never.self) { try rig.complete(result) }
            #expect(rig.quitCompletions == [500])
        }
        rig.scheduler.main.after(milliseconds: 3_000) {
            #expect(rig.quitCompletions == [500], "the bound must not finish Quit a second time")
        }
        #expect(rig.scheduler.run() == .settled)
        #expect(rig.quits == 0, "an interrupted launch must not request a handoff quit")
    }

    @Test("#67 E12: Quit finishes immediately without a launch, including an accepted restart handoff",
          arguments: [false, true])
    func quitWithoutPendingLaunchFinishesImmediately(handoff: Bool) throws {
        let rig = RestartRig()
        defer { rig.scheduler.shutdown() }
        if handoff {
            rig.request(.menu, name: "restart")
            try rig.complete(.success(202))
        }
        rig.restart.quitting { rig.quitCompletions.append(rig.scheduler.now) }
        #expect(rig.quitCompletions == [0])
        #expect(rig.scheduler.run() == .settled)
        #expect(rig.scheduler.now == 0, "Quit must not schedule a wait when no launch is outstanding")
        #expect(rig.quitCompletions == [0])
        #expect(rig.cancellations.isEmpty, "a handoff must keep its accepted replacement")
    }

    @Test("#67 E12: an unfinished launch bounds Quit at two virtual seconds, once per caller")
    func quitWaitIsBoundedAtTwoSeconds() {
        let rig = RestartRig()
        defer { rig.scheduler.shutdown() }
        rig.request(.menu, name: "pending")
        rig.restart.quitting { rig.quitCompletions.append(rig.scheduler.now) }
        #expect(rig.quitCompletions.isEmpty)
        rig.scheduler.main.after(milliseconds: 1_000) {
            rig.restart.quitting { rig.quitCompletions.append(rig.scheduler.now) }
            #expect(rig.quitCompletions.isEmpty, "repeated Quit must join the same launch wait")
        }
        rig.scheduler.main.after(milliseconds: 1_999) { #expect(rig.quitCompletions.isEmpty) }
        rig.scheduler.main.after(milliseconds: 2_001) { #expect(rig.quitCompletions == [2_000, 2_000]) }
        rig.scheduler.main.after(milliseconds: 4_000) { #expect(rig.quitCompletions == [2_000, 2_000]) }
        #expect(rig.scheduler.run() == .settled)
        #expect(rig.quits == 0)
    }

    @Test("#67 E10: a launch completing after the Quit bound still cancels its replacement if this process lives")
    func launchAfterQuitBoundStillCancelsReplacement() {
        let rig = RestartRig()
        defer { rig.scheduler.shutdown() }
        let deadline = rig.now + 10_000_000_000
        rig.request(.cli, name: "expired", deadline: deadline)
        rig.now = deadline
        rig.restart.quitting { rig.quitCompletions.append(rig.scheduler.now) }
        rig.scheduler.main.after(milliseconds: 2_001) {
            #expect(rig.quitCompletions == [2_000])
            #expect(throws: Never.self) { try rig.complete(.success(202)) }
            #expect(rig.cancellations == [202])
            #expect(rig.quitCompletions == [2_000], "a late completion must not finish Quit again")
        }
        #expect(rig.scheduler.run() == .settled)
        #expect(rig.quits == 0)
        #expect(rig.outcomes["expired"] == nil)
    }

    @Test("#67 E10: a fresh handoff after an expired launch never cancels the replacement it quits for")
    func freshHandoffDoesNotCancelReplacement() throws {
        let rig = RestartRig()
        let deadline = rig.now + 10_000_000_000
        rig.request(.cli, name: "expired", deadline: deadline)
        rig.now = deadline
        try rig.complete(.success(202))
        rig.request(.menu, name: "fresh")
        try rig.complete(.success(303))
        rig.restart.quitting()
        rig.request(.cli, name: "joining")
        #expect(rig.cancellations == [202], "cancel only the orphan, never the accepted handoff pid or this instance")
        #expect(rig.quits == 1)
        #expect(rig.outcomes["expired"] == nil)
        #expect(rig.outcomes["fresh"] == [.restarted(pid: 303)])
        #expect(rig.outcomes["joining"] == [.restarted(pid: 303)])
    }

    @Test("an accepted launch reply is not CLI success until the new pid answers ready status")
    func launchReplyWaitsForReadiness() {
        var wait = RestartWait(oldPID: 101, deadline: 10_000_000_000)
        #expect(wait.replied(.success(Reply(restarted: 202))) == .wait)
        #expect(wait.probed(.success(status(101)), now: 1) == .wait)
        #expect(wait.probed(.success(Reply(error: "Tessel is starting")), now: 2) == .wait)
        #expect(wait.probed(.failure(.unavailable), now: 3) == .wait)
        #expect(wait.probed(.success(status(202)), now: 4) == .done(pid: 202))
    }

    @Test("a dropped restart reply still succeeds when a different pid answers ready status",
          arguments: [IPCError.unavailable, .timeout, .invalidMessage])
    func lostReplyWaitsForDifferentReadyPID(_ error: IPCError) {
        var wait = RestartWait(oldPID: 101, deadline: 10_000_000_000)
        #expect(wait.replied(.failure(error)) == .wait)
        #expect(wait.probed(.success(status(101)), now: 1) == .wait)
        #expect(wait.probed(.failure(.unavailable), now: 2) == .wait)
        #expect(wait.probed(.success(status(303)), now: 3) == .done(pid: 303))
    }

    @Test("a launch failure reaches every waiter, never quits, and permits one fresh retry")
    func failedLaunchKeepsOldInstanceAndAllowsRetry() throws {
        let rig = RestartRig()
        rig.request(.menu, name: "first")
        rig.request(.cli, name: "joining")
        #expect(rig.launches == 1)
        #expect(rig.quits == 0)
        try rig.complete(.failure(RestartLaunchError(reason: "Launch denied")))
        for name in ["first", "joining"] {
            #expect(rig.outcomes[name] == [.failed("Launch denied")])
        }
        #expect(rig.quits == 0, "a refused launch must leave the current app untouched")
        #expect(Array(rig.events.prefix(3)) == ["requested menu", "launch", "failed Launch denied"])
        #expect(Set(rig.events.dropFirst(3)) == ["reply first", "reply joining"] && rig.events.count == 5)
        #expect(rig.diagnostics == [.restartRequested(from: .menu), .restartFailed(reason: "Launch denied")])
        rig.request(.cli, name: "retry")
        #expect(rig.launches == 2)
        try rig.complete(.success(303))
        #expect(rig.outcomes["retry"] == [.restarted(pid: 303)])
        #expect(rig.outcomes["first"] == [.failed("Launch denied")], "a completed waiter is replied to exactly once")
        #expect(rig.outcomes["joining"] == [.failed("Launch denied")])
        #expect(rig.quits == 1)
    }

    @Test("the CLI reports a launch refusal without waiting for its deadline")
    func waitReportsLaunchFailure() {
        var wait = RestartWait(oldPID: 101, deadline: 10_000_000_000)
        #expect(wait.replied(.success(Reply(error: "Tessel could not restart: Launch denied")))
                == .fail("Tessel could not restart: Launch denied"))
    }

    @Test("ordinary Quit refuses pending restart callers and ignores the later launch completion")
    func quitInterruptsPendingLaunch() throws {
        let rig = RestartRig()
        rig.request(.menu, name: "menu")
        rig.request(.cli, name: "cli")
        rig.restart.quitting()
        for name in ["menu", "cli"] {
            #expect(rig.outcomes[name] == [.refused("Tessel is quitting")])
        }
        try rig.complete(.success(202))
        #expect(rig.launches == 1 && rig.quits == 0)
        for name in ["menu", "cli"] {
            #expect(rig.outcomes[name] == [.refused("Tessel is quitting")])
        }
    }

    @Test("a ready but unrelated process cannot complete an acknowledged restart")
    func waitRequiresAcceptedPID() {
        var wait = RestartWait(oldPID: 101, deadline: 10_000_000_000)
        #expect(wait.replied(.success(Reply(restarted: 202))) == .wait)
        #expect(wait.probed(.success(status(303)), now: 1) == .wait)
        #expect(wait.probed(.success(status(202)), now: 2) == .done(pid: 202))
    }

    @Test("the production restart budget waits until exactly ten seconds")
    func productionTimeoutIsTenSeconds() {
        let start: UInt64 = 4_000_000_000
        var wait = RestartWait(oldPID: 101, deadline: start + RestartWait.timeoutNanoseconds)
        #expect(wait.probed(.failure(.unavailable), now: start + 9_999_999_999) == .wait)
        #expect(wait.probed(.failure(.unavailable), now: start + 10_000_000_000)
                == .fail("Tessel did not restart within 10 s"))
    }

    private func status(_ pid: Int32) -> Reply {
        Reply(status: AppStatus(permission: "granted", config: ConfigStatus(path: "/fixture/tessel.toml"), version: "fixture", pid: pid))
    }
}

// Model the current app's termination boundary until Restart owns its wait:
// quitting() returns and the app may terminate as soon as its drain finishes.
private extension Restart {
    func quitting(then done: @escaping () -> Void) {
        quitting()
        done()
    }
}

/// A virtual monotonic clock and controlled launch completion, with no OS model.
@MainActor private final class RestartRig {
    let pid: Int32
    init(pid: Int32 = 101) { self.pid = pid }
    var now: UInt64 = 4_000_000_000
    let scheduler = BatonScheduler()
    var quitCompletions: [Int] = []
    var launches = 0
    var cancellations: [Int32] = []
    var quits = 0
    var diagnostics: [Diagnostic] = []
    var events: [String] = []
    var outcomes: [String: [Restart.Outcome]] = [:]
    private var completions: [(Result<Int32, RestartLaunchError>) -> Void] = []

    lazy var restart = Restart(pid: pid, now: { [unowned self] in now }, record: { [unowned self] diagnostic in
        diagnostics.append(diagnostic)
        switch diagnostic {
        case .restartRequested(let source): events.append("requested \(source.rawValue)")
        case .restartFailed(let reason): events.append("failed \(reason)")
        default: break
        }
    }, launch: { [unowned self] done in
        launches += 1
        events.append("launch")
        completions.append(done)
    }, cancel: { [unowned self] pid in
        cancellations.append(pid)
    }, quit: { [unowned self] in
        quits += 1
        events.append("quit")
    })

    func request(_ source: RestartSource, name: String, replacing: Int32? = nil, deadline: UInt64? = nil) {
        restart.request(source, replacing: replacing, deadline: deadline ?? (source == .cli ? now + 10_000_000_000 : nil)) { [unowned self] outcome in
            events.append("reply \(name)")
            outcomes[name, default: []].append(outcome)
        }
    }

    func complete(_ result: Result<Int32, RestartLaunchError>) throws {
        let done = try #require(completions.first, "the coordinator must request a launch before its completion can be delivered")
        completions.removeFirst()
        done(result)
    }
}

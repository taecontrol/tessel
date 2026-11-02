#if SWIFT_PACKAGE
import Ports
#endif

struct RestartLaunchError: Error, Equatable {
    let reason: String
}

/// Owns the handoff: keep this instance intact until a replacement is accepted.
@MainActor
final class Restart {
    enum Outcome: Equatable {
        case restarted(pid: Int32)
        case failed(String)
        case refused(String)
    }

    struct Request {
        let deadline: UInt64?
        let reply: (Outcome) -> Void
    }

    private enum Phase {
        case idle
        case launching([Request])
        // An ordinary Quit has no replacement to which a late request can join.
        case quitting(newPID: Int32?)
    }

    private var phase = Phase.idle
    private var quitWaiters: [() -> Void] = []
    private var quitDeadline: (any ScheduledWork)?
    private let pid: Int32
    private let now: () -> UInt64
    private let main: any MainLane
    private let record: (Diagnostic) -> Void
    private let launch: @MainActor (@escaping (Result<Int32, RestartLaunchError>) -> Void) -> Void
    private let cancel: (Int32) -> Void
    private let quit: () -> Void

    init(pid: Int32, now: @escaping () -> UInt64, main: any MainLane,
         record: @escaping (Diagnostic) -> Void,
         launch: @escaping @MainActor (_ done: @escaping (Result<Int32, RestartLaunchError>) -> Void) -> Void,
         cancel: @escaping (Int32) -> Void,
         quit: @escaping () -> Void) {
        self.pid = pid
        self.now = now
        self.main = main
        self.record = record
        self.launch = launch
        self.cancel = cancel
        self.quit = quit
    }

    /// Expired CLI requests are dropped, including ones queued behind a busy main thread.
    func request(_ source: RestartSource, replacing: Int32? = nil, deadline: UInt64?, reply: @escaping (Outcome) -> Void) {
        guard deadline.map({ now() < $0 }) ?? true else { return }
        let request = Request(deadline: deadline, reply: reply)
        switch phase {
        case .idle:
            // Another CLI may have replaced the observed process between this
            // caller's status probe and its restart connection.
            if let replacing, replacing != pid { reply(.restarted(pid: pid)); return }
            phase = .launching([request])
            record(.restartRequested(from: source))
            launch { [weak self] result in self?.completed(result) }
        case .launching(var waiters):
            waiters.append(request)
            phase = .launching(waiters)
        case .quitting(let pid):
            reply(pid.map { .restarted(pid: $0) } ?? .refused("Tessel is quitting"))
        }
    }

    /// Refuses new restarts, then calls `done` once after handling an outstanding
    /// launch or waiting at most 2 s. An accepted handoff has no launch to await.
    func quitting(then done: @escaping () -> Void) {
        switch phase {
        case .idle:
            phase = .quitting(newPID: nil)
            done()
        case .quitting:
            if quitDeadline != nil { quitWaiters.append(done) }
            else { done() }
        case .launching(let pending):
            phase = .quitting(newPID: nil)
            quitWaiters.append(done)
            // Quit must proceed if LaunchServices never replies. If we exit
            // before its callback, a later replacement can still treat that
            // exit as a handoff: we have no pid to cancel until the reply.
            quitDeadline = main.after(milliseconds: 2_000) { [weak self] in self?.finishQuitting() }
            for request in pending where request.deadline.map({ now() < $0 }) ?? true {
                request.reply(.refused("Tessel is quitting"))
            }
        }
    }

    private func finishQuitting() {
        guard quitDeadline != nil else { return }
        quitDeadline?.cancel()
        quitDeadline = nil
        let ready = quitWaiters
        quitWaiters.removeAll()
        for done in ready { done() }
    }

    private func completed(_ result: Result<Int32, RestartLaunchError>) {
        guard case .launching(let waiters) = phase else {
            if case .quitting(nil) = phase {
                if case .success(let pid) = result { cancel(pid) }
                finishQuitting()
            }
            return
        }
        let pending = waiters.filter { request in request.deadline.map({ now() < $0 }) ?? true }
        switch result {
        case .success(let pid):
            // A late LaunchServices callback must not quit on behalf of CLI
            // requests that have all expired. Cancel the waiting replacement
            // so a later quit or restart cannot let it set up.
            guard !pending.isEmpty else {
                phase = .idle
                cancel(pid)
                return
            }
            phase = .quitting(newPID: pid)
            for request in pending { request.reply(.restarted(pid: pid)) }
            quit()
        case .failure(let error):
            phase = .idle
            record(.restartFailed(reason: error.reason))
            for request in pending { request.reply(.failed(error.reason)) }
        }
    }
}

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
    private let pid: Int32
    private let now: () -> UInt64
    private let record: (Diagnostic) -> Void
    private let launch: @MainActor (@escaping (Result<Int32, RestartLaunchError>) -> Void) -> Void
    private let quit: () -> Void

    init(pid: Int32, now: @escaping () -> UInt64,
         record: @escaping (Diagnostic) -> Void,
         launch: @escaping @MainActor (_ done: @escaping (Result<Int32, RestartLaunchError>) -> Void) -> Void,
         quit: @escaping () -> Void) {
        self.pid = pid
        self.now = now
        self.record = record
        self.launch = launch
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

    func quitting() {
        if case .quitting = phase { return }
        let pending: [Request]
        if case .launching(let waiters) = phase { pending = waiters }
        else { pending = [] }
        phase = .quitting(newPID: nil)
        for request in pending where request.deadline.map({ now() < $0 }) ?? true {
            request.reply(.refused("Tessel is quitting"))
        }
    }

    private func completed(_ result: Result<Int32, RestartLaunchError>) {
        guard case .launching(let waiters) = phase else { return }
        let pending = waiters.filter { request in request.deadline.map({ now() < $0 }) ?? true }
        switch result {
        case .success(let pid):
            // A late LaunchServices callback must not quit on behalf of CLI
            // requests that have all expired. The replacement will abandon us.
            guard !pending.isEmpty else { phase = .idle; return }
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

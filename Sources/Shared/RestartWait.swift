/// A launch acknowledgement is provisional until the replacement answers status.
struct RestartWait {
    enum Step: Equatable {
        case wait
        case done(pid: Int32)
        case fail(String)
    }

    static let timeoutNanoseconds: UInt64 = 10_000_000_000
    static let notRunning = "Tessel is not running"
    static let timedOut = "Tessel did not restart within 10 s"
    static func restarted(_ pid: Int32) -> String { "Tessel restarted (pid \(pid))" }
    static func launchFailed(_ reason: String) -> String { "Tessel could not restart: \(reason)" }

    private let oldPID: Int32
    private let deadline: UInt64
    private var acceptedPID: Int32?
    private var terminal: Step?

    init(oldPID: Int32, deadline: UInt64) {
        self.oldPID = oldPID
        self.deadline = deadline
    }

    mutating func replied(_ reply: Result<Reply, IPCError>) -> Step {
        if let terminal { return terminal }
        if case .success(let reply) = reply {
            if let error = reply.error { return finish(.fail(error)) }
            acceptedPID = reply.restarted
        }
        // A lost reply may mean the old process exited after accepting the launch.
        return .wait
    }

    mutating func probed(_ status: Result<Reply, IPCError>, now: UInt64) -> Step {
        if let terminal { return terminal }
        guard now < deadline else { return finish(.fail(Self.timedOut)) }
        if case .success(let reply) = status, reply.error == nil, let pid = reply.status?.pid,
           pid > 0, pid != oldPID, acceptedPID == nil || acceptedPID == pid {
            return finish(.done(pid: pid))
        }
        return .wait
    }

    private mutating func finish(_ step: Step) -> Step {
        terminal = step
        return step
    }
}

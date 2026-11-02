/// Inert seam for deterministic tests of the CLI's restart decision.
struct RestartWait {
    enum Step: Equatable {
        case wait
        case done(pid: Int32)
        case fail(String)
    }

    init(oldPID: Int32, deadline: UInt64) {}

    mutating func replied(_ reply: Result<Reply, IPCError>) -> Step { .wait }

    mutating func probed(_ status: Result<Reply, IPCError>, now: UInt64) -> Step { .wait }
}

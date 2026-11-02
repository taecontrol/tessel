#if SWIFT_PACKAGE
import Ports
#endif

struct RestartLaunchError: Error, Equatable {
    let reason: String
}

/// Inert seam for the restart acceptance tests. No lifecycle behavior is wired yet.
@MainActor
final class Restart {
    enum Outcome: Equatable {
        case restarted(pid: Int32)
        case failed(String)
        case refused(String)
    }

    struct Request {
        let deadline: UInt64?
    }

    init(now: @escaping () -> UInt64,
         record: @escaping (Diagnostic) -> Void,
         launch: @escaping (_ done: @escaping (Result<Int32, RestartLaunchError>) -> Void) -> Void,
         quit: @escaping () -> Void) {}

    func request(_ source: RestartSource, deadline: UInt64?, reply: @escaping (Outcome) -> Void) {}

    func quitting() {}
}

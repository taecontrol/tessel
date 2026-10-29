enum IPCError: Error, Equatable {
    case unavailable, timeout, invalidMessage, unsafeEndpoint, alreadyRunning

    var cliMessage: String {
        self == .timeout ? "Tessel is not responding" : "Tessel is not running"
    }
}

struct SocketDeadline {
    enum Connection { case connected, pending, unavailable }
    enum Readiness { case ready, timeout, interrupted, unavailable }

    let nanoseconds: UInt64
    private let now: () -> UInt64

    init(until nanoseconds: UInt64, now: @escaping () -> UInt64) {
        self.nanoseconds = nanoseconds
        self.now = now
    }

    static func request(now: @escaping () -> UInt64) -> SocketDeadline {
        SocketDeadline(until: now() + 750_000_000, now: now)
    }

    func connect(_ connection: Connection, poll: (Int32) -> Readiness) throws {
        switch connection {
        case .connected: return
        case .pending: try wait(poll: poll)
        case .unavailable: throw IPCError.unavailable
        }
    }

    func wait(poll: (Int32) -> Readiness) throws {
        while true {
            let time = now()
            guard time < nanoseconds else { throw IPCError.timeout }
            let milliseconds = Int32(min((nanoseconds - time) / 1_000_000 + 1, UInt64(Int32.max)))
            switch poll(milliseconds) {
            case .ready: return
            case .timeout: throw IPCError.timeout
            case .unavailable: throw IPCError.unavailable
            case .interrupted: continue
            }
        }
    }
}

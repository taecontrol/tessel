/// The restart command carries the caller's absolute monotonic deadline and observed pid.
struct RestartRequest {
    let deadline: UInt64
    let replacing: Int32

    init(deadline: UInt64, replacing: Int32) {
        self.deadline = deadline
        self.replacing = replacing
    }

    init?(command: String) {
        let fields = command.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "restart",
              let deadline = UInt64(fields[1], radix: 36),
              let replacing = Int32(fields[2]), replacing > 0 else { return nil }
        self.deadline = deadline
        self.replacing = replacing
    }

    // Base 36 preserves nanoseconds in at most 13 bytes. With the command,
    // spaces and any positive Int32 pid, the payload fits readLine's 32 bytes.
    var command: String { "restart \(String(deadline, radix: 36)) \(replacing)" }
}

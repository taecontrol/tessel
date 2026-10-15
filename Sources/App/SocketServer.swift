import Darwin
import Foundation

final class SocketServer: @unchecked Sendable {
    private let endpoint = Endpoint()
    private let queue = DispatchQueue(label: "tessel.ipc", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private let respond: @Sendable (String) -> Reply

    init(respond: @escaping @Sendable (String) -> Reply) throws {
        self.respond = respond
        try endpoint.prepareDirectory()
        lockFD = open(endpoint.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw IPCError.unsafeEndpoint }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); lockFD = -1; throw IPCError.alreadyRunning }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.unavailable }
        SocketIO.configure(fd)
        unlink(endpoint.path)
        guard try endpoint.withAddress({ Darwin.bind(fd, $0, $1) }) == 0,
              chmod(endpoint.path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw IPCError.unavailable
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while let self {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                SocketIO.configure(client)
                guard SocketIO.sameUser(client) else { close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        do {
            let data = try SocketIO.readLine(client, limit: 32, until: deadline)
            guard let command = String(data: data, encoding: .utf8) else { return }
            let reply = respond(command)
            try SocketIO.writeLine(JSONEncoder().encode(reply), to: client, until: deadline)
        } catch { /* A stalled or disconnected client cannot block another query. */ }
    }

    func stop() {
        source?.cancel()
        source = nil
        if lockFD >= 0 {
            unlink(endpoint.path)
            close(lockFD)
            lockFD = -1
        }
    }

    deinit { stop() }
}

/// The CLI serves only committed snapshots. It never waits for an AX round trip.
final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [pid_t: [WindowRecord]] = [:]
    private var status: AppStatus

    init(status: AppStatus) { self.status = status }

    func update(status: AppStatus) {
        lock.withLock { self.status = status }
    }

    func update(pid: pid_t, windows: [WindowRecord]?) {
        lock.withLock { self.windows[pid] = windows }
    }

    func reply(to command: String) -> Reply {
        lock.withLock {
            switch command {
            case "status": return Reply(status: status)
            case "windows":
                guard status.permission == "granted" else {
                    return Reply(error: "Accessibility permission needed. Open tessel's menu and System Settings to grant access.")
                }
                return Reply(windows: windows.values.flatMap { $0 }.sorted { $0.id < $1.id })
            default: return Reply(error: "Unknown read-only command. Use windows or status.")
            }
        }
    }
}

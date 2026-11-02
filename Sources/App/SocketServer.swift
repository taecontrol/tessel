import Darwin
import Foundation

final class SocketServer: @unchecked Sendable {
    private let endpoint = Endpoint()
    private let queue = DispatchQueue(label: "tessel.ipc", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private let respond: @Sendable (String) -> Reply
    private let restart: @MainActor @Sendable (Int32, UInt64, @escaping @Sendable (Reply) -> Void) -> Void

    init(respond: @escaping @Sendable (String) -> Reply,
         restart: @escaping @MainActor @Sendable (Int32, UInt64, @escaping @Sendable (Reply) -> Void) -> Void) throws {
        self.respond = respond
        self.restart = restart
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
            let reply: Reply
            if command.hasPrefix("restart ") {
                guard let request = RestartRequest(command: command) else { return }
                let requestedDeadline = min(request.deadline,
                                            DispatchTime.now().uptimeNanoseconds + RestartWait.timeoutNanoseconds)
                // Do not let a queued command turn a startup refusal into a restart.
                if let error = respond("status").error { reply = Reply(error: error) }
                else {
                    let pending = PendingReply()
                    DispatchQueue.main.async { self.restart(request.replacing, requestedDeadline, pending.complete) }
                    reply = pending.wait(until: requestedDeadline)
                }
            } else { reply = respond(command) }
            // LaunchServices may take longer than the read-only budget. Give the
            // accepted reply its own bounded write after the coordinator replies.
            let writeDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            try SocketIO.writeLine(JSONEncoder().encode(reply), to: client, until: writeDeadline)
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

/// Only the socket worker waits; the main thread publishes once and keeps quitting.
private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reply: Reply?

    func complete(_ value: Reply) {
        lock.withLock { reply = value }
        semaphore.signal()
    }

    func wait(until deadline: UInt64) -> Reply {
        guard semaphore.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success else {
            return Reply(error: RestartWait.timedOut)
        }
        return lock.withLock { reply! }
    }
}

/// The CLI serves only committed snapshots. It never waits for an AX round trip.
final class SnapshotStore: WindowPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [pid_t: [WindowRecord]] = [:]
    private var status: AppStatus
    private var loginItem: OpenAtLogin
    private let readLoginItem: (@Sendable () -> LoginItemState)?
    private var ready = false

    init(status: AppStatus, openAtLogin: OpenAtLogin, readLoginItem: (@Sendable () -> LoginItemState)? = nil) {
        self.status = status
        self.loginItem = openAtLogin
        self.readLoginItem = readLoginItem
        self.status.openAtLogin = openAtLogin.status
    }

    var openAtLogin: OpenAtLogin { lock.withLock { loginItem } }

    /// Serializes login-item reads and changes, so a read that started before a
    /// click never replaces the click's result. BTM can take time; it is never
    /// called under `lock`, which window snapshots share.
    private let loginItemLock = NSLock()

    func refreshOpenAtLogin() {
        guard let readLoginItem else { return }
        loginItemLock.withLock {
            guard case .installed = openAtLogin else { return }
            let state = readLoginItem()
            publish(openAtLogin.reading(state))
        }
    }

    /// Performs the click's request, then reports the state BTM gives afterwards.
    func changeOpenAtLogin(_ perform: (LoginItemRequest) -> String?) {
        guard let readLoginItem else { return }
        loginItemLock.withLock {
            let current = openAtLogin
            guard let request = current.clickRequest else { return }
            let refused = perform(request)
            publish(current.performed(refused: refused, now: readLoginItem()))
        }
    }

    private func publish(_ value: OpenAtLogin) {
        lock.withLock {
            loginItem = value
            status.openAtLogin = value.status
        }
    }

    func markReady() { lock.withLock { ready = true } }

    func update(status: AppStatus) {
        lock.withLock {
            #if TESSEL_DEVELOPMENT
            let motion = self.status.testMotion
            let map = self.status.testMap
            #endif
            self.status = status
            self.status.openAtLogin = loginItem.status
            #if TESSEL_DEVELOPMENT
            self.status.testMotion = motion
            self.status.testMap = map
            #endif
        }
    }

    #if TESSEL_DEVELOPMENT
    func recordMap(_ map: AppStatus.TestMap) {
        lock.withLock { status.testMap = map }
    }

    func recordStage(_ event: StageEvent) {
        lock.withLock {
            switch event {
            case .begin:
                status.testMotion?.stageMove += 1
                status.testMotion?.stageScreenshots = [:]
            case .screenshot(let id): status.testMotion?.stageScreenshots[String(id), default: 0] += 1
            case .pending(let count): status.testMotion?.stageCapturesPending = count
            case .capture: status.testMotion?.stageCaptures += 1
            case .show: status.testMotion?.stageShows += 1
            case .settled: status.testMotion?.stageSettles += 1
            case .clear: status.testMotion?.stageClears += 1
            }
        }
    }
    func enableMotionInstrumentation() {
        lock.withLock { status.testMotion = AppStatus.TestMotion() }
    }
    #endif

    func update(pid: pid_t, windows: [WindowRecord]?) {
        lock.withLock { self.windows[pid] = windows }
    }

    func reply(to command: String) -> Reply {
        if command == "status" { refreshOpenAtLogin() }
        return lock.withLock {
            guard ready else { return Reply(error: "Tessel is starting") }
            // The state below is read under this lock at this instant.
            let answeredAt = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
            switch command {
            case "status":
                var status = status
                status.answeredAt = answeredAt
                return Reply(status: status)
            case "windows":
                guard status.permission == "granted" else {
                    return Reply(error: "Accessibility permission needed. Open Tessel's menu and System Settings to grant access.")
                }
                return Reply(windows: windows.values.flatMap { $0 }.sorted { $0.id < $1.id }.map {
                    var record = $0
                    record.answeredAt = answeredAt
                    return record
                })
            default: return Reply(error: "Unknown read-only command. Use windows or status.")
            }
        }
    }
}

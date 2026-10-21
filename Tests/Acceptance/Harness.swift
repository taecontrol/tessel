import Darwin
import Foundation
import Testing

/// Real-system suites share one desktop and run serially.
@Suite(.serialized)
enum Acceptance {}

/// One window record from `tessel windows --json`.
struct Row: Decodable, Equatable, Hashable {
    let id: UInt32
    let app: String
    let bundleId: String
    let state: String
    let reason: String
    let tabs: Int
    let workspace: Int?
    let visible: Bool?
    let rail: Int?
    let slot: Int?
}

struct Status: Decodable {
    struct Config: Decodable {
        let path: String
        let state: String
        let revision: UInt64
        let effective: Effective
        let error: ConfigError?
    }
    struct Effective: Decodable, Equatable {
        struct Animation: Decodable, Equatable { let duration: Int }
        let experiments: [String: Bool]
        let animation: Animation
    }
    struct ConfigError: Decodable {
        let line: Int
        let message: String
    }
    let permission: String
    let config: Config
    let version: String
    let pid: pid_t
    let workspaces: Workspaces?
    struct Workspaces: Decodable {
        let enabled: Bool
        let reason: String
        let active: Int
        let layout: String?
        let animationDuration: Int
        let motion: String?
        let rail: Int?
        let gaps: Gaps
        let keys: [String: String]
        struct Layer: Decodable { let state: String; let focused: Bool }
        let layer: Layer?
        struct Gaps: Decodable { let outer: Double }
    }
}

/// The fixture's own description of its windows, keyed by the test's names.
struct FixtureReply: Decodable {
    struct MinimizeEvent: Decodable {
        let name: String
        let minimized: Bool
        let key: Bool
        let main: Bool
        let active: Bool
        let sampledAt: Double
    }
    let pid: pid_t
    let windows: [String: UInt32]
    let nativeTabs: [String: Int]
    let closable: [String: Bool]
    let contentPages: [String: Int]
    let observation: Observation?
    let postedAt: Double?
    let keyCount: Int?
    let menuContains: Bool?
    let ready: Bool?
    let active: Bool?
    let contract: NativeContractReply?
    let frames: [String: [Double]]?
    let axWindowOrder: [UInt32]?
    let transitionCount: Int?
    let keyWindow: UInt32?
    let mainWindow: UInt32?
    let minimizeEvents: [String: [MinimizeEvent]]?
    let miniaturized: [String: Bool]?
}

struct Observation: Decodable {
    struct Window: Decodable {
        let id: UInt32
        let frame: [Double]
        let visible: Bool
        let main: Bool
        let focused: Bool
        let order: Int
        let nativeFullscreen: Bool
        let parent: UInt32?
    }
    let windows: [Window]
    let visibleIDs: [UInt32]
    let frontmostFixture: Bool
    let frontmostFixturePID: Int32
    let activeFixturePID: Int32
    let finderDesktop: Bool
    /// The observer's monotonic time when it finished taking this observation.
    let sampledAt: Double?
    let finderHasNoOrdinaryWindows: Bool?
    let area: [Double]
}

/// What an independent AX client sees in the fixture. It never reads titles.
struct ProbeWindow: Decodable {
    let id: UInt32
    let subrole: String
    let sizeSettable: Bool
    let fullscreen: String
    let tabs: Int
    let extraTabButtons: Int
    let perTabButtons: Int
    let resizeError: Int?
    let acceptedSize: [Double]?
    let sheets: [ProbeWindow]
}

/// A real AppKit fixture process, driven through a test-only datagram socket.
@MainActor
final class FixtureSession {
    private(set) var pid: pid_t = 0
    private(set) var windowIDs = Set<UInt32>()
    private let path: String
    private let clientPath: String
    private let socket: Int32

    private struct Unreachable: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "cannot reach the fixture: errno \(code)" }
    }

    init(directory: URL, number: Int, swiftUI: Bool = false, prohibited: Bool = false) throws {
        path = directory.appending(path: "f\(number).sock").path
        clientPath = directory.appending(path: "c\(number).sock").path
        socket = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        var replyCapacity: Int32 = 65_536
        guard setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &replyCapacity, socklen_t(MemoryLayout.size(ofValue: replyCapacity))) == 0 else {
            close(socket)
            throw HarnessError("cannot reserve the fixture reply buffer")
        }
        unlink(path)
        unlink(clientPath)
        var address = try unixAddress(clientPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw HarnessError("cannot bind the fixture client socket: errno \(errno)") }
        setTimeout(socket, seconds: margin)
        try run(["open", "-n"] + (swiftUI ? [] : ["-g"]) + ["--stdout", "/dev/null", "--stderr", "/dev/null", fixtureBundle.path, "--args", "--socket", path]
                + (swiftUI ? ["--swiftui"] : []) + (prohibited ? ["--prohibited"] : []), timeout: margin, check: true)
        // The path can appear before bind attaches its socket. Keep one ping
        // in flight so a late startup reply cannot answer a later command.
        var sent = false
        guard let reply = try finalValue({ () throws -> FixtureReply? in
            if !sent {
                do { try send("ping", [:], flags: MSG_DONTWAIT) }
                catch let error as Unreachable where error.code == ENOENT || error.code == ECONNREFUSED { return nil }
                sent = true
            }
            return try receive("ping", flags: MSG_DONTWAIT)
        }) else { throw HarnessError("fixture did not launch and answer ping within the final-state margin") }
        pid = reply.pid
    }

    @discardableResult
    func command(_ action: String, _ arguments: [String: Any] = [:]) throws -> FixtureReply {
        let deadline = monotonicSeconds() + margin
        while true {
            do {
                return try request(action, arguments)
            } catch let error as HarnessError where action == "hotkey"
                && error.description.hasPrefix("refusing synthetic hotkey:") && monotonicSeconds() < deadline {
                // These replies precede event posting. Never retry a transport
                // error or a posted event, and keep timing from actual posting.
                usleep(15_000)
            }
        }
    }

    private func request(_ action: String, _ arguments: [String: Any]) throws -> FixtureReply {
        try send(action, arguments)
        guard let reply = try receive(action) else { throw HarnessError("fixture did not answer \(action)") }
        return reply
    }

    private func send(_ action: String, _ arguments: [String: Any], flags: Int32 = 0) throws {
        var request = arguments
        request["action"] = action
        request["transitionMargin"] = margin
        let data = try JSONSerialization.data(withJSONObject: request)
        var address = try unixAddress(path)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, bytes.baseAddress, data.count, flags, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard sent == data.count else { throw Unreachable(code: errno) }
    }

    private func receive(_ action: String, flags: Int32 = 0) throws -> FixtureReply? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let received = recv(socket, &buffer, buffer.count, flags)
        if received < 0, flags & MSG_DONTWAIT != 0, errno == EWOULDBLOCK { return nil }
        guard received > 0 else {
            throw HarnessError("fixture did not answer \(action)")
        }
        let reply = Data(buffer.prefix(received))
        if let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any], let error = object["error"] as? String {
            throw HarnessError(error)
        }
        let decoded = try JSONDecoder().decode(FixtureReply.self, from: reply)
        SampleClock.record(decoded.observation?.sampledAt ?? monotonicSeconds())
        windowIDs = Set(decoded.windows.values)
        return decoded
    }

    func open(kind: String = "standard", key: String = "window", _ options: [String: Any] = [:]) throws -> UInt32 {
        let reply = try command("open", options.merging(["kind": kind, "key": key]) { $1 })
        guard let window = reply.windows[key] else { throw HarnessError("fixture did not open \(key)") }
        return window
    }

    func stop() {
        kill(pid, SIGKILL)
        _ = finalState { kill(pid, 0) != 0 }
        disconnect()
    }

    func disconnect() {
        close(socket)
        unlink(clientPath)
        unlink(path)
    }
}

/// The signed development app and one fixture, shared by a suite.
/// Only fixture records reach assertions. Never print or persist a full window listing.
@MainActor
final class Harness {
    static var shared: Harness!

    private(set) var directory: URL!
    private(set) var configFile: URL!
    private(set) var environment: [String: String] = [:]
    var fixture: FixtureSession!
    var otherFixtures: [FixtureSession] = []

    func other(prohibited: Bool = false) throws -> FixtureSession {
        let session = try FixtureSession(directory: directory, number: otherFixtures.count + 1, prohibited: prohibited)
        otherFixtures.append(session)
        return session
    }
    var observer: FixtureSession!
    private(set) var appPID: pid_t = 0
    /// What NSWorkspace reported in a fresh signed process when the suite began.
    private(set) var desktopReduceMotion = false
    /// The Reduce Motion value tessel was launched with; see `startApp`.
    private(set) var appReduceMotion = false
    private var cleanups: [() -> Void] = []
    private var contracts: URL?

    func start(launchApp: Bool = true) throws {
        let required = [cli, fixtureExecutable, buildTool]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw HarnessError("Run scripts/build first; the build tool and the signed app and fixture bundles are required")
        }
        guard processIDs(appExecutable).isEmpty else {
            throw HarnessError("This worktree's development app is already running; stop it before verification")
        }
        guard try run([fixtureExecutable.path, "--check-session"], timeout: margin).status == 0 else {
            throw HarnessError("Wake and unlock the Mac before running GUI verification")
        }
        let power = Process()
        power.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        power.arguments = ["-d", "-i", "-w", String(getpid())]
        power.standardOutput = FileHandle.nullDevice
        power.standardError = FileHandle.nullDevice
        try power.run()
        cleanups.append { if power.isRunning { power.terminate() } }

        let directory = FileManager.default.temporaryDirectory.appending(path: "tessel-verify-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        cleanups.append { try? FileManager.default.removeItem(at: directory) }
        self.directory = directory
        let configHome = directory.appending(path: "config")
        configFile = configHome.appending(path: "tessel/tessel.toml")
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        environment = ProcessInfo.processInfo.environment.merging(["XDG_CONFIG_HOME": configHome.path]) { $1 }
        fixture = try FixtureSession(directory: directory, number: 0)
        observer = try FixtureSession(directory: directory, number: 999)
        cleanups.append { [unowned self] in observer.stop() }
        cleanups.append { [unowned self] in fixture.stop() }
        cleanups.append { [unowned self] in stopApp() }
        cleanups.append { [unowned self] in otherFixtures.forEach { $0.stop() } }
        guard let desktop = try observer.command("contract", ["operation": "motionPreferences", "pid": observer.pid]).contract?.reduceMotion else {
            throw HarnessError("the signed observer did not report the desktop's Reduce Motion setting")
        }
        desktopReduceMotion = desktop
        if launchApp {
            try startApp()
            print("Motion: \(try motionGiven())")
            fflush(nil)
        }
    }

    func shutdown() {
        while let cleanup = cleanups.popLast() { cleanup() }
    }

    /// The harness owns the Reduce Motion Given instead of inheriting the
    /// desktop's setting: GitHub's macOS images turn it on, which makes every
    /// carousel move instant. macOS protects the persistent preference, and the
    /// private setter the contracts use changes only its own process, so the
    /// value reaches tessel through its argument domain, which NSWorkspace reads
    /// before the user's. Nothing outside this launch changes, so neither
    /// cleanup nor an interrupted run has anything to restore.
    func startApp(fixtureReady: Bool = true, arguments: [String] = [], reduceMotion: Bool = false) throws {
        let capture = ProcessInfo.processInfo.environment["TESSEL_CAPTURE_WORKSPACES"] == "1" ? ["--test-capture-ui"] : []
        try run(["open", "-n", "-g", "--stdout", "/dev/null", "--stderr", "/dev/null",
                 "--env", "XDG_CONFIG_HOME=" + environment["XDG_CONFIG_HOME"]!, app.path,
                 "--args", "--test-fixture-only", "-reduceMotion", reduceMotion ? "YES" : "NO"] + capture + arguments,
            timeout: margin, check: true)
        guard let pid = finalValue({ processIDs(appExecutable).first }) else {
            throw HarnessError("signed development app did not launch")
        }
        appPID = pid
        appReduceMotion = reduceMotion
        guard try finalState({ try invoke("status", "--json").status == 0 }) else {
            throw HarnessError("signed development app did not expose its status endpoint")
        }
        // Motion is off for Reduce Motion exactly when tessel reads it; it can
        // also be off for a missing Screen Recording grant.
        guard try finalState({
            let status = try status()
            return (status.workspaces?.motion == "off: Reduce Motion") == reduceMotion
                || status.config.effective.animation.duration == 0
        }) else { throw HarnessError("tessel did not take the harness's Reduce Motion: \(try motionGiven())") }
        guard fixtureReady else { return }
        // Socket readiness does not prove that startup AX subscriptions exist.
        // Exercise one generic window before driving the app.
        let health = try fixture.open(key: "startupHealth")
        func listed() throws -> Bool? {
            let result = try invoke("windows", "--json")
            guard result.status == 0 else { return nil }
            return try JSONDecoder().decode([Row].self, from: result.outputData)
                .contains { $0.bundleId == fixtureID && $0.id == health }
        }
        guard try finalState({ try listed() == true }) else {
            throw HarnessError("signed development app did not observe the fixture startup window")
        }
        try fixture.command("close", ["key": "startupHealth"])
        guard try finalState({ try listed() == false }) else {
            throw HarnessError("signed development app did not retire the fixture startup window")
        }
    }

    func stopApp() {
        for pid in processIDs(appExecutable) { kill(pid, SIGTERM) }
        _ = finalState { processIDs(appExecutable).isEmpty }
    }

    var appIsRunning: Bool { !processIDs(appExecutable).isEmpty }

    func invoke(_ arguments: String...) throws -> ProcessResult {
        try invoke(arguments)
    }

    func invoke(_ arguments: [String]) throws -> ProcessResult {
        let result = try run([cli.path] + arguments, environment: environment, timeout: margin, recordsReceipt: false)
        // Judge a JSON answer by when tessel produced it; anything else by receipt.
        let json = try? JSONSerialization.jsonObject(with: result.outputData)
        let answer = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        SampleClock.record((answer?["answeredAt"] as? NSNumber)?.doubleValue ?? monotonicSeconds())
        return result
    }

    /// The app's only Unix socket: the CLI endpoint.
    func endpoint() throws -> String {
        let result = try run(["/usr/sbin/lsof", "-a", "-p", String(appPID), "-U", "-Fn"], timeout: margin, check: true)
        let paths = result.output.split(separator: "\n").filter { $0.hasPrefix("n/") && $0.hasSuffix(".sock") }
        guard paths.count == 1 else { throw HarnessError("expected one tessel endpoint, found \(paths.count)") }
        return String(paths[0].dropFirst())
    }

    /// Fixture-only status instrumentation: the app's real stage adapter
    /// counts its window captures and shown motions.
    func stageWork() throws -> UInt64 {
        let reply = try invoke("status", "--json")
        let object = try JSONSerialization.jsonObject(with: reply.outputData) as? [String: Any]
        guard let motion = object?["testMotion"] as? [String: Any], let captures = (motion["stageCaptures"] as? NSNumber)?.uint64Value,
              let shows = (motion["stageShows"] as? NSNumber)?.uint64Value else {
            throw HarnessError("fixture-only status must expose testMotion stage instrumentation")
        }
        return captures + shows
    }

    /// States the motion Given, so a failed motion example explains itself.
    func motionGiven() throws -> String {
        let status = try status()
        return "effective animation duration \(status.workspaces.map { "\($0.animationDuration) ms, motion \($0.motion ?? "unknown")" } ?? "unknown")"
            + " (configured \(status.config.effective.animation.duration) ms); Reduce Motion: tessel \(appReduceMotion ? "on" : "off")"
            + " (set by the harness), desktop \(desktopReduceMotion ? "on" : "off")"
    }

    func status() throws -> Status {
        let result = try invoke("status", "--json")
        guard result.status == 0 else { throw HarnessError("status command failed (window data withheld)") }
        return try JSONDecoder().decode(Status.self, from: result.outputData)
    }

    func rows() throws -> [Row] {
        let result = try invoke("windows", "--json")
        guard result.status == 0 else { throw HarnessError("windows command failed; check Accessibility using tessel status") }
        // Decoding errors never include other apps' records in failure output.
        guard let rows = try? JSONDecoder().decode([Row].self, from: result.outputData) else {
            throw HarnessError("window listing is malformed (content withheld)")
        }
        return rows.filter { $0.bundleId == fixtureID }
    }

    func row(_ id: UInt32) throws -> Row? {
        try rows().first { $0.id == id }
    }

    /// Reads the fixture through a separate AX client, as an oracle independent of tessel.
    func probe(resizing resizeID: UInt32? = nil, session: FixtureSession? = nil) throws -> [ProbeWindow] {
        // LaunchServices must own the probe's TCC identity. A bare binary inherits
        // the terminal host's permission, which need not match the fixture grant.
        let output = directory.appending(path: "probe-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        var command = ["open", "-n", "-g", "--stdout", output.path, "--stderr", "/dev/null", fixtureBundle.path,
                       "--args", "--probe", String((session ?? fixture).pid)]
        if let resizeID { command.append(String(resizeID)) }
        try run(command, timeout: margin, check: true)
        struct Reply: Decodable { let windows: [ProbeWindow]? }
        let reply = try finalValue { () throws -> Reply? in
            guard let data = FileManager.default.contents(atPath: output.path), !data.isEmpty else { return nil }
            return try? JSONDecoder().decode(Reply.self, from: data)
        }
        guard let reply else { throw HarnessError("independent fixture AX probe did not complete") }
        guard let windows = reply.windows else { throw HarnessError("independent fixture AX probe needs Accessibility") }
        return windows
    }

    /// Builds the native contract probe once. It has no tessel bundle ID and never queries AX.
    func contractsExecutable() throws -> URL {
        if let contracts { return contracts }
        let executable = directory.appending(path: "NativeContracts")
        let shared = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Sources/Shared"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        let sources = shared + [root.appending(path: "Sources/Policy/ElementSubscriptions.swift"), root.appending(path: "Sources/App/AXSubscriptions.swift"), root.appending(path: "Tests/Contracts/Main.swift")]
        let compiled = try run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O", "-target", "arm64-apple-macos27.0"]
                               + sources.map(\.path) + ["-o", executable.path], timeout: 120)
        guard compiled.status == 0 else { throw HarnessError("native contracts did not compile:\n" + compiled.error) }
        contracts = executable
        return executable
    }

    /// Per-test setup: a fresh fixture and the default configuration.
    func reset() throws {
        if !appIsRunning { try startApp(fixtureReady: false) }
        try? FileManager.default.removeItem(at: configFile)
        guard try finalState({ try status().config.state == "defaults" }) else {
            throw HarnessError("tessel did not return to the default configuration")
        }
        for other in otherFixtures { other.stop() }
        otherFixtures.removeAll()
        try fixture.command("reset")
    }
}

/// Starts the harness once around a suite and always cleans up its processes and data.
struct AppSession: SuiteTrait, TestScoping {
    var launchesApp = true

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let harness = await MainActor.run {
            let harness = Harness()
            Harness.shared = harness
            return harness
        }
        do {
            try await MainActor.run { try harness.start(launchApp: launchesApp) }
            try await function()
        } catch {
            await MainActor.run { harness.shutdown() }
            throw error
        }
        await MainActor.run { harness.shutdown() }
    }
}

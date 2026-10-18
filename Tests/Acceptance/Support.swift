import Darwin
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let apps = root.appending(path: ".build/apps")
let app = apps.appending(path: "Tessel Dev.app")
let appExecutable = app.appending(path: "Contents/MacOS/TesselApp")
let cli = app.appending(path: "Contents/MacOS/tessel")
let fixtureBundle = apps.appending(path: "Tessel Fixture.app")
let fixtureExecutable = fixtureBundle.appending(path: "Contents/MacOS/TesselFixture")
let fixtureID = "com.taecontrol.tessel.fixture"
// scripts/build builds this tool. Tests run it directly: calling SwiftPM from
// within `swift test` would wait on the lock of the running test build.
let buildTool = root.appending(path: ".build/tools/debug/tessel-build")
let onDisposableRunner = ProcessInfo.processInfo.environment["CI"] == "true"
    && ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ProcessTimeout: Error, CustomStringConvertible {
    let description: String
}

func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
}

// The generous final-state margin for real-system journeys and contracts.
let margin = 5.0

func finalValue<T>(_ predicate: () throws -> T?) rethrows -> T? {
    try eventualValue(within: margin, predicate)
}

func finalState(_ predicate: () throws -> Bool) rethrows -> Bool {
    try finalValue { try predicate() ? true : nil } != nil
}

func requireFinalState(_ expectation: String, _ predicate: () throws -> Bool) throws {
    guard try finalState(predicate) else {
        throw HarnessError("\(expectation) did not arrive within the final-state margin")
    }
}

/// When the inputs of one predicate evaluation were produced (issue #21).
/// An observation counts at the time the independent observer finished taking
/// it, and a CLI answer at its `answeredAt`, when tessel produced it. A fixture
/// reply, a CLI answer without that field, or another subprocess counts when it
/// was received. The xcode-27 runner can deschedule this test process for hundreds
/// of milliseconds after a sample was taken; that delay is not tessel's latency.
enum SampleClock {
    nonisolated(unsafe) private static var evaluations: [Double?] = []
    /// The time the most recent successful wait was judged by.
    nonisolated(unsafe) private(set) static var lastJudged: Double = 0

    static func record(_ time: Double) {
        guard let current = evaluations.indices.last else { return }
        evaluations[current] = max(evaluations[current] ?? time, time)
    }
    fileprivate static func begin() { evaluations.append(nil) }
    /// A nested wait's inputs are also inputs of the evaluation that called it.
    fileprivate static func end() -> Double? {
        let time = evaluations.removeLast()
        if let time { record(time) }
        return time
    }
    fileprivate static func judged(_ time: Double) { lastJudged = time }
}

/// Polls until the predicate holds. A result counts only if its inputs were
/// produced by the deadline (see `SampleClock`); a predicate without recorded
/// inputs is judged when it returns.
func eventualValue<T>(within timeout: Double = 0.5, _ predicate: () throws -> T?) rethrows -> T? {
    let deadline = monotonicSeconds() + timeout
    while true {
        SampleClock.begin()
        var ended = false
        defer { if !ended { _ = SampleClock.end() } }
        let value = try predicate()
        let sampled = SampleClock.end()
        ended = true
        if let result = value {
            let judged = sampled ?? monotonicSeconds()
            guard judged <= deadline else { return nil }
            SampleClock.judged(judged)
            return result
        }
        if monotonicSeconds() >= deadline { return nil }
        usleep(15_000)
    }
}

func eventually(within timeout: Double = 0.5, _ predicate: () throws -> Bool) rethrows -> Bool {
    try eventualValue(within: timeout) { try predicate() ? true : nil } != nil
}

func sleep(seconds: Double) {
    usleep(useconds_t(seconds * 1_000_000))
}

struct ProcessResult {
    let status: Int32
    let outputData: Data
    let errorData: Data
    var output: String { String(decoding: outputData, as: UTF8.self) }
    var error: String { String(decoding: errorData, as: UTF8.self) }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Data] = [:]
    subscript(index: Int) -> Data {
        get { lock.withLock { values[index] ?? Data() } }
        set { lock.withLock { values[index] = newValue } }
    }
}

/// Runs a command, killing it at the timeout. A bare command name is found on PATH.
@discardableResult
func run(_ command: [String], environment: [String: String]? = nil, timeout: Double = 10, check: Bool = false,
         recordsReceipt: Bool = true) throws -> ProcessResult {
    let process = Process()
    if command[0].hasPrefix("/") {
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
    }
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    let pipes = [Pipe(), Pipe()]
    process.standardOutput = pipes[0]
    process.standardError = pipes[1]
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    let collected = Collected()
    let reading = DispatchGroup()
    for (index, pipe) in pipes.enumerated() {
        DispatchQueue.global().async(group: reading) { collected[index] = pipe.fileHandleForReading.readDataToEndOfFile() }
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
        _ = reading.wait(timeout: .now() + 1)
        throw ProcessTimeout(description: "\(URL(fileURLWithPath: command[0]).lastPathComponent) timed out after \(timeout) seconds")
    }
    _ = reading.wait(timeout: .now() + 1)
    if recordsReceipt { SampleClock.record(monotonicSeconds()) }
    let result = ProcessResult(status: process.terminationStatus, outputData: collected[0], errorData: collected[1])
    if check, result.status != 0 {
        throw HarnessError("\(URL(fileURLWithPath: command[0]).lastPathComponent) exited with status \(result.status)")
    }
    return result
}

func processIDs(_ executable: URL) -> [pid_t] {
    let pattern = "^" + executable.path.replacing(/[.^$|?*+()\[\]{}\\]/) { "\\" + $0.output } + "( |$)"
    let result = try? run(["pgrep", "-f", pattern])
    return result?.output.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) } ?? []
}

func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HarnessError("socket path is too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
    return address
}

func setTimeout(_ socket: Int32, seconds: Double) {
    var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
}

/// A stream client of tessel's CLI endpoint, used to send what the CLI never sends.
final class StreamClient {
    private let socket: Int32

    init(path: String, timeout: Double) throws {
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        setTimeout(socket, seconds: timeout)
        var address = try unixAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(socket)
            throw HarnessError("cannot connect to the tessel endpoint: errno \(errno)")
        }
    }

    deinit { close(socket) }

    func send(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let sent = data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, data.count, 0) }
        guard sent == data.count else { throw HarnessError("send failed: errno \(errno)") }
    }

    func receive(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let received = recv(socket, &buffer, count, 0)
        guard received >= 0 else { throw HarnessError("receive timed out or failed: errno \(errno)") }
        return Data(buffer.prefix(received))
    }

    func readLine(limit: Int) throws -> Data {
        var line = Data()
        while line.count < limit, line.last != UInt8(ascii: "\n") {
            let next = try receive(1)
            if next.isEmpty { break }
            line.append(next)
        }
        return line
    }
}

let timebase: mach_timebase_info_data_t = {
    var value = mach_timebase_info_data_t()
    guard mach_timebase_info(&value) == KERN_SUCCESS, value.denom != 0 else { fatalError("cannot determine the Mach CPU timebase") }
    return value
}()

/// Cumulative CPU time and interrupt wakeups, plus current physical footprint.
func resources(_ pid: pid_t) throws -> (cpuNanoseconds: UInt64, interruptWakeups: UInt64, footprintBytes: UInt64) {
    var usage = rusage_info_v0()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
    }
    guard result == 0 else { throw HarnessError("cannot read resource usage of \(pid): errno \(errno)") }
    let ticks = usage.ri_user_time + usage.ri_system_time
    return (ticks * UInt64(timebase.numer) / UInt64(timebase.denom), usage.ri_interrupt_wkups, usage.ri_phys_footprint)
}

func writeInfoPlist(_ info: [String: Any], to url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
}

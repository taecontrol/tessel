import AppKit
import ApplicationServices
import Darwin

/// #40: what WindowServer lists and composites around a placement's AX
/// readback. The writes follow the catalog's rail placement. A sampler
/// thread traces fixture window bounds and screen points from before the
/// first write until a fixed limit after the commit, the instant the presenter
/// would show or hide a window in the turn that receives the readback.
extension FixtureContracts {
    /// One window placed, optionally from the closet or by its app stopping
    /// right after it answers.
    func placementGap(_ command: [String: Any], application: AXUIElement, pid: pid_t) throws -> [String: Any] {
        let window = try retained(command, pid: pid)
        let number = id(window)
        guard let target = command["frame"] as? [Double], target.count == 4 else { throw FixtureContractError("a placement needs a native frame") }
        let stop = command["stop"] as? Bool == true
        // A returning window is placed in the closet, then shown once its
        // readback lands, as the presenter does before retiring a departure.
        let fromCloset = command["fromCloset"] as? Bool == true
        if fromCloset, spaces == nil || !moved.contains(number) { throw FixtureContractError("hide the window in the closet first") }
        let sampler = try PlacementSampler(windows: [number], command: command)
        sampler.start()
        let placed = place(window, application: application, target: target, command: command)
        // Whether WindowServer takes a closeted window's accepted frame while
        // it is still in the closet: hold the show a while.
        if fromCloset, let delay = command["showDelayMilliseconds"] as? Double { sampler.wait(until: PlacementSampler.now() + delay / 1_000) }
        if fromCloset, let spaces { spaces.move([number], to: spaces.active); moved.remove(number) }
        let commit = PlacementSampler.now()
        // A stopped app is the worst case of a busy one: it answered the
        // readback, then runs nothing more until it is resumed.
        if stop { kill(pid, SIGSTOP) }
        sampler.wait(until: commit + sampler.limit)
        var resumed: Double?
        if stop {
            kill(pid, SIGCONT)
            let at = PlacementSampler.now()
            resumed = at
            sampler.wait(until: at + 0.2)
        }
        let trace = sampler.finish()
        return ["placementGap": placed.facts.merging(trace.facts(commit: commit, expected: [number: placed.accepted], resumed: resumed)) { $1 }]
    }

    /// The catalog's placement: enhanced UI off, its resize order or one
    /// `AXFrame` write, the readback, then the flag restored.
    private func place(_ window: AXUIElement, application: AXUIElement, target: [Double], command: [String: Any]) -> (accepted: CGRect, facts: [String: Any]) {
        let resize = command["resize"] as? Bool == true
        let frameWrite = command["frameAttribute"] as? Bool == true
        // A resize can make AppKit relayout before it answers. tessel's own
        // placements wait on the app's queue; a short read limit would turn a
        // slow answer into a missing readback.
        AXUIElementSetMessagingTimeout(application, 1)
        AXUIElementSetMessagingTimeout(window, 1)
        defer {
            AXUIElementSetMessagingTimeout(application, FixtureProbe.observationTimeout)
            AXUIElementSetMessagingTimeout(window, FixtureProbe.observationTimeout)
        }
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(window, "AXFrame" as CFString, &settable)
        let enhanced = "AXEnhancedUserInterface" as CFString
        let restore = (read(application, enhanced as String).value as? Bool) == true
        if restore { _ = AXUIElementSetAttributeValue(application, enhanced, kCFBooleanFalse) }
        var point = CGPoint(x: target[0], y: target[1]), size = CGSize(width: target[2], height: target[3])
        var rectangle = CGRect(origin: point, size: size)
        let position = AXValueCreate(.cgPoint, &point)!, dimensions = AXValueCreate(.cgSize, &size)!, whole = AXValueCreate(.cgRect, &rectangle)!
        var results: [Int32] = [], writes: [String] = [], spans: [[Double]] = []
        let started = PlacementSampler.now()
        // The catalog's order: position first only when the size fits at the
        // target but not at the current origin, or when a taller window rises.
        let current = Self.frame(read(window, kAXPositionAttribute).value, read(window, kAXSizeAttribute).value)
        let screenRight = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        let fitsCurrent = current.minX + target[2] <= screenRight && current.minX + target[2] >= 1
        let fitsTarget = target[0] + target[2] <= screenRight && target[0] + target[2] >= 1
        let positionFirst = resize && (fitsCurrent ? fitsTarget && target[3] > current.height && target[1] < current.minY : fitsTarget)
        func write(_ name: String, _ attribute: String, _ value: AXValue) {
            let begin = PlacementSampler.now()
            results.append(AXUIElementSetAttributeValue(window, attribute as CFString, value).rawValue)
            spans.append([begin, PlacementSampler.now()]); writes.append(name)
        }
        if frameWrite { write("frame", "AXFrame", whole) }
        else {
            if positionFirst { write("position", kAXPositionAttribute, position) }
            if resize { write("size", kAXSizeAttribute, dimensions) }
            if !positionFirst { write("position", kAXPositionAttribute, position) }
        }
        let accepted = Self.frame(read(window, kAXPositionAttribute).value, read(window, kAXSizeAttribute).value)
        let answered = PlacementSampler.now()
        // The catalog restores the flag before its completion reaches main.
        if restore { _ = AXUIElementSetAttributeValue(application, enhanced, kCFBooleanTrue) }
        return (accepted, ["results": results, "writes": writes, "writeSpans": spans, "positionFirst": positionFirst,
                           "frameSettable": settableError == .success && settable.boolValue, "frameSettableError": settableError.rawValue,
                           "before": Self.rect(current), "accepted": Self.rect(accepted), "enhancedUI": restore,
                           "startedAt": started, "answeredAt": answered, "writeMilliseconds": (answered - started) * 1_000,
                           "restoreMilliseconds": (PlacementSampler.now() - answered) * 1_000])
    }

    private static func frame(_ position: CFTypeRef?, _ size: CFTypeRef?) -> CGRect {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return .null }
        var point = CGPoint.zero, dimensions = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point); AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        return CGRect(origin: point, size: dimensions)
    }

    private static func rect(_ value: CGRect) -> [Double] { value.isNull ? [] : [value.minX, value.minY, value.width, value.height] }
}

/// Samples, on its own thread, what WindowServer lists for fixture windows and
/// the palette index it composites at screen points. Only palette indices and
/// fixture geometry leave this process.
final class PlacementSampler: @unchecked Sendable {
    struct Trace {
        /// Each change of a window's description: time, x, y, width, height,
        /// and 1 on screen, 0 off screen, -1 not listed.
        let windows: [UInt32: [[Double]]]
        /// Each change of a point's palette index: time and index, 0 for
        /// anything else, such as the desktop, -1 for an unreadable point.
        let probes: [(point: [Double], events: [[Double]])]
        let samples: Int
        let longestGap: Double
        let startedAt: Double
        let endedAt: Double

        /// Times are milliseconds from the commit. A window listed for good
        /// before the commit has a negative `listedMilliseconds`: a hide or
        /// show committed then could not race it.
        func facts(commit: Double, expected: [UInt32: CGRect], resumed: Double?) -> [String: Any] {
            func near(_ event: [Double], _ frame: CGRect) -> Bool {
                event[5] == 1 && abs(event[1] - frame.minX) <= 1 && abs(event[2] - frame.minY) <= 1
                    && abs(event[3] - frame.width) <= 1 && abs(event[4] - frame.height) <= 1
            }
            var listed: [String: Any] = [:], atCommit: [String: Any] = [:], afterResume: [String: Any] = [:]
            for (id, frame) in expected {
                let events = windows[id] ?? []
                // The state in force at the commit is the last change before it.
                atCommit[String(id)] = events.last { $0[0] <= commit }.map { near($0, frame) } ?? false
                // Listed for good: from that change on, every state matches.
                let settled = events.indices.first { index in events[index...].allSatisfy { near($0, frame) } }.map { events[$0] }
                listed[String(id)] = settled.map { ($0[0] - commit) * 1_000 } as Any? ?? NSNull()
                if let resumed {
                    afterResume[String(id)] = settled.flatMap { $0[0] >= resumed ? ($0[0] - resumed) * 1_000 : nil } as Any? ?? NSNull()
                }
            }
            func relative(_ event: [Double]) -> [Double] { [(event[0] - commit) * 1_000] + event.dropFirst() }
            return ["trace": Dictionary(uniqueKeysWithValues: windows.map { (String($0.key), $0.value.map(relative)) }),
                    "probes": probes.map { ["point": $0.point, "events": $0.events.map(relative)] as [String: Any] },
                    "listedMilliseconds": listed, "listedAtCommit": atCommit, "resumedListedMilliseconds": afterResume,
                    "traceStartMilliseconds": (startedAt - commit) * 1_000, "traceEndMilliseconds": (endedAt - commit) * 1_000,
                    "samples": samples, "longestSampleGapMilliseconds": longestGap * 1_000]
        }
    }

    let windows: [UInt32]
    let points: [CGPoint]
    let limit: Double
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var sampled = false
    private var stopping = false
    private var trace: Trace?

    @MainActor init(windows: [UInt32], command: [String: Any]) throws {
        self.windows = windows
        points = (command["stableProbes"] as? [[Double]] ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        limit = (command["limitMilliseconds"] as? Double ?? 150) / 1_000
        if !points.isEmpty, !CGPreflightScreenCaptureAccess() { throw FixtureContractError("grant Screen Recording to the signed fixture observer") }
    }

    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }

    /// Returns once the baseline, a sample before any write, is taken.
    func start() {
        let thread = Thread { [self] in run() }
        thread.qualityOfService = .userInteractive
        thread.start()
        while !lock.withLock({ sampled }) { usleep(100) }
    }

    func wait(until deadline: Double) {
        while PlacementSampler.now() < deadline { usleep(500) }
    }

    func finish() -> Trace {
        lock.withLock { stopping = true }
        done.wait()
        return lock.withLock { trace! }
    }

    private func run() {
        var listed: [UInt32: [[Double]]] = [:], probed = points.map { _ in [[Double]]() }
        var samples = 0, longest = 0.0, previous = PlacementSampler.now()
        let begin = previous
        while true {
            let at = PlacementSampler.now()
            for number in windows {
                let state: [Double] = Self.windowServer(number).map { [at, $0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height, $0.onScreen ? 1 : 0] }
                    ?? [at, 0, 0, 0, 0, -1]
                if listed[number]?.last.map({ Array($0.dropFirst()) != Array(state.dropFirst()) }) ?? true { listed[number, default: []].append(state) }
            }
            for (index, point) in points.enumerated() {
                let value = Double(Self.composited(at: point) ?? -1)
                if probed[index].last?[1] != value { probed[index].append([PlacementSampler.now(), value]) }
            }
            samples += 1; longest = max(longest, at - previous); previous = at
            if samples == 1 { lock.withLock { sampled = true } }
            if lock.withLock({ stopping }) { break }
            usleep(200)
        }
        let end = PlacementSampler.now()
        lock.withLock {
            trace = Trace(windows: listed, probes: zip(points, probed).map { ([$0.0.x, $0.0.y], $0.1) },
                          samples: samples, longestGap: longest, startedAt: begin, endedAt: end)
        }
        done.signal()
    }

    /// What WindowServer lists for one fixture window, as the stage reads it.
    static func windowServer(_ number: UInt32) -> (bounds: CGRect, onScreen: Bool)? {
        var pointer = UnsafeRawPointer(bitPattern: UInt(number))
        let ids = CFArrayCreate(nil, &pointer, 1, nil)
        guard let entry = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return (rect, entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    /// The palette index WindowServer composites at one screen point, with the
    /// recording's classification.
    private static func composited(at point: CGPoint) -> Int? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: Create.self)(CGRect(origin: point, size: CGSize(width: 1, height: 1)), 1, 0, 1 << 4)?
                .takeRetainedValue() else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let r = Int(pixel[0]), g = Int(pixel[1]), b = Int(pixel[2])
        guard [r, g, b].allSatisfy({ $0 <= 24 || $0 >= 231 }) else { return 0 }
        return switch (r >= 231 ? 4 : 0) | (g >= 231 ? 2 : 0) | (b >= 231 ? 1 : 0) {
        case 4: 1
        case 2: 2
        case 1: 3
        case 6: 4
        case 5: 5
        case 3: 6
        default: 0
        }
    }
}

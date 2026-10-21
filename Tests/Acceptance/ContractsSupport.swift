import Assumptions
import Foundation
import Testing

struct MacAssumption: TestTrait {
    let assumption: Assumption
}

func contract(_ assumption: Assumption) -> MacAssumption { MacAssumption(assumption: assumption) }

struct NativeContractReply: Codable {
    struct MotionSample: Codable {
        struct Window: Codable { let id: UInt32; let valid: Bool; let frame: [Double]; let visible: Bool; let source: String? }
        let at: Double
        let frame: Int?
        let startedAt: Double?
        let sampledAt: Double?
        let focused: UInt32?
        let windows: [Window]
        let order: [UInt32]
        let frontmost: Int32
    }
    let cgFrames: [String: [Double]]?
    let foreground: [String]?
    let motionSamples: [MotionSample]?
    let motionFrameCount: Int?
    let pointerPresses: Int?
    let pointerEvents: [String]?
    let reduceMotion: Bool?
    let motionChanges: [Bool]?
    let screenRecording: Bool?
    let preflightStable: Bool?
    let preflightMilliseconds: Double?
    struct Stage: Codable {
        let captureSize: [Double]?
        let scale: Double?
        let frameBefore: [Double]?
        let frameAfter: [Double]?
        let frontmostBefore: Int32?
        let frontmostAfter: Int32?
        let opaque: Double?
        let captureMilliseconds: Double?
        let overlayListedMilliseconds: Double?
        let overlayDrawnMilliseconds: Double?
        let overlayLayer: Int?
        let menuBarLayer: Int?
        let ignoresMouse: Bool?
        let key: Bool?
    }
    let stage: Stage?
    let sampledAt: Double?
    struct Window: Codable {
        let id: UInt32
        let idError: Int32
        let role: String?
        let roleError: Int32
        let subrole: String?
        let subroleError: Int32
        let layer: Int?
        let frame: [Double]
        let frameError: Int32
        let minimized: Bool?
        let fullscreen: Bool?
        let main: Bool?
        let mainError: Int32?
        let minimizedError: Int32?
        let fullscreenError: Int32?
        let sizeSettable: Bool
        let settableError: Int32
        let bar: Int?
        let tabs: Int
        let sheets: [Window]
    }
    struct Event: Codable {
        let name: String
        let id: UInt32?
        let idError: Int32?
        /// Whether the notified element equals the handle `watch` registered.
        let registered: Bool?
        /// The retained window handle equal to the notified element, if any.
        let handleID: UInt32?
        let pid: Int32?
        let knownPID: Int32?
        let mainThread: Bool
        let minimized: Bool?
        let focusedID: UInt32?
        let focusedError: Int32?
        let alivePIDs: [Int32]?
    }
    struct Chrome: Codable {
        let role: String?
        let tabs: [String]
        let contents: [String]
        let children: [String]
        let tabChildren: [[String]]
        let tabChildrenErrors: [Int32]
        let tabChildrenAreArrays: [Bool]
        let tabsInContents: Bool
        let tabsError: Int32
        let tabsIsArray: Bool
        let contentsError: Int32
        let contentsIsArray: Bool
        let childrenError: Int32
        let childrenIsArray: Bool
        let contentsInChildren: Bool
    }
    struct Membership: Codable {
        let id: UInt32
        let ordinary: [UInt64]
        let all: [UInt64]
    }
    let result: Int32?
    let writeReturnedAt: Double?
    let results: [Int32]?
    let readError: Int32?
    let listError: Int32?
    let listIsArray: Bool?
    let windows: [Window]?
    let window: Window?
    let focused: Window?
    let focusedError: Int32?
    let retainedWindows: [Window]?
    let chrome: [Chrome]?
    let hidden: Bool?
    let frontmost: Bool?
    let visibleIDs: [UInt32]?
    let alive: Bool?
    let listed: Bool?
    let bundleMatches: Bool?
    let regular: Bool?
    let prohibited: Bool?
    let terminated: Bool?
    let lifecycle: [Event]?
    let lifecycleCounts: [String: Int]?
    let events: [Event]?
    let equal: Bool?
    let capturedCount: Int?
    let capturedFrame: [Double]?
    let capturedFocus: UInt32?
    let screen: [Double]?
    let visibleFrame: [Double]?
    let cgDisplay: [Double]?
    let axVisibleFrame: [Double]?
    let activeSpace: UInt64?
    let closetSpace: UInt64?
    let memberships: [Membership]?
    let finderSafe: Bool?
    let desktopRole: String?
    let desktopID: UInt32?
    let desktopSubroleError: Int32?
    let finderFocused: Bool?
    let finderFrontmost: Bool?

    var roots: [Window] { windows ?? [] }
    var visible: Set<UInt32> { Set(visibleIDs ?? []) }
}

extension Acceptance {
    @Suite(AppSession(launchesApp: false))
    @MainActor
    struct Contracts {
        let desktop = Desktop()
        var harness: Harness { Harness.shared }
        var fixture: FixtureSession { harness.fixture }

        init() throws {
            try native("reset")
            for session in harness.otherFixtures { session.stop() }
            harness.otherFixtures.removeAll()
            harness.fixture.stop()
            harness.fixture = try FixtureSession(directory: harness.directory, number: 0)
        }

        @discardableResult
        func native(_ operation: String = "snapshot", session: FixtureSession? = nil, _ arguments: [String: Any] = [:]) throws -> NativeContractReply {
            let request = arguments.merging(["operation": operation, "pid": (session ?? fixture).pid]) { $1 }
            guard let result = try harness.observer.command("contract", request).contract else {
                throw HarnessError("the signed observer did not return native contract facts")
            }
            if ProcessInfo.processInfo.environment["TESSEL_CONTRACT_TRACE"] == "1" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                print("Native contract \(operation): " + String(decoding: try encoder.encode(result), as: UTF8.self))
            }
            return result
        }

        func other(prohibited: Bool = false) throws -> FixtureSession {
            try harness.other(prohibited: prohibited)
        }

        @discardableResult
        func window(_ id: UInt32, session: FixtureSession? = nil) throws -> NativeContractReply.Window {
            guard let result = try finalValue({ () throws -> NativeContractReply.Window? in
                let state = try native("snapshot", session: session)
                let windows = state.roots + state.roots.flatMap(\.sheets)
                return windows.first { $0.id == id && $0.roleError == 0 }
            }) else { throw HarnessError("fixture \(id) did not expose its AX handle within the final-state margin") }
            return result
        }

        func watch(_ names: [String], id: UInt32? = nil) throws {
            var arguments: [String: Any] = ["notifications": names]
            if let id { arguments["id"] = id }
            let results = try native("watch", arguments).results
            try #require(results == Array(repeating: 0, count: names.count), "native AX notification registration failed: \(results ?? [])")
        }

        /// A notification names `id` by its window ID or, when that lookup fails
        /// mid-transition, by AX equality with the observer's retained handle.
        func expectEvent(_ name: String, id: UInt32? = nil, minimized: Bool? = nil) throws {
            var events: [NativeContractReply.Event] = []
            guard try finalState({
                events = try native("events").events ?? []
                return events.contains { event in
                    event.name == name && event.mainThread && (id == nil || event.id == id || event.handleID == id)
                        && (minimized == nil || event.minimized == minimized)
                }
            }) else {
                let described = events.map { "\($0.name) id=\($0.id ?? 0) idError=\($0.idError ?? 0) handle=\($0.handleID.map(String.init) ?? "nil")" }
                throw HarnessError("native \(name) notification\(id.map { " for \($0)" } ?? "") did not arrive within the final-state margin; events \(described)")
            }
        }

        func write(_ id: UInt32, _ attribute: String, _ value: [Double]? = nil) throws -> Int32? {
            var arguments: [String: Any] = ["id": id, "attribute": attribute]
            if let value { arguments["value"] = value }
            return try native("write", arguments).result
        }

        func expectFocus(_ id: UInt32, session: FixtureSession? = nil) throws {
            try requireFinalState("native focus and main for fixture \(id)") {
                let state = try native(session: session)
                return state.focused?.id == id && state.focused?.main == true && state.frontmost == true
            }
        }
    }
}

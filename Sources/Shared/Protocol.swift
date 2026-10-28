import Foundation

enum WindowState: String, Codable, Sendable {
    case tiled, floats, minimized, hidden, fullscreen, ignored
}

struct WindowRecord: Codable, Sendable {
    let id: UInt32
    let app: String
    let bundleId: String
    var state: WindowState
    var reason: String
    let tabs: Int
    var workspace: Int? = nil
    var visible: Bool = false
    var rail: Int? = nil
    var slot: Int? = nil
    /// Raw monotonic seconds (`CLOCK_MONOTONIC_RAW`) when tessel produced this answer.
    var answeredAt: Double? = nil

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(app, forKey: .app)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(state, forKey: .state)
        try container.encode(reason, forKey: .reason)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(visible, forKey: .visible)
        try container.encode(rail, forKey: .rail)
        try container.encode(slot, forKey: .slot)
        try container.encode(answeredAt, forKey: .answeredAt)
    }
}

struct ConfigError: Error, Codable, Sendable {
    let line: Int
    let message: String
}

struct Configuration: Codable, Sendable, Equatable {
    var experiments: [String: Bool] = [:]
    var keys = KeyChord.layerDefaults
    var gaps = Gaps()
    var animation = Animation()
    var map = MapSettings()
}

struct MapSettings: Codable, Sendable, Equatable {
    var duration: Int = 1000
}

struct Animation: Codable, Sendable, Equatable {
    var duration: Int = 250
}

struct Gaps: Codable, Sendable, Equatable {
    var outer: Double = 10
}

struct WorkspaceStatus: Codable, Sendable, Equatable {
    var enabled = false
    var reason = "starting"
    var active = 1
    var layout = "carousel"
    var animationDuration: Int = 250
    /// Why carousel changes animate or not: "on", or "off: " and the reason.
    var motion = "on"
    var rail: Int? = nil
    var railCount = 0
    var gaps = Gaps()
    var keys = KeyChord.layerDefaults
    var layer: LayerStatus? = nil
}

struct LayerStatus: Codable, Sendable, Equatable {
    var state: String
    var focused: Bool
}

struct ConfigStatus: Codable, Sendable {
    let path: String
    var state: String = "defaults"
    var revision: UInt64 = 0
    var effective = Configuration()
    var error: ConfigError?

    // A stable null field makes error recovery explicit to CLI consumers.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(state, forKey: .state)
        try container.encode(revision, forKey: .revision)
        try container.encode(effective, forKey: .effective)
        try container.encode(error, forKey: .error)
    }
}

struct OpenAtLoginStatus: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case enabled, off, offInSettings, unavailable
    }
    var state: State
    var reason: String?

    var text: String {
        switch state {
        case .enabled: "Open at login: on"
        case .off: "Open at login: off"
        case .offInSettings: "Open at login: off in System Settings"
        case .unavailable: "Open at login: unavailable" + (reason.map { " (\($0))" } ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(reason, forKey: .reason)
    }
}

struct AppStatus: Codable, Sendable {
    let permission: String
    let config: ConfigStatus
    let version: String
    let pid: Int32
    var workspaces = WorkspaceStatus()
    var openAtLogin = OpenAtLoginStatus(state: .unavailable, reason: "development build")
    /// Raw monotonic seconds (`CLOCK_MONOTONIC_RAW`) when tessel produced this answer.
    var answeredAt: Double? = nil
    #if TESSEL_DEVELOPMENT
    /// Stage work in a fixture-only development build: window captures and
    /// shown motions. Both stay unchanged at rest.
    struct TestMotion: Codable, Sendable {
        var stageCaptures: UInt64 = 0
        var stageShows: UInt64 = 0
        var stageSettles: UInt64 = 0
        var stageClears: UInt64 = 0
        var stageMove: UInt64 = 0
        var stageCapturesPending = 0
        /// Screenshot requests per window in the current or last staged move,
        /// including unsuccessful requests and resize refreshes.
        var stageScreenshots: [String: UInt64] = [:]
    }
    var testMotion: TestMotion? = nil
    struct TestMap: Codable, Sendable {
        /// Tile counts in the last picture drawn by the real map adapter.
        var railTileCounts: [Int] = []
        var shows: UInt64 = 0
        var window: UInt32? = nil
        var key: Bool? = nil
        var main: Bool? = nil
    }
    var testMap: TestMap? = nil
    #endif
}

extension AppStatus {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(permission: try container.decode(String.self, forKey: .permission),
                  config: try container.decode(ConfigStatus.self, forKey: .config),
                  version: try container.decode(String.self, forKey: .version),
                  pid: try container.decode(Int32.self, forKey: .pid))
        workspaces = try container.decode(WorkspaceStatus.self, forKey: .workspaces)
        if let value = try container.decodeIfPresent(OpenAtLoginStatus.self, forKey: .openAtLogin) {
            openAtLogin = value
        }
        answeredAt = try container.decodeIfPresent(Double.self, forKey: .answeredAt)
        #if TESSEL_DEVELOPMENT
        testMotion = try container.decodeIfPresent(TestMotion.self, forKey: .testMotion)
        testMap = try container.decodeIfPresent(TestMap.self, forKey: .testMap)
        #endif
    }
}

struct Reply: Codable, Sendable {
    var windows: [WindowRecord]?
    var status: AppStatus?
    var error: String?
}

enum ConfigLocation {
    static var file: URL {
        let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return home.appendingPathComponent("tessel/tessel.toml").standardizedFileURL
    }
}

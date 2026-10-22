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
    var keys = KeyChord.defaults
    var gaps = Gaps()
    var animation = Animation()
    var layerEnabled: Bool { experiments["layer"] == true }
    var carouselEnabled: Bool { experiments["carousel"] == true || layerEnabled }
}

struct Animation: Codable, Sendable, Equatable {
    var duration: Int = 250
}

struct Gaps: Codable, Sendable, Equatable {
    var outer: Double = 10
}

struct WorkspaceStatus: Codable, Sendable, Equatable {
    var enabled = false
    var reason = "experiment off"
    var active = 1
    var layout = "stack"
    var animationDuration: Int = 250
    /// Why carousel changes animate or not: "on", or "off: " and the reason.
    var motion = "on"
    var rail: Int? = nil
    var railCount = 0
    var gaps = Gaps()
    var keys = KeyChord.defaults
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

struct AppStatus: Codable, Sendable {
    let permission: String
    let config: ConfigStatus
    let version: String
    let pid: Int32
    var workspaces = WorkspaceStatus()
    /// Raw monotonic seconds (`CLOCK_MONOTONIC_RAW`) when tessel produced this answer.
    var answeredAt: Double? = nil
    #if TESSEL_DEVELOPMENT
    /// Stage work in a fixture-only development build: window captures and
    /// shown motions. Both stay unchanged at rest.
    struct TestMotion: Codable, Sendable { var stageCaptures: UInt64 = 0; var stageShows: UInt64 = 0 }
    var testMotion: TestMotion? = nil
    #endif
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

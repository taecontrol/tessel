import Foundation

enum WindowState: String, Codable, Sendable {
    case tiled, floats, minimized, hidden
}

struct WindowRecord: Codable, Sendable {
    let id: UInt32
    let app: String
    let bundleId: String
    let state: WindowState
    let reason: String
    let tabs: Int
}

struct ConfigError: Error, Codable, Sendable {
    let line: Int
    let message: String
}

struct Configuration: Codable, Sendable, Equatable {
    var experiments: [String: Bool] = [:]
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

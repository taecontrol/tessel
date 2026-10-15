import Darwin
import Foundation

/// Foundation's schema is intentionally empty. Parse the TOML forms that can
/// express it; any assignment or other table is an unknown-key error.
enum ConfigParser {
    static func parse(_ data: Data) throws -> Configuration {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw ConfigError(line: 1, message: "Configuration must be UTF-8 and no larger than 64 KiB")
        }
        var seenExperiments = false
        for (index, source) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = uncomment(source).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.first == "[", line.last == "]", !line.hasPrefix("[[") else {
                throw ConfigError(line: lineNumber, message: line.contains("=") ? "Unknown configuration key" : "Invalid TOML; expected a table or key assignment")
            }
            let key = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            guard tableName(key) == "experiments" else {
                throw ConfigError(line: lineNumber, message: "Unknown or invalid configuration table")
            }
            guard !seenExperiments else { throw ConfigError(line: lineNumber, message: "Duplicate experiments table") }
            seenExperiments = true
        }
        return Configuration()
    }

    private static func tableName(_ value: String) -> String? {
        if value == "experiments" { return value }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("\"") {
            return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        }
        return nil
    }

    private static func uncomment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if character == quote { quote = nil }
            else if quote == nil, character == "\"" || character == "'" { quote = character }
            else if quote == nil, character == "#" { return String(line[..<index]) }
        }
        return line
    }
}

@MainActor
final class ConfigManager {
    private let file = ConfigLocation.file
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var previous: Data?
    private var hasRead = false
    private(set) var status: ConfigStatus
    var onChange: ((ConfigStatus) -> Void)?

    init() {
        status = ConfigStatus(path: file.path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        reload()
        watch()
    }

    func reload() {
        let data: Data?
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { data = nil }
        catch {
            status.state = "error"
            status.error = ConfigError(line: 1, message: "Unable to read configuration file")
            onChange?(status)
            return
        }
        guard !hasRead || previous != data else { return }
        hasRead = true
        previous = data
        do {
            status.effective = try data.map(ConfigParser.parse) ?? Configuration()
            status.state = data == nil ? "defaults" : "loaded"
            status.error = nil
            status.revision += 1
        } catch let error as ConfigError {
            status.state = "error"
            status.error = error
        } catch {
            status.state = "error"
            status.error = ConfigError(line: 1, message: "Invalid TOML")
        }
        onChange?(status)
    }

    private func watch() {
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
        let directory = file.deletingLastPathComponent()
        var ancestor = directory.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        for path in Set([file.path, directory.path, ancestor.path]) {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleReload() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                self?.watch() // Editors often replace the inode rather than writing it.
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: item)
    }
}

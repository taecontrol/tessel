import Darwin
import Foundation

/// Foundation's schema is intentionally empty. Parse the TOML forms that can
/// express it; any assignment or other table is an unknown-key error.
enum ConfigParser {
    private static let horizontalWhitespace = CharacterSet(charactersIn: " \t")

    static func parse(_ data: Data) throws -> Configuration {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw ConfigError(line: 1, message: "Configuration must be UTF-8 and no larger than 64 KiB")
        }
        var seenExperiments = false
        for (index, source) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            guard !source.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9) || $0.value == 0x7f }) else {
                throw ConfigError(line: lineNumber, message: "Invalid TOML control character")
            }
            let line = uncomment(source).trimmingCharacters(in: horizontalWhitespace)
            if line.isEmpty { continue }
            guard line.first == "[", line.last == "]", !line.hasPrefix("[[") else {
                throw ConfigError(line: lineNumber, message: line.contains("=") ? "Unknown configuration key" : "Invalid TOML; expected a table or key assignment")
            }
            let key = line.dropFirst().dropLast().trimmingCharacters(in: horizontalWhitespace)
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
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
        let scalars = Array(value.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 1
        while index < scalars.count - 1 {
            let scalar = scalars[index]
            guard scalar != "\"" else { return nil }
            if scalar != "\\" { result.append(scalar); index += 1; continue }
            index += 1
            guard index < scalars.count - 1 else { return nil }
            switch scalars[index] {
            case "u", "U":
                let end = index + 1 + (scalars[index] == "u" ? 4 : 8)
                guard end <= scalars.count - 1 else { return nil }
                let digits = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                guard digits.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF".unicodeScalars.contains($0) }),
                      let number = UInt32(digits, radix: 16), let decoded = UnicodeScalar(number) else { return nil }
                result.append(decoded)
                index = end
            case "\"", "\\": result.append(scalars[index]); index += 1
            case "b": result.append("\u{8}"); index += 1
            case "t": result.append("\t"); index += 1
            case "n": result.append("\n"); index += 1
            case "f": result.append("\u{c}"); index += 1
            case "r": result.append("\r"); index += 1
            default: return nil
            }
        }
        return String(result)
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
    private var watchers: [String: (source: DispatchSourceFileSystemObject, device: dev_t, inode: ino_t)] = [:]
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
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: 65_537) ?? Data()
        }
        catch CocoaError.fileReadNoSuchFile { data = nil }
        catch CocoaError.fileNoSuchFile { data = nil }
        catch {
            hasRead = false
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
        let directory = file.deletingLastPathComponent()
        var ancestor = directory.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        let paths = Set([file.path, directory.path, ancestor.path])
        for path in watchers.keys where !paths.contains(path) {
            watchers.removeValue(forKey: path)?.source.cancel()
        }
        for path in paths {
            var info = stat()
            if stat(path, &info) == 0, let previous = watchers[path], previous.device == info.st_dev, previous.inode == info.st_ino {
                continue // Keep the existing descriptor across temporary permission errors.
            }
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            guard fstat(fd, &info) == 0 else { close(fd); continue }
            watchers.removeValue(forKey: path)?.source.cancel()
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[path] = (source, info.st_dev, info.st_ino)
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

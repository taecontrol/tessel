import Foundation

/// Parse the experiment's bounded TOML schema before replacing any live state.
enum ConfigParser {
    private static let horizontalWhitespace = CharacterSet(charactersIn: " \t")
    private static let bareKeyCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func parse(_ data: Data) throws -> Configuration {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw ConfigError(line: 1, message: "Configuration must be UTF-8 and no larger than 64 KiB")
        }
        var configuration = Configuration()
        var tables = Set<String>()
        var keys = Set<String>()
        var table = ""
        var overrides: [String:String] = [:]
        for (index, source) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            guard !source.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9) || $0.value == 0x7f }) else {
                throw ConfigError(line: lineNumber, message: "Invalid TOML control character")
            }
            let line = uncomment(source).trimmingCharacters(in: horizontalWhitespace)
            if line.isEmpty { continue }
            if line.first == "[" {
                guard line.last == "]", !line.hasPrefix("[["),
                      let name = keyName(String(line.dropFirst().dropLast()).trimmingCharacters(in: horizontalWhitespace)),
                      ["experiments", "keys", "gaps", "animation"].contains(name) else {
                    throw ConfigError(line: lineNumber, message: "Unknown or invalid configuration table")
                }
                guard tables.insert(name).inserted else { throw ConfigError(line: lineNumber, message: "Duplicate \(name) table") }
                table = name
                continue
            }
            guard let separator = assignment(in: line),
                  let key = keyName(String(line[..<separator]).trimmingCharacters(in: horizontalWhitespace)) else {
                throw ConfigError(line: lineNumber, message: "Invalid TOML; expected a table or key assignment")
            }
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: horizontalWhitespace)
            let canonical = table == "keys" ? KeyChord(key)?.name ?? key : key
            guard keys.insert(table + "." + canonical).inserted else { throw ConfigError(line: lineNumber, message: "Duplicate configuration key") }
            switch (table, key) {
            case ("experiments", "workspaces"), ("experiments", "carousel"), ("experiments", "layer"):
                guard ["true", "false"].contains(value) else { throw ConfigError(line: lineNumber, message: "\(key) must be a boolean") }
                // Kept experiments accept their former keys as inert compatibility input.
            case ("animation", "duration"):
                guard let duration = number(value, integer: true), (0...1000).contains(duration) else {
                    throw ConfigError(line: lineNumber, message: "duration must be a TOML integer from 0 to 1000")
                }
                configuration.animation.duration = Int(duration)
            case ("gaps", "outer"):
                guard let gap = number(value), gap.isFinite, gap >= 0 else { throw ConfigError(line: lineNumber, message: "outer must be a nonnegative TOML number") }
                configuration.gaps.outer = gap
            case ("keys", _):
                guard let chord = KeyChord(key) else { throw ConfigError(line: lineNumber, message: "Invalid key or modifier; use alt, shift, ctrl, cmd and a letter or digit") }
                guard let command = string(value), command.isEmpty || WorkspaceCommand(command) != nil else {
                    throw ConfigError(line: lineNumber, message: "Unknown command; use workspace 1…10, send 1…10, focus next|previous|left|right|up|down, move left|right|up|down, cycle width, toggle layer, or toggle float")
                }
                overrides[chord.name] = command
            default: throw ConfigError(line: lineNumber, message: "Unknown configuration key")
            }
        }
        let defaults = KeyChord.layerDefaults
        configuration.keys = defaults.merging(overrides) { _,new in new }
        return configuration
    }

    private static func number(_ value: String, integer: Bool = false) -> Double? {
        func matches(_ pattern: String) -> Bool {
            value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
        }
        let clean = value.replacingOccurrences(of: "_", with: "")
        for (prefix, digits, radix) in [("0x", "0-9a-fA-F", 16), ("0o", "0-7", 8), ("0b", "01", 2)] {
            if matches(prefix + "[" + digits + "](?:_?[" + digits + "])*") {
                return Int64(clean.dropFirst(2), radix: radix).map(Double.init)
            }
        }
        let decimal = "[+-]?(?:0|[1-9](?:_?[0-9])*)"
        let floating = "(?:\\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?"
        guard matches(decimal + (integer ? "" : floating)) else { return nil }
        if !clean.contains("."), !clean.lowercased().contains("e") { return Int64(clean).map(Double.init) }
        return Double(clean)
    }

    private static func keyName(_ value: String) -> String? {
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ bareKeyCharacters.contains($0) }) { return value }
        return string(value)
    }

    private static func assignment(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if character == quote { quote = nil }
            else if quote == nil, character == "\"" || character == "'" { quote = character }
            else if quote == nil, character == "=" { return index }
        }
        return nil
    }

    private static func string(_ value: String) -> String? {
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

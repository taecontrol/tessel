import Foundation
import Testing

enum IntegritySources {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func files(in directory: String) throws -> [(path: String, source: String)] {
        let base = root.appending(path: directory)
        return try FileManager.default.subpathsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".swift") }.sorted().map {
            (directory + "/" + $0, try String(contentsOf: base.appending(path: $0), encoding: .utf8))
        }
    }
}

enum ExampleLayers {
    enum Layer: String { case contract = "C", tooling = "T", policy = "P", journey = "J", latency = "L", resources = "R", capture = "X" }
    struct Tag {
        let id: String
        let layer: Layer?
        let path: String
    }
    struct Map {
        var layers: [String: Layer] = [:]
        var errors: [String] = []
        var pendingCaptures: Set<String> = []
    }
    static let heading = "## Acceptance example layers (#24)"
    private static let idPattern = #"#(?:1|2|18|19|26|33|36|38|39|40|41|49|51|55) (?:E[1-9][0-9]*[a-z]?|U-[a-z0-9]+(?:-[a-z0-9]+)*)(?![A-Za-z0-9_-])"#

    static func parse(_ document: String) -> Map {
        var result = Map()
        guard let section = document.components(separatedBy: heading).dropFirst().first else {
            result.errors.append("Missing \(heading) map"); return result
        }
        var table = false
        for line in section.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") { break }
            if line.hasPrefix("<!-- Pending capture: "), line.hasSuffix(" -->") {
                result.pendingCaptures.insert(String(line.dropFirst("<!-- Pending capture: ".count).dropLast(4)))
            }
            if line == "| Example | Layer |" { table = true; continue }
            guard table, line.hasPrefix("|") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.count == 4 && cells[1] == "---" && cells[2] == "---" { continue }
            guard cells.count == 4, cells[1].range(of: "^" + idPattern + "$", options: .regularExpression) != nil,
                  let layer = Layer(rawValue: cells[2]) else {
                result.errors.append("Invalid example map row: \(line)"); continue
            }
            if result.layers.updateValue(layer, forKey: cells[1]) != nil { result.errors.append("Duplicate mapped ID: \(cells[1])") }
        }
        for id in result.pendingCaptures where result.layers[id] != .capture { result.errors.append("Only a mapped X example may defer its capture: \(id)") }
        if result.layers.isEmpty { result.errors.append("The example map is empty") }
        return result
    }

    static func tags(in source: String, path: String) -> [Tag] {
        let text = source as NSString, code = PolicyPurity.codeOnly(source) as NSString
        let labels = try! NSRegularExpression(pattern: #"(@Test|\bstep)\s*\(\s*(#*)("""|")"#)
        let ids = try! NSRegularExpression(pattern: idPattern)
        let functions = try! NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z_0-9]*)"#)
        var tags: [Tag] = []
        for label in labels.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard code.substring(with: label.range(at: 1)) == text.substring(with: label.range(at: 1)) else { continue }
            let start = NSMaxRange(label.range)
            let suffix = text.substring(with: label.range(at: 3)) + text.substring(with: label.range(at: 2))
            let escape = "\\" + text.substring(with: label.range(at: 2))
            var end = start
            func matches(_ value: String) -> Bool {
                let count = (value as NSString).length
                return end + count <= text.length && text.substring(with: NSRange(location: end, length: count)) == value
            }
            while end < text.length {
                if matches(escape) { end += (escape as NSString).length + 1 }
                else if matches(suffix) { break }
                else { end += 1 }
            }
            guard end <= text.length else { continue }
            let isStep = text.substring(with: label.range(at: 1)) == "step"
            var function = ""
            if !isStep, let match = functions.firstMatch(in: code as String, range: NSRange(location: NSMaxRange(label.range), length: code.length - NSMaxRange(label.range))) {
                function = code.substring(with: match.range(at: 1))
            }
            let name = text.substring(with: NSRange(location: start, length: end - start)) as NSString
            let layer = layer(path: path, function: function, step: isStep)
            for id in ids.matches(in: name as String, range: NSRange(location: 0, length: name.length)) {
                tags.append(Tag(id: name.substring(with: id.range), layer: layer, path: path))
            }
        }
        return tags
    }

    private static func layer(path: String, function: String, step: Bool) -> Layer? {
        if path.hasPrefix("Tests/Acceptance/Contracts") { return .contract }
        if path.hasPrefix("Tests/CheckTests/") { return .tooling }
        if path.hasPrefix("Tests/PolicyTests/Scenarios/") && !step { return .policy }
        if path.hasPrefix("Tests/Acceptance/Journeys") && path.hasSuffix(".swift") { return .journey }
        if path == "Tests/Acceptance/Latency.swift" && !step { return .latency }
        if path == "Tests/Acceptance/Resources.swift" && !step { return .resources }
        if path.hasPrefix("Tests/Acceptance/") && !step && (function.hasPrefix("capture") || path.hasPrefix("Tests/Acceptance/Captures")) { return .capture }
        return nil
    }

    static func missing(in map: [String: Layer], tags: [Tag], pendingCaptures: Set<String> = []) -> [String] {
        map.keys.filter { id in !(map[id] == .capture && pendingCaptures.contains(id)) && !tags.contains { $0.id == id && $0.layer == map[id] } }.sorted()
    }
    static func stray(in map: [String: Layer], tags: [Tag]) -> [String] {
        tags.compactMap { tag in
            guard let expected = map[tag.id] else { return "\(tag.id): unmapped ID in \(tag.path)" }
            guard tag.layer == expected else { return "\(tag.id): expected \(expected.rawValue), found in \(tag.path)" }
            return nil
        }.sorted()
    }
}

@Suite struct ExampleLayerIntegrity {
    @Test("E20: map and source checker reject missing, duplicate, unknown and misplaced example IDs")
    func negativeControls() {
        let table = ExampleLayers.heading + "\n| Example | Layer |\n| --- | --- |\n| #2 E8 | P |\n"
        let map = ExampleLayers.parse(table)
        #expect(map.errors.isEmpty)
        #expect(!ExampleLayers.parse(table + "| #2 E8 | J |\n").errors.isEmpty)
        #expect(!ExampleLayers.parse(table + "| #2 E9 | Q |\n").errors.isEmpty)
        #expect(!ExampleLayers.parse("No map").errors.isEmpty)
        let pending = table + "| #26 E21 | X |\n<!-- Pending capture: #26 E21 -->\n"
        let capture = ExampleLayers.parse(pending)
        #expect(capture.errors.isEmpty && capture.pendingCaptures == ["#26 E21"])
        #expect(ExampleLayers.missing(in: capture.layers, tags: []).contains("#26 E21"))
        #expect(ExampleLayers.missing(in: capture.layers, tags: [], pendingCaptures: capture.pendingCaptures) == ["#2 E8"])
        #expect(!ExampleLayers.parse(table + "<!-- Pending capture: #2 E8 -->\n").errors.isEmpty)
        let source = "// 🧶 @Test(\"#2 E99\")\n@Test(\"#2 E8; #2 E999: send\") func send() {}"
        let tags = ExampleLayers.tags(in: source, path: "Tests/PolicyTests/Scenarios/Send.swift")
        #expect(tags.map(\.id) == ["#2 E8", "#2 E999"])
        let failedFocus = ExampleLayers.tags(in: "@Test(\"#41 E3; #41 E3a; #41 E3b\") func focus() {}", path: "Tests/PolicyTests/Scenarios/Focus.swift")
        #expect(failedFocus.map(\.id) == ["#41 E3", "#41 E3a", "#41 E3b"])
        #expect(ExampleLayers.tags(in: "@Test(\"#41 E3ab\") func invalid() {}", path: "Tests/PolicyTests/Scenarios/Focus.swift").isEmpty)
        let shared = ExampleLayers.tags(in: "@Test(\"#26 E24; #19 E28: shared idle budget\") func idle() {}", path: "Tests/Acceptance/Resources.swift")
        #expect(shared.map(\.id) == ["#26 E24", "#19 E28"])
        #expect(shared.allSatisfy { $0.layer == .resources })
        #expect(ExampleLayers.missing(in: map.layers, tags: []).contains("#2 E8"))
        #expect(ExampleLayers.missing(in: map.layers, tags: tags).isEmpty)
        #expect(ExampleLayers.stray(in: map.layers, tags: tags).first?.contains("#2 E999") == true)
        let wrong = ExampleLayers.tags(in: source, path: "Tests/Acceptance/Journeys.swift")
        #expect(ExampleLayers.stray(in: map.layers, tags: wrong).contains { $0.contains("#2 E8") })
        let literal = "let example = #\"@Test(\"#2 E8\") func send() {}\"#"
        #expect(ExampleLayers.tags(in: literal, path: "Tests/PolicyTests/Integrity/Check.swift").isEmpty)
        let step = ExampleLayers.tags(in: "step(\"#2 E8 send\") {}", path: "Tests/Acceptance/Journeys.swift")
        #expect(step.first?.layer == .journey)
        let raw = ##"@Test(#"#2 E999: unmapped"#) func raw() {}"##
        let multiline = "@Test(\"\"\"\n#2 E999: unmapped\n\"\"\") func multiline() {}"
        for source in [raw, multiline] {
            let tags = ExampleLayers.tags(in: source, path: "Tests/PolicyTests/Scenarios/Send.swift")
            #expect(tags.map(\.id) == ["#2 E999"])
            #expect(ExampleLayers.stray(in: map.layers, tags: tags).first?.contains("#2 E999") == true)
        }
        let rawStep = ##"step(#"#2 E999 unmapped"#) {}"##
        #expect(ExampleLayers.tags(in: rawStep, path: "Tests/Acceptance/Journeys.swift").first?.id == "#2 E999")
    }

    @Test("E20: every accepted example is tagged in exactly its mapped layer")
    func sourceExamples() throws {
        let map = ExampleLayers.parse(try String(contentsOf: IntegritySources.root.appending(path: "docs/development.md"), encoding: .utf8))
        #expect(map.errors.isEmpty, "\(map.errors.joined(separator: "\n"))")
        let tags = try IntegritySources.files(in: "Tests").flatMap { ExampleLayers.tags(in: $0.source, path: $0.path) }
        let stray = ExampleLayers.stray(in: map.layers, tags: tags)
        #expect(stray.isEmpty, "\(stray.joined(separator: "\n"))")
        let missing = ExampleLayers.missing(in: map.layers, tags: tags, pendingCaptures: map.pendingCaptures)
        #expect(missing.isEmpty, "Mapped IDs without tests: \(missing.joined(separator: ", "))")
    }
}

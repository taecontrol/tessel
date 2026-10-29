import Foundation
import Testing

@Suite struct BrandChecks {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let brand = "docs/brand"
    private static let prose = ["README.md", "AGENTS.md", "docs/development.md", "docs/features.md", "docs/policy-scenarios.md", "docs/brand/README.md"]
    private static let interface = ["Sources/App", "Sources/CLI", "Sources/Shared", "Sources/Policy"]

    // MARK: Brand assets

    @Test("#59 E11: the brand assets are committed at their sizes, with outlined text and no SF Pro")
    func brandAssets() throws {
        let directory = root.appending(path: Self.brand)
        for name in ["tessel-mark.svg", "tessel-mark-dark.svg", "tessel-lockup.svg", "tessel-lockup-dark.svg"] {
            let svg = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            #expect(svg.contains("<svg"), "\(name) must be an SVG")
            #expect(Self.liveText(in: svg).isEmpty, "\(name) must draw its text as outlines: \(Self.liveText(in: svg))")
        }
        for (name, width, height) in [("favicon-16.png", 16, 16), ("favicon-32.png", 32, 32), ("social-preview.png", 1280, 640)] {
            let size = try Self.pngSize(Data(contentsOf: directory.appending(path: name)))
            #expect(size?.width == width && size?.height == height, "\(name) must be \(width)×\(height)")
        }
        let readme = try String(contentsOf: directory.appending(path: "README.md"), encoding: .utf8)
        #expect(readme.contains("favicon-16.png") && readme.contains("favicon-32.png") && readme.localizedCaseInsensitiveContains("web only"),
                "the brand README must label the hinted favicons as web only")
        let sources = ["Sources/App/Tessel.icon", "Sources/App/TesselDev.icon", Self.brand]
        for folder in sources {
            for file in try FileManager.default.subpathsOfDirectory(atPath: root.appending(path: folder).path) where file.hasSuffix(".svg") {
                let svg = try String(contentsOf: root.appending(path: folder + "/" + file), encoding: .utf8)
                #expect(!Self.mentionsSFPro(svg), "\(folder)/\(file) must not contain SF Pro")
            }
        }
    }

    // MARK: License

    @Test("#59 E12: the README keeps the code MIT and excludes the Tessel name and logo")
    func licenseExcludesNameAndLogo() throws {
        // Markdown wraps prose, so compare the README with its whitespace collapsed.
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        #expect(readme.contains("[MIT](LICENSE)"))
        #expect(readme.contains("The Tessel name and logo are not covered by the MIT license"))
    }

    // MARK: Product name

    @Test("#59 E13: user-facing prose and interface strings name the product Tessel")
    func productIsNamedTessel() throws {
        for path in Self.prose {
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            #expect(Self.lowercaseNameInProse(text).isEmpty, "\(path) names the product in lowercase: \(Self.lowercaseNameInProse(text).prefix(5))")
        }
        for folder in Self.interface {
            for file in try FileManager.default.subpathsOfDirectory(atPath: root.appending(path: folder).path) where file.hasSuffix(".swift") {
                let source = try String(contentsOf: root.appending(path: folder + "/" + file), encoding: .utf8)
                #expect(Self.lowercaseNameInStrings(source).isEmpty, "\(folder)/\(file) shows the product in lowercase: \(Self.lowercaseNameInStrings(source))")
            }
        }
    }

    @Test("#59 E14: renaming the product never renames an identifier or an accepted ADR")
    func identifiersKeepTheirNames() throws {
        func read(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }
        let build = try read("Tools/Build/Main.swift")
        for identifier in [#""com.taecontrol.tessel""#, #""com.taecontrol.tessel.dev""#, #""Tessel Dev.app""#, #""Tessel.app""#, #"appending(path: "tessel")"#] {
            #expect(build.contains(identifier), "the build must keep \(identifier)")
        }
        #expect(try read("Sources/Shared/Protocol.swift").contains(#""tessel/tessel.toml""#))
        #expect(try read("Sources/Shared/IPC.swift").contains(#""/tmp/tessel-\(getuid())""#))
        #expect(try read("Sources/App/SocketServer.swift").contains(#""tessel.ipc""#))
        #expect(try read("Sources/CLI/Main.swift").contains("Usage: tessel windows [--json] | tessel status [--json]"))
        for adr in ["0001-swift-for-build-and-verification-tooling", "0004-verify-policy-against-a-simulated-macos",
                    "0006-move-carousel-windows-through-captures-on-a-stage", "0007-capture-only-windows-that-are-drawn"] {
            #expect(!Self.lowercaseNameInProse(try read("docs/adr/\(adr).md")).isEmpty, "accepted ADR \(adr) keeps its original wording")
        }
    }

    @Test("the brand guards reject what their examples forbid and accept identifiers")
    func guardsCanFail() {
        #expect(!Self.liveText(in: #"<svg><text x="0">Tessel</text></svg>"#).isEmpty)
        #expect(!Self.liveText(in: #"<svg><g font-family="Inter"/></svg>"#).isEmpty)
        #expect(Self.liveText(in: #"<svg><path d="M0 0h1v1z"/></svg>"#).isEmpty)
        #expect(Self.mentionsSFPro("<svg><!-- SF Pro Display --></svg>") && Self.mentionsSFPro("font: SFPro-Semibold"))
        #expect(!Self.mentionsSFPro("<svg><path d=\"M0 0\"/></svg>"))
        for forbidden in ["tessel is an experiment.", "Open tessel's menu.", "Quit and open tessel again."] {
            #expect(!Self.lowercaseNameInProse(forbidden).isEmpty, "the prose guard must reject \(forbidden)")
        }
        for allowed in ["Run `tessel status`.", "See [the repo](https://github.com/taecontrol/tessel).", "Use tessel-check and tessel-build.",
                        "```sh\ntessel windows\n```", "`$XDG_CONFIG_HOME/tessel/tessel.toml`", "Tessel is an experiment."] {
            #expect(Self.lowercaseNameInProse(allowed).isEmpty, "the prose guard must accept \(allowed)")
        }
        for forbidden in [#"menu.addItem(withTitle: "Quit tessel", action: nil, keyEquivalent: "q")"#, #"Reply(error: "tessel is starting")"#,
                          #"print("tessel \(status.version)")"#, #"setAccessibilityLabel("tessel: " + label)"#] {
            #expect(!Self.lowercaseNameInStrings(forbidden).isEmpty, "the interface guard must reject \(forbidden)")
        }
        for allowed in [#"DispatchQueue(label: "tessel.ipc")"#, #"print("Usage: tessel windows [--json] | tessel status [--json]")"#,
                        #"let path = "tessel/tessel.toml""#, #"// tessel is an experiment"#, #"Reply(error: "Tessel is starting")"#] {
            #expect(Self.lowercaseNameInStrings(allowed).isEmpty, "the interface guard must accept \(allowed)")
        }
    }

    // MARK: Guards

    /// "tessel" as a standalone lowercase word: not a path, URL, file name, tool name or command.
    private static let lowercaseName = #"(?<![\w./$-])tessel(?![\w./-])"#

    static func lowercaseNameInProse(_ text: String) -> [String] {
        let stripped = text
            .replacingOccurrences(of: #"(?s)```.*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"`[^`\n]*`"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\]\([^)\s]*\)"#, with: "]", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        return matches(of: lowercaseName, in: stripped)
    }

    static func lowercaseNameInStrings(_ source: String) -> [String] {
        let code = source.replacingOccurrences(of: #"(?s)/\*.*?\*/|//[^\r\n]*"#, with: " ", options: .regularExpression)
        return matches(of: #""(?:[^"\\\n]|\\.)*""#, in: code)
            // A command line names the executable, not the product.
            .map { $0.replacingOccurrences(of: #"\btessel (?=windows\b|status\b)"#, with: "", options: .regularExpression) }
            .filter { !matches(of: lowercaseName, in: $0).isEmpty }
    }

    static func liveText(in svg: String) -> [String] {
        matches(of: #"(?i)<text\b|<tspan\b|font-family|@font-face"#, in: svg)
    }

    static func mentionsSFPro(_ text: String) -> Bool {
        text.range(of: #"(?i)\bSF[ -]?Pro"#, options: .regularExpression) != nil
    }

    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 24, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A][...], String(decoding: bytes[12..<16], as: UTF8.self) == "IHDR" else { return nil }
        let value = { (offset: Int) in bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (value(16), value(20))
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

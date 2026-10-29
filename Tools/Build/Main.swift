import Foundation

/// Builds registrable, signed development bundles. Never falls back to ad-hoc signing.
@main
struct TesselBuild {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let usage = "Usage: tessel-build [--if-needed] [--signing-config FILE] [--output-dir DIR] [--variant dev|daily]"

    static func main() {
        do {
            try build(options: Options(CommandLine.arguments.dropFirst()))
        } catch let failure as Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            exit(failure.status)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    struct Options {
        var signingConfig = root.appending(path: "Signing.local.xcconfig")
        var outputDir = root.appending(path: ".build/apps")
        var variant = "dev"
        var ifNeeded = false

        init<Arguments: Sequence<String>>(_ arguments: Arguments) throws {
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                if argument == "-h" || argument == "--help" { print(usage); exit(0) }
                if argument == "--if-needed" { ifNeeded = true; continue }
                guard ["--signing-config", "--output-dir", "--variant"].contains(argument), let value = iterator.next() else {
                    throw Failure(usage, status: 2)
                }
                switch argument {
                case "--signing-config": signingConfig = URL(fileURLWithPath: value)
                case "--output-dir": outputDir = URL(fileURLWithPath: value)
                default:
                    guard ["dev", "daily"].contains(value) else { throw Failure(usage, status: 2) }
                    variant = value
                }
            }
        }
    }

    struct Failure: Error {
        let message: String
        let status: Int32
        init(_ message: String, status: Int32 = 1) {
            self.message = message
            self.status = status
        }
    }

    static func build(options: Options) throws {
        let identity = try signingIdentity(options.signingConfig)
        let compiler = try run(["xcrun", "swiftc", "--version"])
        guard compiler.status == 0 else { throw Failure("Could not identify the Swift compiler.") }
        let inputs = try BuildManifest.inputs(root: root, signingConfig: options.signingConfig, variant: options.variant, compiler: compiler.output)
        let manifestURL = options.outputDir.appending(path: "build-manifest.json")
        let bundleNames = [options.variant == "dev" ? "Tessel Dev.app" : "Tessel.app", "Tessel Fixture.app"]
        if options.ifNeeded,
           let previous = try? JSONDecoder().decode(BuildManifest.self, from: Data(contentsOf: manifestURL)),
           previous.inputs == inputs,
           let artifacts = try? BuildManifest.files(in: bundleNames, relativeTo: options.outputDir), previous.artifacts == artifacts {
            print("Signed bundles match current build inputs and artifacts.")
            return
        }
        try? FileManager.default.removeItem(at: manifestURL)
        let staging = root.appending(path: ".build/staging")
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try manager.createDirectory(at: options.outputDir, withIntermediateDirectories: true)
        let stage = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: staging, create: true)
        defer { try? manager.removeItem(at: stage) }

        let stamp = buildStamp()
        let buildInfo = stage.appending(path: "BuildInfo.swift")
        try Data("enum BuildInfo { static let version = \"0.1.0+\(stamp)\" }\n".utf8).write(to: buildInfo)
        let common = try sources(in: "Sources/Shared")

        func compileCommand(_ folder: String, to output: URL, extra: [URL] = []) throws -> [String] {
            let command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-package-name", "tessel", "-O", "-target", "arm64-apple-macos27.0", "-o", output.path]
                + (["Sources/App", "Sources/CLI"].contains(folder) && options.variant == "dev" ? ["-D", "TESSEL_DEVELOPMENT"] : [])
            let policy = try folder == "Sources/App" ? sources(in: "Sources/Ports") + sources(in: "Sources/Policy") : []
            return try command + (common + policy + sources(in: folder) + extra).map(\.path)
        }

        func sign(_ path: URL, identifier: String? = nil) throws {
            var command = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
            if let identifier { command += ["--identifier", identifier] }
            guard try run(command + [path.path]).status == 0 else {
                throw Failure("Code signing failed; no unsigned bundle was installed. Check the local identity and keychain access.")
            }
        }

        let development = options.variant == "dev"
        let name = development ? "Tessel Dev" : "Tessel"
        let bundleID = development ? "com.taecontrol.tessel.dev" : "com.taecontrol.tessel"
        let bundles: [(name: String, identifier: String, folder: String, executable: String, extra: [URL])] = [
            (name, bundleID, "Sources/App", "TesselApp", [buildInfo]),
            ("Tessel Fixture", "com.taecontrol.tessel.fixture", "Tests/Fixture", "TesselFixture", []),
        ]
        // Each whole-module compile uses about one core, so the executables
        // compile concurrently; signing and installation stay sequential.
        var compiles: [(folder: String, command: [String])] = []
        for bundle in bundles {
            let macOS = stage.appending(path: bundle.name + ".app/Contents/MacOS")
            try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
            compiles.append((bundle.folder, try compileCommand(bundle.folder, to: macOS.appending(path: bundle.executable), extra: bundle.extra)))
            if bundle.executable == "TesselApp" {
                compiles.append(("Sources/CLI", try compileCommand("Sources/CLI", to: macOS.appending(path: "tessel"))))
            }
        }
        let succeeded = Results(count: compiles.count)
        DispatchQueue.concurrentPerform(iterations: compiles.count) { index in
            succeeded[index] = (try? run(compiles[index].command, capture: false).status) == 0
        }
        if let failed = compiles.indices.first(where: { !succeeded[$0] }) { throw Failure("Compilation of \(compiles[failed].folder) failed.") }
        for bundle in bundles {
            let app = bundle.executable == "TesselApp"
            let path = stage.appending(path: bundle.name + ".app")
            let macOS = path.appending(path: "Contents/MacOS")
            try writeInfo(into: path, name: bundle.name, identifier: bundle.identifier, executable: bundle.executable, version: stamp, variant: options.variant)
            if app { try sign(macOS.appending(path: "tessel"), identifier: bundle.identifier + ".cli") }
            try sign(path)
            let verified = try run(["codesign", "--verify", "--strict", path.path])
            guard verified.status == 0 else {
                throw Failure("Signature verification failed: " + verified.error.replacingOccurrences(of: identity, with: "<local identity>"))
            }
            let destination = options.outputDir.appending(path: path.lastPathComponent)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: path, to: destination)
        }
        guard try BuildManifest.inputs(root: root, signingConfig: options.signingConfig, variant: options.variant, compiler: compiler.output) == inputs else {
            throw Failure("Build inputs changed during compilation; rerun scripts/build.")
        }
        let manifest = try BuildManifest(inputs: inputs, artifacts: BuildManifest.files(in: bundleNames, relativeTo: options.outputDir))
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        print("Signed bundles: \(options.outputDir.path)")
    }

    /// Accepts only the exact name or SHA-1 fingerprint of an available code-signing identity.
    static func signingIdentity(_ config: URL) throws -> String {
        let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let setting = try NSRegularExpression(pattern: #"^[ \t]*CODE_SIGN_IDENTITY[ \t]*=[ \t]*([^\r\n]*)$"#, options: .anchorsMatchLines)
        var identity = ""
        if let match = setting.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            identity = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if identity.isEmpty || identity == "-" || ["adhoc", "ad-hoc", "sign to run locally"].contains(identity.lowercased()) {
            throw Failure("Configure CODE_SIGN_IDENTITY in Signing.local.xcconfig with a code-signing identity from your keychain. See docs/development.md. Ad-hoc signing is not allowed.")
        }
        let listing = try run(["security", "find-identity", "-v", "-p", "codesigning"])
        guard listing.status == 0 else { throw Failure("Cannot list code-signing identities. See docs/development.md.") }
        let entry = try NSRegularExpression(pattern: #"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$"#)
        let available = listing.output.split(whereSeparator: \.isNewline).compactMap { line -> (fingerprint: String, name: String)? in
            let line = String(line)
            guard let match = entry.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let fingerprint = Range(match.range(at: 1), in: line), let name = Range(match.range(at: 2), in: line) else { return nil }
            return (String(line[fingerprint]), String(line[name]))
        }
        guard available.contains(where: { identity.caseInsensitiveCompare($0.fingerprint) == .orderedSame || identity == $0.name }) else {
            throw Failure("The configured code-signing identity is unavailable. See docs/development.md.")
        }
        return identity
    }

    /// Writes a staged bundle's Info.plist. The app bundle first gets the
    /// variant's compiled icon, which its Info.plist names; the fixture has none.
    static func writeInfo(into bundle: URL, name: String, identifier: String, executable: String, version: String, variant: String) throws {
        let app = executable == "TesselApp"
        let icon = app ? try compileAppIcon(variant: variant, into: bundle.appending(path: "Contents/Resources")) : [:]
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
            "CFBundleName": name, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": version,
            "LSMinimumSystemVersion": "27.0", "LSUIElement": app, "NSHighResolutionCapable": true,
        ].merging(icon) { current, _ in current }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
    }

    /// The Icon Composer source and app icon name for a build variant. The
    /// development icon differs, so the two builds are told apart in System Settings.
    static func appIcon(variant: String) -> (source: String, name: String) {
        variant == "dev" ? ("Sources/App/TesselDev.icon", "TesselDev") : ("Sources/App/Tessel.icon", "Tessel")
    }

    /// Compiles the variant's app icon into a bundle's Resources with actool and
    /// returns the Info.plist keys actool assigns to it. macOS 27 renders an
    /// Icon Composer icon natively; a legacy icns would be framed at small sizes.
    static func compileAppIcon(variant: String, into resources: URL) throws -> [String: String] {
        let icon = appIcon(variant: variant)
        let partial = FileManager.default.temporaryDirectory.appending(path: "tessel-icon-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: partial) }
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let result = try run(["xcrun", "actool", root.appending(path: icon.source).path, "--compile", resources.path,
                              "--app-icon", icon.name, "--enable-on-demand-resources", "NO", "--development-region", "en",
                              "--target-device", "mac", "--platform", "macosx", "--minimum-deployment-target", "27.0",
                              "--output-partial-info-plist", partial.path])
        guard result.status == 0, let keys = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: partial), format: nil)) as? [String: String],
              keys["CFBundleIconName"] == icon.name else {
            throw Failure("Compiling the app icon \(icon.source) failed.")
        }
        return keys
    }

    static func sources(in folder: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appending(path: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// Every build gets a distinct version, so a rebuild is a real signature change.
    static func buildStamp() -> String {
        var time = timeval()
        gettimeofday(&time, nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let date = Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
        return formatter.string(from: date) + String(format: "%06d", time.tv_usec)
    }

    /// Runs a tool found on PATH. Tests replace security, xcrun, and codesign there.
    static func run(_ command: [String], capture: Bool = true) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        if capture {
            process.standardOutput = output
            process.standardError = error
        }
        try process.run()
        guard capture else {
            process.waitUntilExit()
            return (process.terminationStatus, "", "")
        }
        // Drain both pipes at once so a full stderr buffer cannot block the tool.
        let errorData = Collected()
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) { errorData.data = error.fileHandleForReading.readDataToEndOfFile() }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reading.wait()
        return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData.data, as: UTF8.self))
    }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool]
        init(count: Int) { values = Array(repeating: false, count: count) }
        subscript(index: Int) -> Bool {
            get { lock.withLock { values[index] } }
            set { lock.withLock { values[index] = newValue } }
        }
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        var data: Data {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

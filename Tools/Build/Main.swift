import Foundation

/// Builds registrable, signed development bundles. Never falls back to ad-hoc signing.
@main
struct TesselBuild {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let usage = "Usage: tessel-build [--signing-config FILE] [--output-dir DIR] [--variant dev|daily]"

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

        init<Arguments: Sequence<String>>(_ arguments: Arguments) throws {
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                if argument == "-h" || argument == "--help" { print(usage); exit(0) }
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

        func compile(_ folder: String, to output: URL, extra: [URL] = []) throws {
            let command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-package-name", "tessel", "-O", "-target", "arm64-apple-macos27.0", "-o", output.path]
                + (["Sources/App", "Sources/CLI"].contains(folder) && options.variant == "dev" ? ["-D", "TESSEL_DEVELOPMENT"] : [])
            let policy = try folder == "Sources/App" ? sources(in: "Sources/Ports") + sources(in: "Sources/Policy") : []
            let inputs = try (common + policy + sources(in: folder) + extra).map(\.path)
            guard try run(command + inputs, capture: false).status == 0 else { throw Failure("Compilation of \(folder) failed.") }
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
        for bundle in bundles {
            let app = bundle.executable == "TesselApp"
            let path = stage.appending(path: bundle.name + ".app")
            let macOS = path.appending(path: "Contents/MacOS")
            try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
            try compile(bundle.folder, to: macOS.appending(path: bundle.executable), extra: bundle.extra)
            if app { try compile("Sources/CLI", to: macOS.appending(path: "tessel")) }
            let info: [String: Any] = [
                "CFBundleIdentifier": bundle.identifier, "CFBundleExecutable": bundle.executable,
                "CFBundleName": bundle.name, "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": stamp,
                "LSMinimumSystemVersion": "27.0", "LSUIElement": app, "NSHighResolutionCapable": true,
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: path.appending(path: "Contents/Info.plist"))
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

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        var data: Data {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

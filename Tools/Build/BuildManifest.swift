import CryptoKit
import Foundation

/// Stored only after a signed build succeeds. Content hashes make checkout
/// moves, added/deleted sources and replaced artifacts independent of mtimes.
struct BuildManifest: Codable, Equatable {
    let inputs: [String: String]
    let artifacts: [String: String]

    static func inputs(root: URL, signingConfig: URL, variant: String, compiler: String) throws -> [String: String] {
        var hashes = try files(in: ["Sources", "Tests/Fixture", "Tools/Build"], relativeTo: root)
        for path in ["Package.swift", "scripts/build"] {
            hashes[path] = try hash(Data(contentsOf: root.appending(path: path)))
        }
        hashes["signing-config"] = try hash(Data(contentsOf: signingConfig))
        hashes["variant"] = hash(Data(variant.utf8))
        hashes["compiler"] = hash(Data(compiler.utf8))
        return hashes
    }

    static func files(in directories: [String], relativeTo root: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for directory in directories {
            let base = root.appending(path: directory)
            let paths = try FileManager.default.subpathsOfDirectory(atPath: base.path).sorted()
            for path in paths {
                let file = base.appending(path: path)
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                hashes[directory + "/" + path] = try hash(Data(contentsOf: file))
            }
        }
        return hashes
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

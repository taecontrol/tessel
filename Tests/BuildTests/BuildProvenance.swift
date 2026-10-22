import Foundation
import Testing
@testable import Build

struct BuildProvenance {
    @Test("source provenance detects changed, added and deleted app, fixture and build inputs",
          arguments: ["Sources/App/Generic.swift", "Sources/Policy/Generic.swift", "Sources/Ports/Generic.swift", "Sources/CLI/Generic.swift", "Sources/Shared/Generic.swift", "Tests/Fixture/Generic.swift", "Tools/Build/Generic.swift", "scripts/build", "Package.swift", "Signing.local.xcconfig"])
    func changedInputsInvalidateBuild(_ path: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in ["Sources/App/Generic.swift", "Tests/Fixture/Generic.swift", "Tools/Build/Generic.swift", "scripts/build", "Package.swift", "Signing.local.xcconfig", path] {
            let url = directory.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original\n".utf8).write(to: url)
        }
        func inputs() throws -> [String: String] {
            try BuildManifest.inputs(root: directory, signingConfig: directory.appending(path: "Signing.local.xcconfig"), variant: "dev", compiler: "fixture compiler")
        }
        let original = try inputs(), file = directory.appending(path: path)
        try Data("changed\n".utf8).write(to: file)
        #expect(try inputs() != original, "changing \(path) must invalidate signed outputs")
        if path.hasSuffix(".swift"), path != "Package.swift" {
            try FileManager.default.removeItem(at: file)
            #expect(try inputs() != original, "deleting \(path) must invalidate signed outputs")
            try Data("original\n".utf8).write(to: file)
            try Data("new source\n".utf8).write(to: file.deletingLastPathComponent().appending(path: "Added.swift"))
            #expect(try inputs() != original, "adding a source must invalidate signed outputs")
        }
    }

    @Test("artifact provenance detects replaced or missing installed bytes")
    func replacedArtifactInvalidatesBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appending(path: "generic-artifact/executable")
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("revision A".utf8).write(to: artifact)
        let original = try BuildManifest.files(in: ["generic-artifact"], relativeTo: directory)
        try Data("revision B".utf8).write(to: artifact)
        #expect(try BuildManifest.files(in: ["generic-artifact"], relativeTo: directory) != original)
        try FileManager.default.removeItem(at: artifact)
        #expect(try BuildManifest.files(in: ["generic-artifact"], relativeTo: directory) != original)
    }
}

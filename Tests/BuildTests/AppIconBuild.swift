import Foundation
import Testing
@testable import Build

/// The app icon is compiled by the real actool from the repository's Icon
/// Composer sources; the system renders its result (#59 E6, E7 captures).
struct AppIconBuild {
    @Test("#59 E1: the daily build compiles its app icon into Assets.car and names it in Info.plist")
    func dailyBuildCompilesItsIcon() throws {
        try expectCompiledIcon(variant: "daily")
    }

    @Test("#59 E2: the development build carries its own icon variant under its own name")
    func developmentBuildCarriesItsOwnIcon() throws {
        let development = try expectCompiledIcon(variant: "dev")
        let daily = try expectCompiledIcon(variant: "daily")
        #expect(development != daily, "Tessel Dev must name a different icon than Tessel")
    }

    @Test("#59 E3: every file of both app icon sources is a build input")
    func iconSourcesAreBuildInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let signing = directory.appending(path: "Signing.local.xcconfig")
        try Data("CODE_SIGN_IDENTITY = Generic\n".utf8).write(to: signing)
        let inputs = try BuildManifest.inputs(root: TesselBuild.root, signingConfig: signing, variant: "dev", compiler: "fixture compiler")
        for variant in ["daily", "dev"] {
            let source = TesselBuild.appIcon(variant: variant).source
            let files = (try? FileManager.default.subpathsOfDirectory(atPath: TesselBuild.root.appending(path: source).path)) ?? []
            let regular = files.filter {
                (try? TesselBuild.root.appending(path: source + "/" + $0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            #expect(regular.contains("icon.json"), "\(source) must be an Icon Composer source")
            for file in regular {
                #expect(inputs[source + "/" + file] != nil, "changing \(source)/\(file) must invalidate signed outputs")
            }
        }
    }

    /// Compiles the variant's icon with the build tool's own step and returns its name.
    @discardableResult
    private func expectCompiledIcon(variant: String) throws -> String {
        let resources = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/Contents/Resources")
        defer { try? FileManager.default.removeItem(at: resources.deletingLastPathComponent().deletingLastPathComponent()) }
        let keys = try TesselBuild.compileAppIcon(variant: variant, into: resources)
        let name = try #require(keys["CFBundleIconName"], "Info.plist must name the app icon")
        let catalog = resources.appending(path: "Assets.car")
        try #require(FileManager.default.fileExists(atPath: catalog.path), "the bundle must carry Assets.car")
        let info = try TesselBuild.run(["xcrun", "assetutil", "--info", catalog.path])
        try #require(info.status == 0, "assetutil must read the compiled catalog")
        let entries = try #require(try JSONSerialization.jsonObject(with: Data(info.output.utf8)) as? [[String: Any]])
        let icons = entries.filter { $0["AssetType"] as? String == "Icon Image" && $0["Name"] as? String == name }
        #expect(!icons.isEmpty, "Assets.car must contain the app icon \(name)")
        return name
    }
}

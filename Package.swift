// swift-tools-version: 6.2
// Development tooling and internal libraries used only by tests. tessel-build
// compiles the libraries into the signed app; no SwiftPM product is the app.
import PackageDescription

let package = Package(
    name: "tessel-tools",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "tessel-build", targets: ["Build"]),
        .executable(name: "tessel-verify-selection", targets: ["VerifySelection"]),
    ],
    targets: [
        .executableTarget(name: "Build", path: "Tools/Build"),
        .executableTarget(name: "VerifySelection", path: "Tools/Verify"),
        .target(name: "Ports", path: "Sources/Ports", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .target(name: "Policy", dependencies: ["Ports"], path: "Sources", exclude: ["App", "CLI", "Ports", "Shared/IPC.swift"],
                sources: ["Policy", "Shared/Protocol.swift", "Shared/KeyChord.swift"],
                swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .testTarget(name: "PolicyTests", dependencies: ["Policy", "Ports"], path: "Tests/PolicyTests"),
    ]
    + (Context.environment["TESSEL_ACCEPTANCE"] == "1" ? [
        .testTarget(name: "Acceptance", path: "Tests/Acceptance", exclude: ["resource-budget.json", "switch-budget.json", "rails-budget.json"]),
    ] : [])
)

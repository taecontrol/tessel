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
        .executable(name: "tessel-check", targets: ["Check"]),
    ],
    targets: [
        .executableTarget(name: "Build", path: "Tools/Build"),
        .executableTarget(name: "VerifySelection", path: "Tools/Verify"),
        .target(name: "Ports", path: "Sources/Ports", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        // SwiftPM can find undeclared neighboring modules; restrict Policy's
        // compiler clients so Simulator cannot import it even after a build.
        .target(name: "Policy", dependencies: ["Ports"], path: "Sources", exclude: ["App", "CLI", "Ports", "Shared/IPC.swift"],
                sources: ["Policy", "Shared/Protocol.swift", "Shared/KeyChord.swift", "Shared/SocketDeadline.swift"],
                swiftSettings: [.enableUpcomingFeature("MemberImportVisibility"), .unsafeFlags(["-allowable-client", "PolicyTests"])]),
        .target(name: "Assumptions", path: "Tests/Assumptions"),
        .target(name: "Simulator", dependencies: ["Ports", "Assumptions"], path: "Tests/Simulator"),
        .testTarget(name: "PolicyTests", dependencies: ["Policy", "Ports", "Simulator", "Assumptions"], path: "Tests/PolicyTests"),
        .executableTarget(name: "Check", path: "Tools/Check"),
        .testTarget(name: "CheckTests", dependencies: ["Check"], path: "Tests/CheckTests"),
        .testTarget(name: "BuildTests", dependencies: ["Build"], path: "Tests/BuildTests"),
    ]
    + (Context.environment["TESSEL_ACCEPTANCE"] == "1" ? [
        .testTarget(name: "Acceptance", dependencies: ["Assumptions"], path: "Tests/Acceptance", exclude: ["resource-budget.json"]),
    ] : [])
)

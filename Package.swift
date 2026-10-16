// swift-tools-version: 6.2
// Development tools only. The app, CLI, and fixture are built and signed by
// tessel-build; a SwiftPM product must never be launched as the app.
import PackageDescription

let package = Package(
    name: "tessel-tools",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "tessel-build", targets: ["Build"])],
    targets: [
        .executableTarget(name: "Build", path: "Tools/Build"),
        .testTarget(name: "Acceptance", path: "Tests/Acceptance", exclude: ["resource-budget.json"]),
    ]
)

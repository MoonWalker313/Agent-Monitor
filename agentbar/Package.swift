// swift-tools-version:5.9
import PackageDescription

// Built with SwiftPM only (no Xcode project needed). `scripts/build-dmg.sh`
// assembles the .app bundle and .dmg from these products.
let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentBarCore", targets: ["AgentBarCore"]),
        .executable(name: "AgentBarApp", targets: ["AgentBarApp"]),
        .executable(name: "agentbar-cli", targets: ["AgentBarCLI"]),
        .executable(name: "agentbar-selftest", targets: ["AgentBarSelfTest"]),
    ],
    targets: [
        .target(name: "AgentBarCore"),
        .executableTarget(name: "AgentBarApp", dependencies: ["AgentBarCore"]),
        .executableTarget(name: "AgentBarCLI", dependencies: ["AgentBarCore"]),
        // Self-test runner instead of a test target: Swift Testing/XCTest need full Xcode,
        // and this project builds with Command Line Tools only. Run: swift run agentbar-selftest
        .executableTarget(name: "AgentBarSelfTest", dependencies: ["AgentBarCore"]),
    ]
)

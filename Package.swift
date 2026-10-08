// swift-tools-version: 6.2
import PackageDescription

// Core tests; build the app with Playdock.xcodeproj.
let package = Package(
    name: "PlaydockCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PlaydockCore", targets: ["PlaydockCore"])],
    targets: [
        .target(name: "PlaydockCore", path: "Sources/PlaydockCore"),
        .executableTarget(name: "PlaydockSteamIntegration", dependencies: ["PlaydockCore"], path: "Sources/PlaydockSteamIntegration", exclude: ["LICENSE", "NOTICE"]),
        .testTarget(name: "PlaydockSteamIntegrationTests", dependencies: ["PlaydockSteamIntegration"], path: "Tests/PlaydockSteamIntegrationTests"),
        .testTarget(name: "PlaydockCoreTests", dependencies: ["PlaydockCore"], path: "Tests/PlaydockCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)

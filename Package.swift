// swift-tools-version: 6.2
import PackageDescription

// Core tests; build the app with Wayfarer.xcodeproj.
let package = Package(
    name: "WayfarerCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WayfarerCore", targets: ["WayfarerCore"])],
    targets: [
        .target(name: "WayfarerCore", path: "Sources/WayfarerCore"),
        .executableTarget(name: "WayfarerSteamIntegration", dependencies: ["WayfarerCore"], path: "Sources/WayfarerSteamIntegration", exclude: ["LICENSE", "NOTICE"]),
        .testTarget(name: "WayfarerSteamIntegrationTests", dependencies: ["WayfarerSteamIntegration"], path: "Tests/WayfarerSteamIntegrationTests"),
        .testTarget(name: "WayfarerCoreTests", dependencies: ["WayfarerCore"], path: "Tests/WayfarerCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)

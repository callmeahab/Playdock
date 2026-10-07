// swift-tools-version: 6.2
import PackageDescription

// Core tests; build the app with Wayfarer.xcodeproj.
let package = Package(
    name: "WayfarerCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WayfarerCore", targets: ["WayfarerCore"])],
    targets: [
        .target(name: "WayfarerCore", path: "Sources/WayfarerCore"),
        .testTarget(name: "WayfarerCoreTests", dependencies: ["WayfarerCore"], path: "Tests/WayfarerCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 5.9
import PackageDescription

// The native app is built with Wayfarer.xcodeproj. This package provides fast core tests.
let package = Package(
    name: "WayfarerCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WayfarerCore", targets: ["WayfarerCore"])],
    targets: [
        .target(name: "WayfarerCore", path: "Sources/WayfarerCore"),
        .testTarget(name: "WayfarerCoreTests", dependencies: ["WayfarerCore"], path: "Tests/WayfarerCoreTests"),
    ]
)

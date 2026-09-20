// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GamekitCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GamekitCore", targets: ["GamekitCore"]),
    ],
    targets: [
        .target(name: "CProcessSupport"),
        .target(name: "GamekitCore", dependencies: ["CProcessSupport"], resources: [.copy("GameProfiles")]),
        .testTarget(name: "GamekitCoreTests", dependencies: ["GamekitCore"], path: "tests/GamekitCoreTests"),
    ]
)

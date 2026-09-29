// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mobdev",
    // Liquid Glass needs macOS 26.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Mobdev", targets: ["Mobdev"])
    ],
    dependencies: [
        // Over-the-air updates for release builds.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "MobdevCore"),
        .executableTarget(
            name: "Mobdev",
            dependencies: ["MobdevCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "MobdevCoreTests", dependencies: ["MobdevCore"]),
    ]
)

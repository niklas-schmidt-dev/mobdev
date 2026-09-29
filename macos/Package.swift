// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mobdev",
    // Liquid Glass needs macOS 26.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Mobdev", targets: ["Mobdev"])
    ],
    targets: [
        .target(name: "MobdevCore"),
        .executableTarget(name: "Mobdev", dependencies: ["MobdevCore"]),
        .testTarget(name: "MobdevCoreTests", dependencies: ["MobdevCore"]),
    ]
)

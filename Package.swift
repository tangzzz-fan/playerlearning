// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerStack",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        .library(name: "PlayerUI", targets: ["PlayerUI"])
    ],
    targets: [
        .target(name: "PlayerCore"),
        .target(name: "PlayerUI", dependencies: ["PlayerCore"]),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"]),
        .testTarget(name: "PlayerUITests", dependencies: ["PlayerCore", "PlayerUI"])
    ],
    swiftLanguageModes: [.v6]
)

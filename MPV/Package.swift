// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerMPV",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlayerMPV", targets: ["PlayerMPV"])
    ],
    dependencies: [
        .package(name: "PlayerStack", path: "..")
    ],
    targets: [
        .target(
            name: "PlayerMPV",
            dependencies: [
                .product(name: "PlayerCore", package: "PlayerStack"),
                .target(name: "Libmpv", condition: .when(platforms: [.iOS]))
            ]
        ),
        .binaryTarget(name: "Libmpv", path: "Library/Libmpv.xcframework")
    ],
    swiftLanguageModes: [.v6]
)

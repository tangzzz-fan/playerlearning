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
                // 适配器要能实现 UI 层的「视频表面」契约（`VideoSurface`），
                // 否则 `MPVRenderOutput` 没法被 `PlayerScreenView` 挂上去 ——
                // 只能由 App 层再包一层没有意义的垫片。
                .product(name: "PlayerUI", package: "PlayerStack"),
                .target(name: "Libmpv", condition: .when(platforms: [.iOS]))
            ]
        ),
        .testTarget(
            name: "PlayerMPVTests",
            dependencies: [
                "PlayerMPV",
                .product(name: "PlayerCore", package: "PlayerStack"),
            ],
            path: "Tests/PlayerMPVTests"
        ),
        .binaryTarget(name: "Libmpv", path: "Library/Libmpv.xcframework")
    ],
    swiftLanguageModes: [.v6]
)

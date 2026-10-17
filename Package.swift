// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerStack",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        .library(name: "PlayerUI", targets: ["PlayerUI"]),
        // `PlayerMPV` 在**根清单**里，不再是一个子目录包。
        // 原因：SPM 的 `url:` 依赖只解析仓库根的 `Package.swift`，子目录包对外部消费者不可见
        // —— 那会让这个仓库永远只能被 `path:` 引用（`docs/30` A1 / 实测证据 3）。
        .library(name: "PlayerMPV", targets: ["PlayerMPV"])
    ],
    targets: [
        .target(name: "PlayerCore"),
        .target(name: "PlayerUI", dependencies: ["PlayerCore"]),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"]),
        .testTarget(name: "PlayerUITests", dependencies: ["PlayerCore", "PlayerUI"]),
        .target(
            name: "PlayerMPV",
            dependencies: [
                "PlayerCore",
                "PlayerUI",
                // 只在 iOS 上链接 libmpv：xcframework 没有 macOS slice，
                // 而 `MPVKernel` 整份被 `#if canImport(Libmpv)` 圈住 ⇒ macOS 上是空模块（`P-096`）。
                .target(name: "Libmpv", condition: .when(platforms: [.iOS]))
            ],
            path: "MPV/Sources/PlayerMPV"
        ),
        .testTarget(
            name: "PlayerMPVTests",
            dependencies: ["PlayerMPV", "PlayerCore"],
            path: "MPV/Tests/PlayerMPVTests"
        ),
        // 开发期用 `path:`：产物 104 MB，不进版本库（`.gitignore:19`），
        // 由 `Tools/stage-libmpv.sh` 从构建目录落位。
        // 发布形态需换成 `.binaryTarget(name: "Libmpv", url:checksum:)`（`docs/30` §七）。
        .binaryTarget(name: "Libmpv", path: "MPV/Library/Libmpv.xcframework")
    ],
    swiftLanguageModes: [.v6]
)

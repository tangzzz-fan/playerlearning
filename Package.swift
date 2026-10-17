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
        // 发布形态：产物挂在 Release 上按 tag 取，checksum 固定。
        // 本机想改回本地产物时，把这一段换成
        //   .binaryTarget(name: "Libmpv", path: "MPV/Library/Libmpv.xcframework")
        // 两者只能二选一（SPM 没有条件式 binaryTarget）。取舍见 `docs/30` §八。
        .binaryTarget(
            name: "Libmpv",
            url: "https://github.com/tangzzz-fan/playerstack/releases/download/v0.1.1/Libmpv.xcframework.zip",
            checksum: "f98a0c3fa47f0a7cc7cb1c2d8160c892c3e584da478862dfa05a3c082caca0d6"
        )
    ],
    swiftLanguageModes: [.v6]
)

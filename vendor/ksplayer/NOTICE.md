# NOTICE — vendor/ksplayer

本目录是 **KSPlayer 的只读学习副本（vendor）**，不是本项目的代码。用途：本地阅读与全文检索。

## 来源与版本

| 项 | 值 |
| --- | --- |
| 上游仓库 | `git@github.com:kingslay/KSPlayer.git` |
| 冻结版本 | branch `main` · commit `01dba1317f74a5eee402958092bb0aa19124bafd`（2026-10-10） |
| `git describe` | `2.3.4-71-g01dba13` |
| 上游最新 tag | `2.3.4` |
| 版权 | 归原作者 `kintan` / `kingslay` 及贡献者所有 |
| 许可 | **GPL**（见本目录 `LICENSE`） |

> 上游 `main` 是滚动分支。本副本**冻结在上述 commit**，与 `docs/01` 的评估快照一致；未做任何源码修改。

## ⚠️ 许可影响

把 GPL 代码放进本仓库，意味着**本仓库的 `vendor/` 部分受 GPL 约束**。

- **当前（自用、不对外分发）**：无实际影响。
- **若将来要分发本仓库**：必须重新评估 —— 要么移除 `vendor/`，要么整体遵守 GPL。
- 本副本**不是**"我们的代码"，任何对外产物都不应链接或引用它。

## 保留了什么，为什么

| 路径 | 体积 | 保留理由 |
| --- | --- | --- |
| `Sources/KSPlayerUI/**` | 476 K | UI 层全部开源，是**唯一能读到的完整实现**（29 文件；含 SwiftUI / UIKit / AppKit 三套） |
| `Sources/MPVPlayer/**` | 128 K | libmpv 内核接入的参考实现（`wid` 嵌入 + mpv 选项配置） |
| `Documents/KSPlayer原理详解.md` | 7.5 K | 作者自述的架构与并发模型，**价值最高的一份文档** |
| `Documents/AVPlayer踩坑记.md` | 3.8 K | 平台踩坑记录 |
| `Tests/KSPlayerUITests/KSPlayerResourceTest.swift` | 8 K | 全仓库唯一的测试文件（Swift Testing 风格参考） |
| `Package.swift` | 3.1 K | 依赖与目标定义；子模块演进的证据（`package(path:)` 条件分支） |
| `README.md` / `README_CN.md` | 20 K | GPL/LGPL 模块对照表、付费特性清单、交互约定 |
| `LICENSE` | 35 K | **必须保留**（GPL） |
| `.swiftformat` / `.spi.yml` | 191 B | 工程卫生基线 |

## 剔除了什么，为什么

| 路径 | 原体积 | 剔除理由 |
| --- | --- | --- |
| `Sources/KSPlayer.xcframework/**` | **99 M** | 闭源二进制，**学不到任何东西**；其 slice 构成已在 `docs/01` §2.2 完整记录（3 个 slice：`ios-arm64_x86_64-simulator` / `macos-arm64_x86_64` / `tvos-arm64`，**无 `ios-arm64` 真机**） |
| `Demo/**` | 7.6 M | 其中 `demo.gif` 7.1 M；其余为 asset catalog 与 Xcode 工程，非学习必要 |
| `Documents/*.png`（1/2/3/6） | 1.1 M | 架构图；`KSPlayer原理详解.md` 内已以 GitHub raw URL 引用，无需本地副本 |
| `Documents/未命名.key` | 542 K | Keynote 源文件 |
| `Documents/Sponsors.jpg` | 139 K | 赞助商图 |
| `Documents/PrivacyPolicy.md`、`Terms.md`、`privacy.html`、`terms.html` | 28 K | App Store 上架合规材料，与学习目标无关 |
| `.gitmodules` | 0 B | **0 字节历史残留**（子模块 `FFmpegKit` 已于 2024-10-22 由 `4e3bf3e` 删除，考证见 `docs/01` 第六章） |
| `.DS_Store`、`.workbuddy/` | — | 本机与工具产物 |
| `.github/` | — | 上游 CI 配置（本次副本未包含；其内容要点已记入 `docs/01` §5 P2） |

剔除后体积：**109 M → 692 K**（约 1/160）。

## 不可构建声明

**本副本不能编译，这是刻意的。** 原因：

1. `Package.swift` 的 `.binaryTarget` 指向已剔除的 `Sources/KSPlayer.xcframework`；
2. `KSPlayerUI` / `MPVPlayer` 依赖该闭源二进制里的类型 —— `MetalView`、`KSPlayerLayer`、`KSPlayerLayerDelegate`、`KSOptions`、`MediaPlayerProtocol`、`DynamicInfo`、`KSLog`（证据见 `docs/01` §2.2）。

也就是说：**这里只有 13,920 行可读代码 + 文档，没有可运行的产物。** 需要可运行的参考时，请另建目录做完整 clone：

```bash
git clone --depth 1 git@github.com:kingslay/KSPlayer.git /tmp/ksplayer-full
```

（注意：完整 clone 约 109 M，其中 99 M 是那个二进制。）

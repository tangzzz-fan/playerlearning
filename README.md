# playerlearning

做一个**自己的 iOS 优先 / macOS 跟进播放器**：libmpv 单内核，本地文件 + 网络点播 + 直播全都要，能播系统播放器播不了的格式（mkv / ASS 特效字幕 / 各种编码）。

**当前状态**：**Phase 0 与 Phase 1 均已完成** —— **`G0`/`M0`（路线成立）** 与 **`G1`/`M1`（地基可测）** 达成。

| 里程碑 | 状态 |
| --- | --- |
| M0 路线成立 | ✅ 已产出**自建动态 LGPL-2.1 libmpv 产物**，模拟器与真机（iPhone 16 Pro）双通出画面 |
| M1 地基可测 | ✅ 内核边界已立（`PlayerKernelProtocol` / 注册表 / `FakeKernel` / 状态机 / 时间模型）· **84 tests 全绿** · 变异 **27/27** 杀死 · `PlayerCore` 零 UI 依赖 |
| M2 能看片 | ⬅ **进行中**（Phase 2：`MPVKernel` 生命周期 + 事件循环 ✓ · `wid` 视频表面 ✓ · **装配层 `PlayerController` ✓** · 下一步真画面） |

门禁：`./Tools/gate.sh`（退出码 0 = `G1` 达成）。

## 文档索引

| 文档 | 内容 | 何时读 |
| --- | --- | --- |
| [`docs/01-KSPlayer-设计思想与整体评估.md`](docs/01-KSPlayer-设计思想与整体评估.md) | 设计思想 8 条 + 长处 9 条 + 短处 15 条 + submodule 考证 + 整体判断 + §2.4 授权传导源 | **先读这份**，建立全局认识 |
| [`docs/02-自建播放器决策记录.md`](docs/02-自建播放器决策记录.md) | 11 条决策、逐条理由与被否方案、**§三 分发口径**、显式放弃清单、施工硬约束 10 条 | 动手前读，作为施工约束 |
| [`docs/03-路线图.md`](docs/03-路线图.md) | Phase 0–7 拆解、判定门 G0–G7、横切事项、里程碑定义、未定项与决策回访点 | 按 ticket 推进 |
| [`docs/04-开工前准备清单.md`](docs/04-开工前准备清单.md) | 环境体检实测、P0 ticket 表、决策项 D1–D5、风险登记 R1–R5 | 开工前必读 |
| [`docs/05-libmpv产物实测报告.md`](docs/05-libmpv产物实测报告.md) | `P0-T4`：上游产物的许可实测（发现其落在 LGPLv3） | 需要许可结论时 |
| [`docs/06-P0-T5a技术验证报告.md`](docs/06-P0-T5a技术验证报告.md) | `P0-T5a`：`wid` + MoltenVK 技术验证（模拟器 + 真机双通） | `P2` 接入前 |
| [`docs/07-P0-T5b验证报告.md`](docs/07-P0-T5b验证报告.md) | `P0-T5b`：**自建动态 LGPL-2.1 产物**（`G0` 达成）· 许可证据链 · 端到端 | 需要产物规格时 |
| [`docs/08-P1验证报告.md`](docs/08-P1验证报告.md) | `P1`：骨架与内核抽象 · **`G1` 达成** · 交付物清单 · 集成测试抓到的缺陷 | 进 Phase 2 前 |
| [`docs/09-P2就绪度分析与票面修正.md`](docs/09-P2就绪度分析与票面修正.md) | `P2` 开工前复核：**票面缺装配层的证据** · `MPVKernel` 六项缺陷 · 两处拍板决策 · `G2` 口径细化 | **当前阶段的必读** |
| [`docs/PITFALLS.md`](docs/PITFALLS.md) | **踩坑日志**（现象 → 根因 → 处置 → 防再犯），现有 **33 条**（`P-001`–`P-033`），末段为**跨项目移植区**（来源 Marquee / HabitLoop / meta 待回流清单） | **动手前扫一遍**，能省掉重复排查 |

## 工程结构

```
Package.swift            ← 根包 PlayerStack：PlayerCore / PlayerUI 双 target（iOS 17 / macOS 14 / Swift 6）
Sources/
├── PlayerCore/          ← 内核边界与状态机（⛔ 禁止 import SwiftUI / UIKit / AppKit）
└── PlayerUI/            ← SwiftUI 视图层
Tests/PlayerCoreTests/   ← 纯逻辑单测 + 集成测试（跑在 macOS）
Tools/                   ← gate.sh（G1 门禁）· mutation_check.py · stage-libmpv.sh
MPV/                     ← ⚠️ 独立包 PlayerMPV：libmpv 适配器（只在 iOS 上编译，见下）
Demo/                    ← app shell（project.yml → xcodegen 生成，产物不入仓）
```

```bash
./Tools/gate.sh                        # G1 门禁：零 UI import + build + test + 变异（退出 0 即通过）
swift build && swift test              # 只跑根包（⚠️ 受限 shell 需加 --disable-sandbox，gate.sh 会自动判断）
python3 Tools/mutation_check.py        # 只跑变异闸门（--restore 可还原被就地改动的源文件）
cd Demo && xcodegen generate           # 生成 app 工程（.xcodeproj 不入 git）
xcodebuild -project Demo/PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
  -destination 'generic/platform=iOS Simulator' build

./Tools/stage-libmpv.sh                # ⚠️ 构建 MPV 包前必须先跑（产物 104 MB，gitignored）
cd MPV && xcodebuild -scheme PlayerMPV -destination 'platform=iOS Simulator' build
```

> ⚠️ **测试一律用 Swift Testing**（`@Test` / `#expect` / `try #require`），**不使用 XCTest**。触及 `CAMetalLayer` 的套件须显式 `@Suite(.serialized)`（并行是默认）。
> ⚠️ **`Demo/project.yml` 必须显式声明 `schemes:`** —— xcodegen **默认不生成** scheme，没有它 `xcodebuild -scheme` 与 CI 全不可用（见 `P-030`）。

> ⚠️ **`PlayerCore` 里出现 `import SwiftUI` / `UIKit` / `AppKit` 即视为违规** —— 这是 `G1` 判定门的一条硬线，破了就永久失去可测性。
> ⚠️ **根包不得引用 libmpv** —— 适配器只在 `MPV/` 独立包内。原因：自建产物**只有 iOS 切片**，而 SPM 会校验 `binaryTarget` 路径存在性（与平台条件无关）⇒ 一旦放进根包，**新克隆的 `swift test` 必失败**。
> ⚠️ **以 `AsyncStream` 为边界的测试必须能"收尾 + 排空 + 断言 nil"**，否则只会"过"或"挂死"（见 `docs/PITFALLS.md` `P-014`）。
> ⚠️ **每个"边界 + 消费者"的组合必须有集成测试** —— 单元测试全绿不等于部件能组合（见 `P-018`）。

## 目录结构

```
playerlearning/
├── docs/                  ← 我们的分析与决策（本仓库自己的产出）
│   ├── 01…07-*.md
│   └── assets/            ← 验证证据截图（p0t5a/ · p0t5b/）
├── spike/                 ← 一次性验证工程（不参与产品构建）
│   ├── p0-t5a-libmpv-smoke/        ← wid + MoltenVK 冒烟
│   └── p0-t5b-lgpl-dynamic-build/  ← 自建动态 LGPL 产物的构建方式
└── vendor/
    └── ksplayer/          ← KSPlayer 的只读学习副本（GPLv3，非我们的代码）
        ├── NOTICE.md      ← 来源 / 版本 / 许可 / 剔除说明 / 不可构建声明（先读）
        ├── Sources/       ← KSPlayerUI + MPVPlayer（13,920 行）
        ├── Documents/     ← 原理详解 + AVPlayer踩坑记
        └── ...
```

> **`spike/` 与产品代码的边界**：`spike/` **不参与产品构建**、不是产品代码；产品骨架在 Phase 1 新建 `PlayerCore` / `PlayerUI` 双 target。产物二进制（104 MB）**不入 git**，由脚本产出。

## 参考源

| 项 | 值 |
| --- | --- |
| 上游仓库 | `git@github.com:kingslay/KSPlayer.git` |
| 评估快照 | branch `main` · HEAD `01dba13`（2026-10-10） · `git describe = 2.3.4-71-g01dba13` |
| 授权 | **GPLv3**（默认，免费）/ LGPL（付费）/ 商业另行授权 |

> 评估结论绑定上述 commit。上游 `main` 是滚动分支，若后续拉取新版本，`docs/01` 中标注为「快照事实」的数字需要重新核对。

## ⚠️ 许可提示

### `vendor/ksplayer/`（参考副本）

`vendor/ksplayer/` 是 **GPLv3** 代码。把它放进本仓库意味着**本仓库的 `vendor/` 部分受 GPL 约束**。

- **只发 `docs/` 不发 `vendor/` ⇒ 无影响。**
- 本项目**要上架 App Store**（`docs/02` A1 已于 2026-10-13 反转），因此：
  - ❌ **不得把它的代码文本抄进产品代码**（原「自用不分发 ⇒ 可放心借鉴」的理由已失效）；
  - ✅ 只可借**设计思想与抽象**；
  - 若对外分发本仓库：需移除 `vendor/`，或整体遵守 GPL。
- 本副本**不是**我们的代码，任何对外产物都不应链接或引用它。

### 我们自己的产物（libmpv）

产物为自建 **LGPL-2.1** 动态 framework。三个必须记住的点：

1. **定义可上架性的不是「用了 libmpv」，而是「LGPL 构建 + 动态链接」**这两个条件。
2. **要交的是「对应源码 + 构建方式」** —— 构建方式已归档在 `spike/p0-t5b-lgpl-dynamic-build/`。
3. ⚠️ **iOS 上「用户可替换库」实质不成立**（App 由 Apple 联合签名 + FairPlay 加密）⇒ 只能**尽力合规**，对外不得宣称「已确保合规」。**唯一真实风险来源是上游 contributor 投诉**（VLC 2011 先例），不是 Apple 审核。

> 完整判定树与红线见 [`docs/02` §三「分发口径」](docs/02-自建播放器决策记录.md)。

## 下一步

进 **Phase 2 · libmpv 适配器**。票面已由 [`docs/09`](docs/09-P2就绪度分析与票面修正.md) 修正为九张（原三张），判定门 **`G2`**：本地 mkv **出画 + 出声 + `seek` 落点精确 + `./Tools/gate.sh` 退出 0**。

| ticket | 内容 | 状态 |
| --- | --- | --- |
| `P2-T0` | 模块拓扑：libmpv 适配器独立成包 `MPV/` | ✅ |
| `P2-T1` | `MPVKernel` 生命周期 + 事件循环 | ✅（编译层） |
| `P2-T2` | `VideoOutputProtocol` + `WindowEmbedOutput`（`wid`） | ✅ |
| `P2-T3` | **装配层 `PlayerController`** —— 内核事件流的唯一消费者 + 扇出 | ✅（同日完成测试框架迁移 → Swift Testing、xcodegen scheme、门禁管道修复） |
| `P2-T4` | `PlayerKernelSnapshot` 加 `naturalSize`（跨层，与 T5 同批） | ⬅ **下一步** |
| `P2-T5` | 属性映射补全 + `pause` 改 observe（取消乐观 emit） | 待开始 |
| `P2-T6` | `END_FILE` 区分错误 → `.failed` | 待开始 |
| `P2-T7` | `attach` 时序收口 + wakeup 回调 `passRetained` | 待开始 |
| `P2-T8` | 播放控制 + `seek` 用 `absolute+exact`（钳制归装配层） | 待开始 |
| `P2-T9` | `MPV/` 包纳入门禁（test target + `gate.sh` 条件步骤） | 待开始 |
| `P2-T10` | Demo 接入 `PlayerMPV` 包（端到端硬前置） | 待开始 |
| `P2-T11` | 端到端 + 性能基线 + `docs/10` + `G2` 固化 | 待开始 |

**可直接复用的既有成果**：产物接入方式与已验证配置见 [`docs/06`](docs/06-P0-T5a技术验证报告.md) / [`docs/07`](docs/07-P0-T5b验证报告.md)；`spike/p0-t5b-lgpl-dynamic-build/verify/` 就是一份能跑通的接线样板。

> **范围锚点是 M3（"能顺手用"）**：任何不推进 M3 的需求都往后排。

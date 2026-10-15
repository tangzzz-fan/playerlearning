# playerlearning

做一个**自己的 iOS 优先 / macOS 跟进播放器**：libmpv 单内核，本地文件 + 网络点播 + 直播全都要，能播系统播放器播不了的格式（mkv / ASS 特效字幕 / 各种编码）。

**当前状态**：**Phase 0 ~ Phase 4 均已完成**（`G0`/`M0` · `G1`/`M1` · `G2`/`M2` · `G3` · `G4`）；**Phase 5（网络点播）进行中**：`P5-T1`/`P5-T2` 完成，`G5` 未判定（缺可控弱网）。真机（iPhone 16 Pro）已跑通。

| 里程碑 | 状态 |
| --- | --- |
| M0 路线成立 | ✅ 自建动态 LGPL-2.1 libmpv 产物，模拟器与真机（iPhone 16 Pro）双通出画面 |
| M1 地基可测 | ✅ 内核边界已立（`PlayerKernelProtocol` / 注册表 / `FakeKernel` / 状态机 / 时间模型）· `PlayerCore` 零 UI 依赖 |
| M2 能看片 | ✅ 出画 + 出声 + `seek` 精确 + 播完报 `.finished`（[`docs/10`](docs/10-P2验证报告.md)） |
| M3 能顺手用 | **◑**：① **真机校准 ✅**（真机首屏出声出画 ≈0.20 s；模拟器那个 1.97 s 是 MoltenVK 管线编译的代价，**与音轨无关，真机未复现**）② 真机长跑**只跑了 ≈3 min/18 轮**（阶梯后持平，无泄漏迹象，但**不据此推断 30 min**）③ 字幕菜单真机手势仍待手测 |
| 端到端素材 | **Sintel trailer 720p（CC BY · 1280×720 · 48 kHz 立体声 · 52 s）**运行时下载，另有 W3C 镜像与 MDN `flower` 两级备用；离线退回本地生成；**用哪一个是哪个会打印出来** |

**验收标准就一条：项目能正确运行，`swift test` 全绿**（命令见下）。

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

**验收标准就一条：项目能正确运行，`swift test` 全绿。**

```bash
# ① 根包（纯逻辑，日常就是它）
swift build && swift test              # ⚠️ 受限 shell 需加 --disable-sandbox（见下）

# ② MPV 包（libmpv 适配器，只编译 iOS）
./Tools/stage-libmpv.sh                # 产物 104 MB 且 gitignored ⇒ 换设备后**必须先跑一次**
cd MPV && xcodebuild -scheme PlayerMPV -destination 'platform=iOS Simulator' build

# ③ Demo app（手动跑起来看效果）
cd Demo && xcodegen generate           # 新增源文件后必须重跑（P-030）；.xcodeproj 不入 git
xcodebuild -project PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
  -destination 'platform=iOS Simulator' build

# ④ 播放控制回归（`-exerciseControls` 跑「加载 → 播 → 停 → 再播」，逐拍打点）
xcrun simctl launch --console <udid> com.playerstack.demo -exerciseControls -traceUpdates
#   ⇒ [exercise] loaded→playing / stopped→idle / replayed→playing
#   ⚠️ 它证明"控制链路 + 内核语义"是通的；**不能**证明手指有没有点到按钮上 ——
#      点击本身无法自动化（UI 测试已按决定移除），那件事只能真机手测。

# ⑤ 长跑稳定性（每轮走完 load→play→seek→pause→play→stop，逐轮打点内存）
xcrun simctl launch --console <udid> com.playerstack.demo -soakRounds 30
#   ⇒ [soak] round N/30 · t=… · footprint=… MB · state=idle
#   180 轮 ≈ 30 min（`M3` 门槛那个量级）。判据：**单调线性 = 泄漏；阶梯后持平 = 预热**。

# ⑤b **播完 → 再点播放**（`-exerciseFinish`，走与按钮完全相同的 action）
xcrun devicectl device process launch --device <真机 UDID> --console \
  --terminate-existing com.playerstack.demo -- -exerciseFinish -traceUpdates
#   ⇒ [finish] 播到末尾 → state/位置/进度 · 等 2 秒后 → … · 点播放 3 秒后 → …
#   ⚠️ 它证明的是**按钮按下之后**那段。重播必须走 `finished → preparing → readyToPlay → playing`；
#      界面停在 finished 就说明那条边没报（见 P-053）。

# ⑥ 网络点播验证（**必须用支持 Range 的服务器**，见 P-052）
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2     # 一个终端
xcrun simctl launch --console <udid> com.playerstack.demo \
  -directURL http://127.0.0.1:8765/sintel_trailer-720p.mp4 -traceUpdates
#   ⚠️ 别用 `python -m http.server`：它不支持 Range ⇒ mp4 会"14 毫秒就播完"，
#      那是**环境缺口**而不是产品缺陷。`-traceUpdates` 会同时打开**内核自己的日志**。

# ⑦ 真机（iPhone 16 Pro）
cd Demo && xcodegen generate
xcodebuild -project PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
  -destination 'id=<真机 UDID，用 xcrun devicectl list devices 现查>' \
  -derivedDataPath DD-Device build
xcrun devicectl device install app --device <UDID> \
  DD-Device/Build/Products/Debug-iphoneos/PlayerStackDemo.app
#   ⚠️ `Demo/project.yml` 的 `DEVELOPMENT_TEAM` 必须是 **UKXWZ3FS84**（本机真实团队）。
#      写成别的会报 `No profiles for 'com.playerstack.demo'`，而那条报错**会把你带去查账号** ——
#      本机已有 Xcode 通配描述文件 + 钥匙串里的 `Apple Development` 证书，**不需要登 Apple ID**。
#   ⚠️ 真机上的 `--console` 需要 `--` 把参数与 devicectl 自己的选项隔开（否则 `-traceUpdates`
#      会被解析成 devicectl 的 `-t`）。
```

> **构建/测试环境（沙箱逃逸、挑模拟器、toybox shim）用现成的技能，别在项目里再包一层：**
> `bash ~/.workbuddy/skills/macos-build-test/scripts/macos-run.sh probe` （SwiftPM / macOS）
> `bash ~/.workbuddy/skills/ios-build-test/scripts/ios-run.sh probe` （iOS 模拟器 / 真机）
> 两个脚本会自动补逃逸参数、自动挑可用模拟器、把日志落文件只回打关键行。
> 换设备先跑 `bash ~/.workbuddy/skills/install.sh`（实体随 Marquee 仓库走）。

> ⚠️ **测试一律用 Swift Testing**（`@Test` / `#expect` / `try #require`），**不使用 XCTest**。触及 `CAMetalLayer` 的套件须显式 `@Suite(.serialized)`（并行是默认）。
> ⚠️ **`Demo/project.yml` 必须显式声明 `schemes:`** —— xcodegen **默认不生成** scheme，没有它 `xcodebuild -scheme` 与 CI 全不可用（见 `P-030`）。

> ⚠️ **`PlayerCore` 里出现 `import SwiftUI` / `UIKit` / `AppKit` 即视为违规** —— 破了就永久失去可测性（KSPlayer 的教训），这是一条**架构约束**，与有没有自动门禁无关。
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

## 各阶段完成情况（Phase 0 ~ 4）

| Phase | 判定门 | 结果 |
| --- | --- | --- |
| 0 风险排除 | `G0` / `M0` | ✅ 自建动态 LGPL-2.1 `Libmpv.xcframework`，模拟器 + 真机双通出画面 |
| 1 骨架与抽象 | `G1` / `M1` | ✅ `PlayerKernelProtocol` / 注册表 / `FakeKernel` / 状态机 / 时间模型；`PlayerCore` 零 UI 依赖 |
| 2 内核接入 | `G2` / `M2` | ✅ 出画 + 出声 + `seek` 精确 + 播完报 `.finished`（[`docs/10`](docs/10-P2验证报告.md)） |
| 3 UI 最小闭环 | `G3` | ✅ 播放/暂停 · 时间 · 进度条+拖拽 · 全屏 · 字幕开关 · 文件选择（[`docs/11`](docs/11-P3验证报告.md)） |
| 4 字幕 | `G4` | ✅ SRT 中文不乱码 · ASS 能加载渲染 · 字幕延迟可调（[`docs/03`](docs/03-路线图.md) 的 📌） |
| 5 网络点播 | `G5` | ◑ `P5-T1`/`P5-T2` 完成（真机直连 http → playing）· `G5` 未判定（缺可控弱网） |
| 6 直播 | `G6` | ⬜ 未定（见 `docs/03` §5） |
| 7 macOS | `G7` | ⬜ 未开始 |

## 下一步

**先还 `M3` 的欠账**（不做新功能）：

1. **真机校准** —— 音轨使模拟器首屏 60 ms → 1.97 s，**模拟器的数字不可信**；真机上量一遍再说要不要优化。
2. **手动长跑 30 min** —— 看内存是否增长、音频输出是否掉线（`G2` 只跑过 5 秒）。
3. **字幕菜单在真机上手势可用性** —— 菜单项多时是否可滚动、延迟按钮是否够大。

之后进 **Phase 5 · 网络点播**。

> **范围锚点是 M3（"能顺手用"）**：任何不推进 M3 的需求都往后排。

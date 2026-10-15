# playerlearning

做一个**自己的 iOS 优先 / macOS 跟进播放器**：libmpv 单内核，本地文件 + 网络点播 + 直播全都要，能播系统播放器播不了的格式（mkv / ASS 特效字幕 / 各种编码）。

**当前状态**：**Phase 0–5 均已交付** · **`M3` 达成**（真机校准 ✅ · 长跑经拍板取消 · 字幕菜单真机手势 ✅） · **Phase 7（macOS）`P7-T1` 完成**（`G7` 达成）。
**`G5` 三项已判定**（真机**可控弱网**：不崩 / 有缓冲提示 / 恢复后自动继续 —— [`docs/12`](docs/12-P5验证报告.md)）；
§二 口径里的「可切清晰度」（`P5-T5`）**设计前提已答**（= 视频轨道切换，见 [`docs/14`](docs/14-P5-T5-HLS多码率调研.md)），
但**尚未实现** ⇒ **`Phase 5` 仍不宣告关闭**。
**直播源环境已补**（`mediamtx` + `ffmpeg`，一次性动作、不入仓库）⇒ **`P6-T1` 的播放端已在真机证通**（RTSP 真机 `playing`，见 [`docs/14`](docs/14-P5-T5-HLS多码率调研.md)）。
真机已跑通 —— 两套环境各一台：家里 iPhone 16 Pro（`UKXWZ3FS84`）· 本机 Tang的iPhone（`3GMJYX32U9`），口径见 §⑦。

| 里程碑 | 状态 |
| --- | --- |
| M0 路线成立 | ✅ 自建动态 LGPL-2.1 libmpv 产物，模拟器与真机（iPhone 16 Pro）双通出画面 |
| M1 地基可测 | ✅ 内核边界已立（`PlayerKernelProtocol` / 注册表 / `FakeKernel` / 状态机 / 时间模型）· `PlayerCore` 零 UI 依赖 |
| M2 能看片 | ✅ 出画 + 出声 + `seek` 精确 + 播完报 `.finished`（[`docs/10`](docs/10-P2验证报告.md)） |
| M3 能顺手用 | ✅ **达成**：① 真机校准 ✅（真机出声出画 ≈0.20 s；模拟器那个 1.97 s 是 MoltenVK 管线编译的代价，**与音轨无关，真机未复现**）② 长跑**经董事长拍板取消**（不做长时任务；已跑的 ≈3 min/18 轮如实保留）③ 字幕菜单真机手势**经董事长实测确认可用** |
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
| [`docs/09-P2就绪度分析与票面修正.md`](docs/09-P2就绪度分析与票面修正.md) | `P2` 开工前复核：**票面缺装配层的证据** · `MPVKernel` 六项缺陷 · 两处拍板决策 · `G2` 口径细化 | 需要 `P2` 决策依据时 |
| [`docs/12-P5验证报告.md`](docs/12-P5验证报告.md) | `P5`：真机局域网链路 · **`G5` 三项判定**（可控弱网 45 KB/s）· 请求头端到端证据 · 未覆盖项 | 需要网络点播证据时 |
| [`docs/13-P6-T0调研.md`](docs/13-P6-T0调研.md) | `P6-T0`：**产物已带 RTSP/RTMP**（运行时探针证据）· 无参考实现可抄 · 低延迟候选选项 · **缺什么才能验** | 进 `Phase 6` 前 |
| [`docs/14-P5-T5-HLS多码率调研.md`](docs/14-P5-T5-HLS多码率调研.md) | `P5-T5` 设计前提（**HLS 多码率 = N 条 video track，切清晰度 = 设 `vid`**）· 三档源造法 · **RTSP 真机打通证据** · 直播 `duration` 语义差异 | 做可切清晰度 / 直播前 |
| [`docs/PITFALLS.md`](docs/PITFALLS.md) | **踩坑日志**（现象 → 根因 → 处置 → 防再犯），现有 **58 条**（`P-001`–`P-058`），末段为**跨项目移植区**（来源 Marquee / HabitLoop / meta 待回流清单） | **动手前扫一遍**，能省掉重复排查 |

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

# ⑥b 请求头注入验证（`P5-T4`，验证自定义 HTTP 头能正确发送）
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2 --echo-headers  # 服务器回显请求头
xcrun simctl launch --console <udid> com.playerstack.demo \
  -directURL http://127.0.0.1:8765/sintel_trailer-720p.mp4 \
  -headers "X-Player-Test: yes,User-Agent: CustomUA/2.0" -traceUpdates
#   查服务器日志（stderr）看到 `X-Player-Test: yes` 与 `User-Agent: CustomUA/2.0` ⇒ 注入生效
#   格式：`Key: Value`（逗号分隔多个头），刻意与 mpv 的 `http-header-fields` 一致

# ⑥c **真机弱网判定**（`G5`：不崩 / 有缓冲提示 / 恢复后自动继续）—— 见 docs/12
#   ⚠️ 真机不能用 127.0.0.1：手机在另一台设备上 ⇒ 服务器要绑 0.0.0.0，URL 用宿主的局域网地址。
#   ⚠️ 也不要加 -traceUpdates：mpv 的 verbose 日志会把 devicectl --console 打爆，
#      日志**在第 2 秒就断流**，看起来像"播不动"（`P-058`）。判定用每秒一条的 `[status]`。
MACIP=$(ipconfig getifaddr en1 || ipconfig getifaddr en0)          # 本机局域网地址
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2 --host 0.0.0.0 --throttle 45000
xcrun devicectl device process launch --device <真机 UDID> --console \
  --terminate-existing com.playerstack.demo -- -directURL http://$MACIP:8765/sintel_trailer-720p.mp4
#   ⇒ 每秒一行：`[status] … state=playing t=…/… progress=… buffering=true|false …`
#   判据：state 始终 playing（不崩）· buffering 反复翻转（有提示）· t 在停住之后自行推进（自动继续）
#   参考值：720p 实时需 ≈146 KB/s；限到 45 000 B/s ⇒ 供给只有需求 1/3，缓存必然反复耗尽。
#   `--stall-at/--stall-for` 可造"挂住 N 秒再继续"（更长断网的恢复能力，尚未测）。

# ⑦ 真机（⚠️ 两套 Xcode 环境、两个 team ⇒ 构建时**命令行覆盖**，不改仓库）
#   环境 A · 家里：team UKXWZ3FS84 · 真机 Tango / iPhone 16 Pro
#   环境 B · 本机：team 3GMJYX32U9 · 真机 Tang的iPhone      ← `project.yml` 里写的是 A 的值
cd Demo && xcodegen generate
xcodebuild -project PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
  -destination 'id=<真机 UDID，用 xcrun devicectl list devices 现查>' \
  DEVELOPMENT_TEAM=3GMJYX32U9 \
  -derivedDataPath DD-Device-32U9 build
xcrun devicectl device install app --device <UDID> \
  DD-Device-32U9/Build/Products/Debug-iphoneos/PlayerStackDemo.app
#   ⚠️ 覆盖值必须同时对上两件事：**本机钥匙串里带私钥的 `Apple Development` 证书**
#      （本机 = `3GMJYX32U9` · `Tang Tango (WU37464V73)`）与**覆盖该设备的通配描述文件**。
#      对不上会报 `No profiles for 'com.playerstack.demo'` 或
#      `No "iOS Development" signing certificate matching team ID …` ——
#      两条报错**都会把你带去查账号**，而真因是**环境不对**（见 `P-055`）。
#   ⚠️ 本机 Xcode **未登录 Apple ID** ⇒ `-allowProvisioningUpdates` 必报 `No Accounts`，别用；
#      只吃本机已有的描述文件 + 证书。
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
| 5 网络点播 | `G5` | ◑ `P5-T1`–`T4` 完成 · **`G5` 三项达成**（真机可控弱网：不崩 / 有缓冲提示 / 恢复后自动继续，见 [`docs/12`](docs/12-P5验证报告.md)）· `P5-T5`「可切清晰度」**设计前提已答、尚未实现** |
| 6 直播 | `G6` | ◑ **播放端已在真机证通**（`rtsp://` 真机 `playing`，[`docs/14`](docs/14-P5-T5-HLS多码率调研.md)）· 延迟指标与低延迟参数**未做** |
| 7 macOS | `G7` | ✅ `P7-T1` 完成 · `G7` 达成（根包 214 tests macOS 全绿 + Demo macOS target 构建成功） |

## 下一步

**`M3` 已达成（范围锚点前移到 `M4`）。** 你拍的三件事已全部落地，现在**有能直接开工的票了**：

1. **`P5-T5` 可切清晰度**（`Phase 5` 唯一的欠账）—— 设计前提**已实测答完**（[`docs/14`](docs/14-P5-T5-HLS多码率调研.md)）：
   HLS 多码率 = **N 条 video track**，切清晰度 = **设 `vid`**。
   跨三层：`PlayerCore` 轨道模型 · 内核 `selectVideoTrack` · UI 菜单。
   开工第一条要验的是「**切 `vid` 会不会带动音轨**」（未验）。
2. **`P6-T1` 直播**—— 播放端已在真机证通，剩下的主要是把它**钉成可复现的验收**
   （`P6-T2` 的"延迟怎么量"仍需先定口径：端到端 vs 播放器内部，两者不可比）。
3. **`P6-T3` 低延迟参数逐项实测** —— **尚未拍板**（票面建议里提过）。

**只能肉眼做的**（自动化测不了，等你哪天顺手看一眼）：缓冲提示的文案是否够清楚。

> **范围锚点是 `M4`（在线点播可用）**：任何不推进 `M4` 的需求都往后排。
>
> **环境（一次性，不入仓库）**：`brew install mediamtx ffmpeg` —— 造多码率源 / 直播源都用它。
> 复现步骤见 [`docs/14`](docs/14-P5-T5-HLS多码率调研.md) §五。⚠️ 本机跑本地服务时
> **要清 `HTTP_PROXY`**（会话代理会劫持回环请求，见 `PITFALLS` 的 `P-059`）。

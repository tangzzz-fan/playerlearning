# 变更记录

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

**只记"对使用者可见的变化"**：能编译的行为、公开 API、依赖的二进制、许可。
内部重构、文档措辞、测试增删不记 —— 那些看 `git log`。

> 这里**不写**产物 checksum。二进制与 tag 的对应关系在
> [`compliance/README.md`](compliance/README.md) 的版本对照表里（LGPL「可重现」的落点）。
> 两处都写就会有两处过期，且过期时间不一致。

---

## [Unreleased]

### 新增

- **`PlayerProcessors`（新 product）** —— GPU 处理器的参考实现集。只依赖 `PlayerCore`，不碰 libmpv
  ⇒ iOS 与 macOS 都能构建、都能单测（本机 `swift test` 真的会跑 Metal 并读回像素）。
  - `MetalPassProcessor` —— 一趟全屏 pass 的通用外壳（环形输出池 / 不等待提交 / 片元源码注入）。
  - `LUTFrameProcessor` —— 第一个真实处理器：`.cube` 3D LUT 跑在 GPU 上，`strength` 可变。
    `identifier` 默认 `"lut"`、`order` 默认 `100`。
  - ⚠️ 构造时必须传 `MPVRenderOutput.processingDevice` / `.processingQueue` ——
    队列**必须与上屏同一个**，否则两者之间没有顺序保证。
- `PlayerCore.ColorLUT` —— `.cube` 3D LUT 的解析与三线性采样（纯 CPU，无 Metal）。
  它同时是 GPU 侧的**对账基准**：两边插值口径必须逐点一致。
  自带 `ColorLUT.identity` 与 `ColorLUT.inverted(dimension:)`（后者是"处理器真的在跑"最省事的判据）。
- `MPVRenderOutput.processingDevice` / `.processingQueue` —— 造处理器要用的那一对资源。
- `PlayerCore.FrameProcessor` / `FramePipeline` —— **帧处理器链**：一个处理器慢了不能让播放卡住。
  `Frame` 是关联类型，适配器里实例化成 `MTLTexture`，所以这一层不依赖 Metal，可以在 mac 上纯逻辑单测。
  - `FrameProcessorOutput` 只有 `.unchanged` / `.replaced` / `.notReady` 三种。
    **故意没有"丢弃这一帧"**：丢帧表现为卡顿（无从解释），顶替旧结果表现为延迟（可以报出来）。
  - `StaleFramePolicy` 两档：`.passthrough`（原帧过）与 `.holdLastResult(maxAgeFrames:)`
    （用上一次结果顶替，超龄就退回 passthrough）。
  - `order` 决定执行顺序，**同 `order` 按 `identifier` 字典序** —— Swift 排序不稳定，
    不设这条，同一份输入可能今天 a→b、明天 b→a。
  - `FramePipelineOutput.applied` / `maxLagFrames` 报出"这一帧是谁处理的、晚了几帧"。
- `MPVRenderOutput.framePipeline` —— 处理器链的**唯一插入点**（帧已到手、还没上屏）。
  默认 `nil` ⇒ 这段代码不执行，与没有这一层时的渲染逐字节一致。
- `MPVRenderOutput.resetFramePipeline()` —— **seek 之后必须调**，否则跳转后的第一帧会被旧结果顶替。

### 尚未提供

- **真机上的帧率还没有数字**。本机能证明"处理得对"（像素读回 + 与 CPU 逐点对账），
  **不能**证明"4K 接上处理器还实时"—— 那要按 `docs/34` §六 在真机上压帧。
- 异步处理器（深度 / 推理）一个都没有：`StaleFramePolicy.holdLastResult` 至今没有真实使用者，
  `maxAgeFrames` 默认 2 是猜的。
- 1D LUT（逐通道曲线）不支持，`ColorLUT.parse` 会明确报错。

---

## [0.1.1] - 2026-10-17

### 修复

- **这一版之前，这个包无法被外部项目使用。** `0.1.0` 的 `Package.swift` 里是
  `.binaryTarget(name:path:)`，指向仓库内的 `MPV/Library` —— 而那个目录被 gitignore，
  别人机器上不存在。用它做 `url:` 依赖会在消费者侧报
  `local binary target 'Libmpv' … does not contain a binary artifact`。

### 变更

- 清单改成 `.binaryTarget(name:url:checksum:)`，产物从 Release 下载。
- 仓库由 `playerlearning` 改名为 **`playerstack`**。
  ⚠️ SPM 的 `package:` identity **取自仓库名** ⇒ 引用写法是
  `.product(name: "PlayerMPV", package: "playerstack")`，不是清单里的 `name`（`PlayerStack`）。
- 新增根 `LICENSE`（**MIT**）。此前整个仓库没有许可文件 —— public ≠ 可使用。

### 说明

- 产物 `Libmpv.xcframework.zip` 与 `0.1.0` **逐字节相同**（checksum 一致），
  变的只是 SwiftPM 取用方式。所以"可重现性"对两版是同一个二进制。

---

## [0.1.0] - 2026-10-17

首个 tag。**形态可用、但不可被外部引用**（见 `0.1.1` 的修复）。

### 新增

- `PlayerCore` / `PlayerUI` / `PlayerMPV` 三个 product **全部进入根清单**。
  此前 `PlayerMPV` 在 `MPV/` 子目录里靠自己一份清单，而 SPM 的 `url:` 依赖只解析仓库根清单。
- 产物：两个 slice（`ios-arm64` · `ios-arm64_x86_64-simulator`）。**没有 macOS slice**
  —— macOS 上 `PlayerMPV` 是空模块（`docs/PITFALLS.md` P-096）。
- 许可：代码 MIT · 二进制 **LGPL-2.1**，对应源码与可替换性说明在 `compliance/`。

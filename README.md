# PlayerStack

**可编程帧的 iOS 播放栈。** libmpv 负责解码与格式覆盖，帧落进你自己的 `CVPixelBuffer` ——
在它上屏之前，你可以插手：自绘字幕、滤镜链、2D→3D、AI 推理，随便加。

Swift 6 · iOS 17+ · 代码 MIT / 预编译产物 LGPL-2.1

## 它是什么，不是什么

| | 常见播放库（KSPlayer / VLCKit / AVPlayer） | PlayerStack |
| --- | --- | --- |
| 你拿到的东西 | 一块**能播的屏幕** | 每一帧的像素 |
| 能控制什么 | 播放：放 / 停 / 进度 / 音量 | 播放 **+ 帧内容** |
| 想加字幕样式 | 用库给的那一套 | 自己画，爱怎么排怎么排 |
| 想做 2D→3D | 拿不到帧，做不了 | 帧已经在手里 |
| 格式覆盖 | 好 | 好 —— 同一个 libmpv，这是地基不是卖点 |

一句话：**它不争"能播多少格式"，它给你"帧的出口"。**

## 安装

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/tangzzz-fan/playerstack.git", from: "0.1.1")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "PlayerCore", package: "playerstack"),
        .product(name: "PlayerUI",   package: "playerstack"),
        .product(name: "PlayerMPV",  package: "playerstack")   // iOS only
    ])
]
```

> `package:` 写的是**仓库名** `playerstack`，不是清单里的 `name`（`PlayerStack`）。
> 这两个不一样，写错会报 `product … not found in package`。

三个包各管一段：`PlayerCore` 零 UI 依赖（状态机 / 时间模型 / 字幕时间轴，288 条测试不需要模拟器）·
`PlayerUI` 是 SwiftUI 壳 · `PlayerMPV` 是 libmpv 适配器。

## 30 秒上手

**顺序不可换**：先有输出表面 → 再造内核 → 最后造控制器。换错不会报错，只会黑屏。

```swift
import PlayerCore
import PlayerUI
import PlayerMPV

// ① 先有"表面"——它决定帧从哪出来，这一步决定后面一切
let bridge = MPVRenderBridge()
let output = try MPVRenderOutput(bridge: bridge)      // 帧进你的 CVPixelBuffer
// 或者：let output = WindowEmbedOutput()             // 让 mpv 自己画（拿不到帧）

// ② 再造内核——渲染上下文必须早于第一次 loadfile
let kernel = MPVKernel(renderBridge: bridge)

// ③ 最后造控制器与界面
let vm = PlayerViewModel(controller: PlayerController(kernel: kernel))
PlayerScreenView(viewModel: vm, surface: output)

// 播放
await vm.start()
await vm.load(PlayerResource(url: url, headers: ["Referer": "https://example.com/"]))
await vm.play()
```

两条硬约束（违反的现象都很像"玄学"）：

| 约束 | 违反后 |
| --- | --- |
| 渲染上下文必须**早于** `loadfile` 建立 | mpv 报 `No render context set.`，整个文件加载失败 |
| `mpv_render_context_*` 必须在**主线程**调 | 单线程 API，跨线程等于未定义行为 |

要自己动手处理帧，就接管 `output` 出来的 `CVPixelBuffer`（零拷贝转 Metal 纹理）。

## 平台与限制

| 项 | 情况 |
| --- | --- |
| iOS | 17.0+（真机 + 模拟器都有 slice） |
| macOS | `PlayerCore` / `PlayerUI` 可用；**`PlayerMPV` 是空模块**（xcframework 无 macOS slice，`P-096`） |
| 二进制体积 | `Libmpv.xcframework.zip` 40 MB，SPM 下载一次后走本地缓存 |
| 工具链 | Swift 6 / Xcode 16+ |

## 状态

`v0.1.1` · 386 条测试全绿（288 单元 + 98 UI 逻辑 + 适配器）· 真机 4K 按上屏 **11.51 ms/帧**（86 fps 上限）。
详见 [`docs/25`](docs/25-RenderAPI上屏与吞吐.md) 与 [`docs/26`](docs/26-真机复验-render上屏.md)。

## 许可

| 部分 | 许可 |
| --- | --- |
| 本仓库自己的代码（`PlayerCore` / `PlayerUI` / `PlayerMPV` / Demo / docs） | **MIT**，见 [`LICENSE`](LICENSE) |
| 预编译产物 `Libmpv.xcframework`（GitHub Releases） | **LGPL-2.1** —— 对应源码 / 许可文本 / 可替换性 / 修改声明见 [`compliance/`](compliance/README.md) |

两者是分开的：MIT 不会改变那个二进制里的 LGPL 义务，详见 `LICENSE` 末尾的 scope note。
为什么停在 2.1 而不是 3.0，`compliance/README.md` §一 有完整论证。

## 文档

| 想知道 | 读 |
| --- | --- |
| **这条路往哪走**（定位 / 场景 / 能力缺口） | [`docs/32`](docs/32-帧管道路线.md) |
| 能力全貌、六个机制、怎么装配 | [`docs/28`](docs/28-播放能力总览.md) |
| 要把它移植到别的 App | [`docs/29`](docs/29-移植到JoveView-方案.md) |
| 下一步做什么 | [`docs/31`](docs/31-开源后路线.md) |
| 踩过的坑（动手前扫一眼省事） | [`docs/PITFALLS.md`](docs/PITFALLS.md) |
| 里程碑口径、验证命令、真机部署 | [`docs/00`](docs/00-维护手册.md) |

## 贡献

Issue / PR 都欢迎。改代码前请先跑一遍测试（`swift test --disable-sandbox`），
涉及渲染路径的改动请连同 `xcodebuild -destination 'generic/platform=iOS'` 一起验 ——
`swift build` 在 macOS 上**不碰** libmpv，通不出任何结论。

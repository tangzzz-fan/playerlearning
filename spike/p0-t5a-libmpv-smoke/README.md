# P0-T5a · libmpv + MoltenVK 冒烟工程

> **定位**：`docs/06-P0-T5a技术验证报告.md` 的**可运行留档**。**不是产品代码** —— 产品骨架见 `docs/03` 的 Phase 1。
> **ticket**：`P0-T5a`（技术验证）· **状态**：已完成（2026-10-13）
> **结论**：**模拟器 + 真机（iPhone 16 Pro）双通** —— `wid` 嵌入 + `vo=gpu-next` / `gpu-api=vulkan` / `gpu-context=moltenvk` 在 iOS 上可用；本地 mkv + PGS 图形字幕 + 硬件解码均正常。

---

## 为什么它在这里

`docs/03` 的 Phase 0 原原则是「**spike 一次性、不进主仓**」。本工程经拍板（2026-10-13）**迁入仓库**，用途有二：

1. **技术结论的可复现证据** —— `docs/06` 里的截图与指标可通过重跑本工程复现，而不是只能看文档
2. **`P0-T5b` / Phase 1 的实现基线** —— `docs/06` §3.1 的 mpv 初始化序列、§3.2 的三条实施要点，源头都在这 6 个文件里

代价是它**与 Phase 0 原原则冲突**，该修订已记入 `docs/03`。

---

## 内容

| 路径 | 说明 |
| --- | --- |
| `project.yml` | XcodeGen 工程定义；SPM 引 `mpvkit/MPVKit`（**pin revision** `d9194243bdc68b87d8989376ab52aee7da6c8e0b`，product `MPVKit` 即 LGPL 档） |
| `Sources/MetalLayer.swift` | **两个坑修复**：`drawableSize` 过滤 ≤1；`wantsExtendedDynamicRangeContent` 强制主线程 |
| `Sources/MPVPlayerViewController.swift` | mpv 生命周期：`wid` 注入 `CAMetalLayer` → 选项 → `mpv_initialize` → wakeup callback 事件循环 → 属性观测 |
| `Sources/PlayerStatusModel.swift` | 验证用指标（`video-params/w|h|pixelformat` / `time-pos` / `paused-for-cache` / 事件计数） |
| `Sources/MPVPlayerView.swift` | `UIViewControllerRepresentable` 封装 |
| `Sources/ContentView.swift` | 播放区 + 状态面板；默认播 bundle 内的 `pgs_subtitle.mkv` |
| `fetch-assets.sh` | 取测试素材（见下） |
| `Resources/` | **不入仓**（`.gitignore`），本地必要时由脚本获取 |

---

## 怎么跑

```bash
cd spike/p0-t5a-libmpv-smoke

./fetch-assets.sh          # 取测试素材（约 24 MB）
xcodegen generate          # 生成 P0T5A.xcodeproj

xcodebuild -project P0T5A.xcodeproj -scheme P0T5A \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ./DD build
```

真机（需解锁设备 + 相应签名团队）：

```bash
xcodebuild -project P0T5A.xcodeproj -scheme P0T5A \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -derivedDataPath ./DD-device -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE_UDID> ./DD-device/Build/Products/Debug-iphoneos/P0T5A.app
xcrun devicectl device process launch --device <DEVICE_UDID> --terminate-existing com.p0t5a.spike
xcrun devicectl device capture screenshot --device <DEVICE_UDID> --destination ./shot.png
```

---

## 已知约束（细节见 `docs/06` §3.2 / §4）

1. **必须继承 `MetalLayer` 的两个 setter 重写** —— 否则 MoltenVK 会把 `drawableSize` 设成 1x1 导致闪烁（mpv PR #13651），且非主线程无法激活 EDR。
2. **Metal API Validation 必须关闭**（Scheme → Run → Diagnostics）—— 否则播 HDR 崩溃（MoltenVK issue #2226）。本工程未测 HDR。
3. **测试素材不入仓**。来源 `mpvkit/video-test`；`raw.githubusercontent.com` 在部分网络下极不稳定（20.9 MB 的 mkv 会被超时截断），故脚本改用 **jsDelivr CDN**。
4. **SPM 会下载 `MPVKit` 的 GPL 与 LGPL 两套产物**（`.binaryTarget(url:)` 全量下载），首次解析约 400–600 MB、18 分钟左右。
5. 真机 `launch` 要求设备**已解锁**，否则报 `FBSOpenApplicationErrorDomain error 7 Locked`。

---

## 未覆盖（属后续 ticket）

HDR / Dolby Vision · ASS 字幕特效 · 多音轨 · seek · 音频实际发声 · 性能与功耗 · **动态 framework 形态**（属 `P0-T5b`）。

# P0-T5b · 端到端验证工程

> **用途**：用 [`P0-T5b`](../README.md) 自建的**动态 LGPL libmpv** 替换掉 `P0-T5a` 用的远端 `MPVKit`，验证「自包含动态库」能在 iOS App 里加载并出画面。
> **这是 `G0` 判定门的最后一步**：技术（`P0-T5a`）+ 产物（`P0-T5b`）+ 集成（本工程）三者齐备后才算通过。
> **与 `p0-t5a-libmpv-smoke` 的关系**：`Sources/` 是它的同一套代码（只改了 target 名与 bundle id）；差异**只在依赖来源**。

---

## 为什么 App 侧只需要一个 `Libmpv.xcframework`

`P0-T5b` 的产物是**自包含**的：`otool -L` 显示它只依赖系统 framework，**零个 `libav*` / `libass` / `libplacebo`** —— FFmpeg 与其余 20+ 依赖全部**静态链入** `libmpv.dylib`。

所以对比 `P0-T5a`（依赖 `MPVKit` 的 38 个 binaryTarget），这里只需要：

```
LocalLibmpv/Package.swift  →  .binaryTarget(name: "Libmpv", path: "Libmpv.xcframework")
```

**LGPL 视角这也是更有利的形态**：可替换的库只有**一个**（`libmpv`），用户替换它即替换整条链。

---

## 怎么跑

```bash
../build.sh                # 若还没构建
./stage-artifact.sh        # 把 dist 里的 xcframework 拷进 LocalLibmpv/（不入 git）
xcodegen generate
xcodebuild -project P0T5BVerify.xcodeproj -scheme P0T5BVerify \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ./DD build
```

真机（需解锁设备）：

```bash
DEV=<DEVICE_UDID>
xcodebuild -project P0T5BVerify.xcodeproj -scheme P0T5BVerify \
  -destination "platform=iOS,id=$DEV" \
  -derivedDataPath ./DD-device -allowProvisioningUpdates build
xcrun devicectl device install app --device $DEV ./DD-device/Build/Products/Debug-iphoneos/P0T5BVerify.app
xcrun devicectl device process launch --device $DEV --terminate-existing com.p0t5b.verify
xcrun devicectl device capture screenshot --device $DEV --destination ./shot.png
```

---

## 关键依赖：rpath

产物的 `install_name` 是 **`@rpath/Libmpv.framework/Libmpv`**（由 [`postprocess-framework.sh`](../postprocess-framework.sh) 修正 —— 原值是构建目录的绝对路径，装进 App 必然加载失败）。

所以 App 必须带 `@executable_path/Frameworks` 这条 rpath，`project.yml` 里已显式设置：

```yaml
LD_RUNPATH_SEARCH_PATHS: [$(inherited), "@executable_path/Frameworks"]
```

**若启动时崩溃并报 `Library not loaded: @rpath/Libmpv.framework/Libmpv`**，先查这一条。

---

## 通过标准

1. App 启动不崩（动态库加载成功）
2. 本地 mkv 出画面，状态面板显示 `pixfmt: videotoolbox`
3. 两张截图 md5 不同（画面在动）

与 `P0-T5a` 的通过标准一致 —— 因为**变量只有一个**：产物从「远端 MPVKit 静态」换成「自建动态 LGPL」。

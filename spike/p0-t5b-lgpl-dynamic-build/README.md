# P0-T5b · 自建动态 LGPL-2.1 libmpv 产物

> **对应 ticket**：`P0-T5b`（`G0` 判定门的最后一块）
> **目标**：产出 **动态 framework** 形态的 **LGPL-2.1** libmpv，替代 `MPVKit` 的预编译静态产物
> **依据**：[`docs/04`](../../docs/04-开工前准备清单.md) §3 · [`docs/05`](../../docs/05-libmpv产物实测报告.md)（P0-T4 结论）· [`docs/06`](../../docs/06-P0-T5a技术验证报告.md)（技术已通）
> **状态**：改动定稿，全量重建中（2026-10-13）

---

## 一、为什么是这两个目标

| 目标 | 为什么 |
| --- | --- |
| **动态**（而非静态） | LGPL 合规的枢纽是「用户能用修改后的库重新链接」。静态链接只能退到「交出可重链接材料」那条路，iOS 上不成立。`docs/04` §3 已把它定为施工硬约束 |
| **LGPL-2.1**（而非 v3） | `P0-T4` 从二进制里捞出 `--enable-version3` ⇒ MPVKit 产物落在 **LGPLv3**。该开关是**构建方的选择**，LGPL-2.1-or-later 允许不选 ⇒ **不选它，全链停在 LGPL-2.1**，绕开 LGPLv3 §4(e)（挂钩 GPLv3 §6 的 Installation Information）—— iOS 上最拧巴的条款 |

---

## 二、改动：**一个文件，5 处**（`01-build-changes.patch`）

全部落在 `Sources/BuildScripts/XCFrameworkBuild/main.swift`。

### 2.1 动态化（1 处）

| # | 位置 | 改动 |
| --- | --- | --- |
| 1 | `BuildMPV.arguments` | 插入 `"-Ddefault_library=shared"` |

**为什么一行就够**（三条已核实）：

| 依据 | 出处 |
| --- | --- |
| mpv 用 `libmpv = library('mpv', sources, …)`，**不是 `static_library()`** ⇒ 受 `default_library` 控制 | mpv v0.41.0 `meson.build` L1786 |
| `-Ddefault_library=shared` **只传给 mpv**（不改全局 cross-file）⇒ FFmpeg 与其余依赖**全部保持静态**，被静态链进 `libmpv.dylib` | 由 ① 推出；架构上更优 |
| 命令行 `-D` **能覆盖** cross-file 里的 `default_library='static'` | 已用最小 meson 项目实测：`libt.a` → `libt.dylib` ✓ |

**架构结果**：只有 `libmpv` 是动态库，FFmpeg 静态链进它 ⇒ **LGPL 合规只需「libmpv 可替换」**（用户换掉 libmpv = 换掉整条链），App 的体积与集成复杂度都远小于「20+ 个库全动态化」。

### 2.2 压回 LGPL-2.1（4 处）

**第一次尝试（只去掉 `--enable-version3`）构建失败**，FFmpeg 报：

```
gmp is version3 and --enable-version3 is not specified.
```

⇒ 顺着这条错误查清了**真正的许可传导链**（这一步是本次最重要的发现）：

| 环节 | 事实 | 依据 |
| --- | --- | --- |
| `--enable-version3` 只是「声明」 | 真正要求 v3 的是**链进来的库** | FFmpeg configure 报错原文 |
| **`gmp`** | LGPLv3+ / GPLv2+ 双许可；在 FFmpeg 的 `EXTERNAL_LIBRARY_VERSION3_LIST` 里 | `FFmpeg/configure` L2051-2060 |
| `gmp` 在 FFmpeg 里的用途 | **仅 `libavformat/rtmpdh.c`（RTMP 的 Diffie-Hellman）** —— 与本地/HTTP 播放无关 | `rtmpdh.c` L62 `#if CONFIG_GMP`（有内部回退实现） |
| **引入 gmp 的真正路径** | `--enable-gnutls` → **nettle**（LGPLv3+/GPLv2+）→ **gmp** | FFmpeg 的 `gnutls_deps`；mpvkit 构建脚本 LDFLAGS |
| **mpv 自己** | `meson.build` 里 **gnutls / openssl / gmp / smbclient 零匹配** ⇒ mpv **不直接依赖** TLS 库，TLS 全从 FFmpeg 走 | mpv v0.41.0 `meson.build` |
| **替代方案** | FFmpeg 自带 **SecureTransport** 后端 = Apple 系统 TLS（`Security.framework`），文档标注 `[autodetect]` 且与 gnutls **互斥** | `FFmpeg/configure` L342、L4108 |

**所以 4 处改动是：**

| # | 位置 | 改动 | 作用 |
| --- | --- | --- | --- |
| 2 | `BuildFFMPEG` 的 configure 参数 | 去掉 `--enable-version3` | 不再声明 v3 |
| 3 | `BuildFFMPEG.arguments` 的 `dependencyLibrary` | 去掉 `.gmp, .gnutls`（连带不再生成 `--enable-gmp` / `--enable-gnutls` 及其 `-I`/`-L`/`-l`） | **切断 v3 依赖链** |
| 4 | `BuildFFMPEG.ldFlags` | 去掉 `-lhogweed`（nettle）与 gnutls 条件分支，`Security`/`CoreFoundation` 改为无条件 | 与 ③ 对齐 |
| 5 | 同上 configure 参数 | 加 `--enable-securetransport` | TLS 改走系统框架 |
| — | `BuildMPV.flagsDependencelibrarys` | `[.gmp]` → `[]` | mpv 侧不再链 gmp |
| — | `BuildFFMPEG.flagsDependencelibrarys` | `[.gmp, .nettle, .gnutls]` → `[]` | 同上 |

**GPL 模式（`--enable-gpl`）的分支原样保留** —— 本 patch 只动非 GPL 分支，不影响上游脚本的其它用法。

### 2.3 快速验证（不做 20 分钟盲跑）

用 iOS SDK 直接跑一次 FFmpeg configure（约 40 秒）：

```
License: LGPL version 2.1 or later          ← configure 自报许可
#define CONFIG_SECURETRANSPORT 1            ← 系统 TLS 后端探测成功
#define CONFIG_TLS_PROTOCOL 1               ← TLS 协议启用
#define CONFIG_HTTPS_PROTOCOL 1             ← HTTPS 协议启用
#define CONFIG_GNUTLS 0
#define CONFIG_OPENSSL 0
```

⇒ **LGPL-2.1 是可达的，且不牺牲 HTTPS**。

### 2.4 备用方案（若 SecureTransport 行为异常）

改为 `--enable-openssl`（mpvkit 脚本本来就构建 OpenSSL 3.3.5，**Apache-2.0**，同样不触发 v3）。一行开关之差，已记录为回退路径。

---

## 三、不需要做的事（已排除）

| 原本以为要做的 | 实际情况 |
| --- | --- |
| 改 4 处静态配置（`main.swift` L661 + `base.swift` L649/L294/L673-684） | **只需 1 处**（`-Ddefault_library=shared`） |
| pin `meson==1.4.2`（对齐 CI） | mpv 要求 `meson_version: '>=1.3.0'`，**只有下限无上限** ⇒ 本机 1.12.1 满足 |
| 另写 framework 打包脚本 | mpvkit 的 `createFramework` **原生支持**：`lib/*.a` 不存在时自动回退 `lib/*.dylib`，再 `lipo -create` 合成 |
| 装 `rename` | 那是 CI release 打包步骤用的，构建期不需要 |
| 把 20+ 个依赖全部动态化 | **不需要** —— 只动 libmpv，其余静态链入 |

---

## 四、环境依赖

| 项 | 说明 |
| --- | --- |
| **`wget`** | **构建脚本唯一的额外外部命令**（缺了它会自己 `brew install wget`，并触发 Homebrew auto-update 拖慢数分钟） |
| `meson` / `ninja` / `cmake` / `pkg-config` / `autoconf` / `automake` / `libtool` / `nasm` / `python3` | 见 `docs/04` §2.2（已装齐） |
| 注意 | `BaseBuild.defaultPath` **硬编码** PATH 为 `/Library/Frameworks/Python.framework/Versions/Current/bin:/opt/homebrew/bin:…` ⇒ **无法靠 shell PATH 前置切换 meson 版本**（所幸不需要） |
| 注意 | `buildALL()` 会**逐个删除并重建**每个库，**没有跳过逻辑** ⇒ 任何改动都要全量重跑（约 20–30 分钟） |

---

## 五、怎么跑

```bash
./build.sh                     # 拉源码 + 打补丁 + 只构 iOS
./postprocess-framework.sh     # 修正 install_name 并自检
```

产物期望位置：`$WORK/mpvkit/dist/release/xcframework/Libmpv.xcframework`

### 待验证清单（构建完成后逐条核）

1. **是否真产出动态库**：`file` 各 slice 的 `Libmpv` 应为 `Mach-O ... dynamically linked shared library`
2. **依赖是否自包含**：`otool -L` 应只有系统 framework（FFmpeg 已静态链入），**不应**出现 `libav*.dylib` 之类
3. **`install_name`**：须为 `@rpath/Libmpv.framework/Libmpv`（mpvkit 未处理，故有 `postprocess-framework.sh`）
4. **切片完整性**：需含 `ios-arm64`（真机）与 `ios-arm64_x86_64-simulator`
5. **许可串**：`strings` 应显示 **LGPL version 2.1 or later**（不再是 P0-T4 看到的 v3）
6. **v3 依赖残留**：`gnutls` / `nettle` / `gmp` / `hogweed` 的符号痕迹应为 **0**
7. **端到端**：把产物喂给 `verify/` 工程，真机复跑出画面

---

## 六、这个目录里的东西与 LGPL 的关系

按 LGPL，分发时必须提供「库的修改」与「构建方式」。本目录即为此用途：

| 文件 | 作用 |
| --- | --- |
| `01-build-changes.patch` | 我们对**构建脚本**的修改（不是对 mpv 源码的修改） |
| `build.sh` | 可原样重跑的构建方式 |
| `postprocess-framework.sh` | 打包后处理（`install_name`），同样属于「构建方式」 |
| `verify/` | 端到端验证工程（本地 `binaryTarget` 引用产物） |

> ⚠️ 另需一并提供的是 **mpvkit 自带的 3 个 patch**（`Sources/BuildScripts/patch/libmpv/`）—— 其中 `0001-player-add-moltenvk-context.patch` **就是 `wid` 通路本身**，上游 mpv 没有。这属于 `P0-T6`（合规材料基线）的范围。

# 对应源码与构建方式（LGPL-2.1 §6 / §4）

> 目的：**任何人**拿着这份文件，能把 `MPV/Library/Libmpv.xcframework` 从源码重新做出来，
> 并且能用下面 §4 的命令验证"做出来的确实是同一个东西"。
>
> 依据的原始记录：[`spike/p0-t5b-lgpl-dynamic-build/build-evidence.md`](../spike/p0-t5b-lgpl-dynamic-build/build-evidence.md)
> ——那份文件是从**实际产出当前产物的那次构建日志**里逐行提取的 meson 命令行，不是事后补写的。

---

## 一、三个上游来源（都必须按这个 commit 取）

| 组件 | 来源 | 固定的版本 | 说明 |
| --- | --- | --- | --- |
| 构建脚本 | `github.com/mpvkit/MPVKit` | **`d9194243bdc68b87d8989376ab52aee7da6c8e0b`** | 我们改的是它的 `Sources/BuildScripts/XCFrameworkBuild/main.swift`（见 [`MODIFICATIONS.md`](MODIFICATIONS.md)） |
| mpv | 由 mpvkit 在该 revision 下自动下载 | **v0.41.0** | 产物里可读到 `mpv v0.41.0-dirty`（`-dirty` 就是"我们打过补丁"） |
| FFmpeg | 由 mpvkit 在该 revision 下自动下载 | **libavcodec `Lavc63.1.102`** | 版本号是**从产物里读出来的**，不是查文档填的 |

> ⚠️ **不要**自己指定 FFmpeg 的 tag 去"对齐版本"。mpvkit 的脚本会按 `d9194…` 这个 revision
> 下载它认的那一版；手工指定会让"构建方式"与"产物"脱钩，而这份文件的价值就在于两者能对上。

---

## 二、我们的补丁（三个文件，全部在 `spike/p0-t5b-lgpl-dynamic-build/`）

| 文件 | 作用 | 详细说明 |
| --- | --- | --- |
| `01-build-changes.patch` | ① `-Ddefault_library=shared`（动态化）② 去掉 `--enable-version3` 与 gmp / nettle / gnutls 依赖（行使 `or later` 选项，停在 LGPL-2.1，理由见 [`README.md`](README.md) §一） | [`MODIFICATIONS.md`](MODIFICATIONS.md) §1 |
| `02-build-env-passthrough.patch` | 把 `WGETRC` 转发进构建子进程（受限网络的证书适配） | §2 |
| `ffmpeg/0001-videotoolbox-metal-compatibility.patch` | VideoToolbox 输出的 `CVPixelBuffer` 兼容键从 OpenGLES 改成 **Metal** | §3 |

---

## 三、复现步骤

```bash
# 前置：Xcode 命令行工具、wget、约 20 GB 空闲磁盘；网络能到 github.com
cd spike/p0-t5b-lgpl-dynamic-build

# 1) 构建（clone mpvkit@d9194…、打三个补丁、跑 mpvkit 的 ios 构建）
WORK=/tmp/p0t5b-build ./build.sh

# 2) 产物体检 + 改名 install_name（postprocess 会把 @rpath 与 framework 结构定型）
WORK=/tmp/p0t5b-build ./postprocess-framework.sh

# 3) 取产物
ls /tmp/p0t5b-build/mpvkit/dist/release/xcframework/Libmpv.xcframework
```

`build.sh` 里对**受限网络**（MITM 代理导致 `wget` 校验失败）做了探针式处理：
只在一次调用内设置 `WGETRC`，**不写全局 wgetrc** —— 那是环境适配，不是构建配方的一部分。
同理 `--disable-sandbox` 只在"本机确实不允许再套一层沙箱"时附加，正常终端里与
`make build platform=ios` 完全等价。

---

## 四、产物校验（把"同一个东西"变成可核对的四条）

```bash
XCF=MPV/Library/Libmpv.xcframework/ios-arm64/Libmpv.framework/Libmpv

# ① 它是动态库，且只依赖系统库（这是"可替换"的前提）
otool -L "$XCF"

# ② 版本串（应含 mpv v0.41.0-dirty）
strings "$XCF" | grep "mpv v0"

# ③ FFmpeg 是被静态链进来的（有符号、无独立 dylib）
strings "$XCF" | grep Lavc
nm -gU "$XCF" | grep -c avcodec

# ④ 许可文本不在产物里 —— 所以必须由我们随分发提供（见 README §一）
strings "$XCF" | grep -c "Lesser General Public"
```

本文件与产物对应的一次实测结果（2026-10-17）：

| 检查 | 结果 |
| --- | --- |
| `otool -L` 的非系统依赖 | **只有 1 条**：`@rpath/Libmpv.framework/Libmpv` |
| `mpv v0` | `mpv v0.41.0-dirty` |
| `Lavc` | `Lavc63.1.102` |
| 内嵌许可文本 | **0**（⇒ 外带，`licenses/LGPL-2.1.txt`） |

---

## 五、这份文件的边界

- 它保证"**源码 + 补丁 + 构建命令**能被人拿到并重跑"；
- 它**不保证**重跑出来的二进制与手上这个**逐字节相同**（编译器版本、Xcode 版本会带来差异）——
  LGPL 要求的是"对应源码"与"可重建"，不是"可复现构建（bit-for-bit）"；
- 我们**没有**做可复现构建（reproducible build）。若将来需要，先固定 Xcode 与 SDK 版本再谈。

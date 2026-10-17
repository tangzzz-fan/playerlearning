# 修改声明（LGPL-2.1 §2(a) / §6）

> 我们对上游做了**三类**改动。每一类都写清：改了什么、**为什么**、对分发物的**实际影响**。
>
> 原则：**没有效果的改动也要声明**（例如只为构建环境加的那一行）——
> "改了但没影响"与"没改"是两件事，混在一起会让这份声明失去可信度。

---

## 1. 构建开关：动态化 + 停在 LGPL-2.1（`01-build-changes.patch`）

改的是 **mpvkit 的构建脚本**（`Sources/BuildScripts/XCFrameworkBuild/main.swift`），
不改 mpv / FFmpeg 的源码。

| # | 改动 | 为什么 | 对产物的影响 |
| - | --- | --- | --- |
| 1 | mpv 构建参数插入 `-Ddefault_library=shared` | LGPL 合规的枢纽是"用户能换掉库"；静态链接只能退到"交出可重链接材料"，而 iOS 上不成立 | **libmpv 变成动态库**（`@rpath/Libmpv.framework/Libmpv`）—— 这是整件事的目的 |
| 2 | 去掉 `--enable-version3` | 该开关会把许可推到 **LGPLv3**（进而挂上 GPLv3 §6 的 Installation Information 要求）。LGPL-2.1-or-later 允许不选它 | 全链停在 **LGPL-2.1** |
| 3 | FFmpeg 依赖里去掉 **gmp / nettle / gnutls** | 这是"去掉 ② 之后仍然构建失败"的**真因**：`gmp is version3 and --enable-version3 is not specified` —— 依赖链把许可又拉回 v3 | 链接期不再拉这 3 个库；**TLS 改用系统 SecureTransport**，功能不减少 |
| 4 | 链接 flags 里去掉 `-lhogweed` 与 gnutls 分支（改为直接带 `Security` / `CoreFoundation`） | 与 ③ 同源：既然不链 gnutls，这两段就是死代码 | 无（只是清掉失效分支） |
| 5 | `dependencyLibrary` 列表去掉 `gmp` / `gnutls` | 同上（打包阶段也要一致，否则会去找不存在的东西） | 无 |

> ⚠️ 第 3 条是这一整块里**唯一有功能含义**的改动：TLS 栈从 gnutls 换成了系统的
> SecureTransport。**这个换法不是妥协** —— 在 iOS 上它本来就是更自然的选择（系统信任链、
> ATS 一致），但它是"我们改了依赖构成"，必须写在这里。

---

## 2. 构建环境适配：`WGETRC` 转发（`02-build-env-passthrough.patch`）

| 改了什么 | 为什么 | 对分发物的影响 |
| --- | --- | --- |
| mpvkit 给子进程构造环境时，把父进程的 `WGETRC` 也转发进去 | 受限网络（MITM 代理）下 `wget` 无法验证 `github.com` 证书，构建下载会失败 | **零**。未设置 `WGETRC` 时行为完全不变；它只影响构建期的下载行为，不进二进制 |

> 这条是**唯一一条"我们改了上游脚本、但产物不受影响"的**。仍然列出，理由见本文开头。

---

## 3. FFmpeg：VideoToolbox 的 buffer 兼容键改成 Metal（`ffmpeg/0001-…patch`）

| 改了什么 | 为什么 | 对分发物的影响 |
| --- | --- | --- |
| `libavcodec/videotoolbox.c` 里，`CVPixelBuffer` 的属性键从 `kCVPixelBufferOpenGLESCompatibilityKey` / `…IOSurfaceOpenGLTextureCompatibilityKey` 改为 **`kCVPixelBufferMetalCompatibilityKey`**（两处） | FFmpeg 默认按 **OpenGL ES** 准备 VideoToolbox 的输出 buffer；我们在 iOS 上用 **Metal** 取纹理。不改这一处，`CVMetalTextureCacheCreateTextureFromImage` 拿不到可用的 IOSurface | 硬解输出的帧**能被 Metal 直接使用**。这是"帧到了我们手上"能成立的前提之一 |

> 这一条**改了 FFmpeg 的源码**（前两条改的是构建脚本）。它是**功能性的**：
> 换回原样，硬解那条路在 Metal 上就取不到纹理。

---

## 4. 我们**没有**改的部分

| 没改 | 说明 |
| --- | --- |
| mpv 的源码 | mpv 本体一行未改（`v0.41.0-dirty` 的 `-dirty` 来自构建配置，不是 mpv 源码补丁） |
| FFmpeg 的其余部分 | 除 §3 那一处，其余按上游原样 |
| libass / libplacebo / vulkan / MoltenVK / dav1d 等 | 未改，按 mpvkit 的固定版本 |

> 上表里"mpv 源码一行未改"这句是可核对的：`spike/p0-t5b-lgpl-dynamic-build/` 下
> **没有任何 mpv 源码补丁**，只有构建脚本补丁与一个 FFmpeg 补丁。

---

## 5. 与 `docs/23` §五 的对应

`docs/23-上架准备清单.md` §五 列的四件交付物，这里是第 4 件。
对应关系：源码与构建方式 → [`SOURCE.md`](SOURCE.md) · 可替换说明 → [`REPLACEABILITY.md`](REPLACEABILITY.md) ·
许可文本 → [`licenses/LGPL-2.1.txt`](licenses/LGPL-2.1.txt)。

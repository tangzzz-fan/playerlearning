# LGPL 合规交付物（PlayerStack）

> **这不是法律意见。** 它是"我们把能自己做完的部分做完了"的记录，以及"剩下哪些需要人判断"的清单。
>
> **对外表述纪律**（`ksplayer-playbook/D` §4）：只能宣称「**已尽力合规**」，
> **不得**宣称「已确保合规」。真实风险来自**上游权利人投诉**，不是平台审核。

---

## 一、我们分发的是什么

| 事实 | 值 | 怎么核 |
| --- | --- | --- |
| 动态库 | **`Libmpv.framework/Libmpv`**，单一 `@rpath` 动态库 | `otool -L MPV/Library/Libmpv.xcframework/ios-arm64/Libmpv.framework/Libmpv` |
| 其余依赖 | **全部是系统库**（CoreText / CoreMedia / VideoToolbox / libc++ / libz …） | 同上；输出里除第一行外没有第三方路径 |
| FFmpeg | **静态链进 libmpv**（不作为独立 dylib 出现） | 同上 + `nm -gU … \| grep avcodec` 有符号、`otool -L` 无 libav* |
| mpv 版本 | `mpv v0.41.0-dirty` | `strings …/Libmpv \| grep "mpv v0"` |
| libavcodec 版本 | `Lavc63.1.102` | `strings …/Libmpv \| grep Lavc` |
| 许可文本 | **产物内不含**（grep 计数 0）⇒ 必须由我们随分发提供 | `strings …/Libmpv \| grep -c "Lesser General Public"` ⇒ 0 |

> "只有 libmpv 是动态的，FFmpeg 静态链在它里面" 这件事**不是巧合，是选择**：
> 它把"可替换"的范围收敛到**一个文件** —— 用户换掉 `Libmpv` 就等于换掉整条解码链，
> 不必逐个换 20+ 个库（`spike/p0-t5b-lgpl-dynamic-build/README.md` §2.1）。

### 为什么是 2.1，而不是 3.0

上游的许可是 `LGPL-2.1 **or later**`。"or later" 是**授权方给接收方的选项**，
不是接收方的义务 ⇒ 我们选 2.1 是行使这项选项，**不构成"降级"或"倒退"**。

| 事实 | 值 | 怎么核 |
| --- | --- | --- |
| 产物自报的许可 | **7 个 FFmpeg 组件全部** `LGPL version 2.1 or later` | `strings -a …/Libmpv \| grep "license: LGPL" \| sort` |
| 有无 v3 痕迹 | **0** | `strings -a …/Libmpv \| grep -ci "gpl version 3"` |
| 上游 MPVKit 原本选的是 v3 | `BuildFFMPEG.arguments` 里硬写 `--enable-version3` | `spike/…/01-build-changes.patch` |
| 只删那个开关不够 | 首次构建失败：`gmp is version3 and --enable-version3 is not specified.` | `spike/…/README.md` §2.2 |
| 真正拔掉的一条链 | `--enable-gnutls` → `nettle` → `gmp`，三者均为 (L)GPLv3+ | 同上；`FFmpeg/configure` 的 `EXTERNAL_LIBRARY_VERSION3_LIST` |

**不用 v3 的三条理由**（LGPLv3 不是独立文本，是 GPLv3 之上的附加许可）：

| 条款 | 要求 | iOS 上的现实 |
| --- | --- | --- |
| §4(e) → GPLv3 §6 | 对 "User Product" 提供**安装信息**，让用户能装上自己改过的版本 | 安装必经 Apple 签名/描述文件，**物理上不存在**这条路径 |
| GPLv3 §3 | 作品不得成为"有效技术措施"的一环 | 与 FairPlay 冲突 |
| GPLv3 §10 | 不得对作品施加额外限制 | App Store 条款本身即额外限制 |

**v3 的好处我们用不上**：它相对 2.1 的实质增量是 §11 明示专利授权 + 与 Apache-2.0 兼容。
本链所链的库（freetype / harfbuzz / fribidi / libass / dav1d / libplacebo / lcms2 / uavs3d）
在 2.1 下均可用；把 gnutls 换成 SecureTransport 后，**唯一压在 v3 上的依赖链已拆除**。

**代价（写清，不粉饰）**：

1. **没有明示专利授权** —— GPLv3 §11 那层保护不存在，H.264/HEVC 专利池风险自担（见本文 §三）。
2. **与 Apache-2.0 有摩擦** —— 所以 `spike/…/README.md` §2.4 的备用方案（改用 OpenSSL 3.3.5，
   Apache-2.0）**不是"一行开关之差"的等价替换**，若要采用需单独评估兼容性。
3. **义务不减** —— 仍是 LGPL：对应源码、许可文本、可替换性、修改声明四件一件都不能少。

---

## 二、四件交付物（`docs/23` §五 要的那四件）

| # | 交付物 | 文件 | 状态 |
| - | --- | --- | --- |
| 1 | **库的对应源码**（含补丁 + 可复现的构建配置） | [`SOURCE.md`](SOURCE.md) | ✅ |
| 2 | **许可文本与说明** | [`licenses/LGPL-2.1.txt`](licenses/LGPL-2.1.txt) · 本文 §一 | ✅ |
| 3 | **"用户可替换库"的尽力说明** | [`REPLACEABILITY.md`](REPLACEABILITY.md) | ✅ |
| 4 | **修改声明** | [`MODIFICATIONS.md`](MODIFICATIONS.md) | ✅ |

---

## 二·补、版本对照（LGPL 要的是「哪个版本对应哪份源码」）

| tag | commit | 产物 | sha256（SPM checksum） |
| --- | --- | --- | --- |
| `v0.1.0` | `b8398c3` | `Libmpv.xcframework.zip`（40 MB，ios-arm64 + ios-arm64_x86_64-simulator） | `f98a0c3fa47f0a7cc7cb1c2d8160c892c3e584da478862dfa05a3c082caca0d6` |
| `v0.1.1` | `33630fd` | 同上（**同一个 zip，未重新打包** ⇒ sha256 完全相同） | `f98a0c3fa47f0a7cc7cb1c2d8160c892c3e584da478862dfa05a3c082caca0d6` |

> ⚠️ **`v0.1.0` 的清单仍是 `path:` 形态**（那时产物还在本地）。开源后要用 `url:` 引用，
> 必须用 **`v0.1.1`** —— 否则消费者读到的还是 `path:` 清单，会失败。详见 [`docs/30`](../docs/30-导出物现状与欠缺.md) §八。
>
> **`v0.1.1` 相对 `v0.1.0` 没有改产物**（checksum 逐位相同），只改了清单形态与仓库名
> （`playerlearning` → `playerstack`，因此 identity 也变了）。所以这两个 tag 对应的**二进制源码完全相同**，
> 变更的只是 SwiftPM 的取用方式。
>
> 每个 tag 都要在这张表里加一行。这张表就是"三年后有人来问"的第一处落点。

---

## 三、还缺什么（只有人能做的）

| 项 | 为什么我做不了 |
| --- | --- |
| **对外页面**（商店页 / 网站上的"开源许可"页） | 需要可公开访问的 URL。文本已备好（本目录），发布位置是运营决定 |
| **源码包的对外托管** | 本仓库可以交出，但"给公众的下载地址"要人定（GitHub 公开仓库 / 独立 tar 包） |
| **上游权利人的实际态度** | 律师/商务层面。我们只做到"能拿出对应源码、能替换、有修改声明" |
| **编解码专利池**（H.264 / HEVC） | 与 LGPL **无关**、是另一件事：`D` §7。**"我用了 LGPL" 不等于 "没有专利问题"** |

---

## 四、这一节要记住的一句话

> **合规不是"打包时做对一次"，是"三年后有人来问，能在一小时内拿出四件东西"。**
>
> 所以本目录的文件都写成**可当场复核**（每条事实都带命令），
> 以及**可复现**（补丁 + 上游 commit + 构建命令），而不是一张"我们重视开源"的声明。

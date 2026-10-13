# libmpv 产物实测报告（P0-T4）

> **对应 ticket**：`P0-T4`（补齐 LGPL 核查）
> **审计日期**：2026-10-13
> **审计对象**：`mpvkit/MPVKit` release tag `1.1.0-n9.0.2` 的 **LGPL 档**（product `MPVKit`，非 `-GPL`）
> **审计产物**：`Libmpv` · `Libavutil` · `Libavcodec` · `Libavfilter` · `Libavformat`（均取 `ios-arm64` slice）
> **方法**：解压 xcframework → `file` / `ar -t` / `nm -g` / `strings`。**全部命令见 §7，可复现。**
> **编号说明**：本文为 `docs/03` 原预告的 P0 交付物，因 `docs/04` 已被开工前准备清单占用，顺延为 `docs/05`。

---

## 一、结论先说

**MPVKit 的 LGPL 档产物是真的干净 LGPL —— FFmpeg 侧核查通过。** 三条决定性证据：

| # | 证据 | 实测值 |
| --- | --- | --- |
| 1 | **FFmpeg 自己声明的许可串** | `libavutil license: LGPL version 3 or later` |
| 2 | **configure 行无任何 GPL 开关** | 无 `--enable-gpl`、无 `--enable-nonfree` |
| 3 | **GPL-only 组件痕迹全零** | `Libavcodec` / `Libavfilter` / `Libavformat` 三个库的 `.o` 列表对 x264 / x265 / libxvid / postproc / vidstab / frei0r / avisynth / zvbi / smbclient **全部 0 命中**；外部符号同样为空 |

**同时确认了一件让我们必须自建的事**：整条链（mpv 与 FFmpeg）**全部是静态库**，`--disable-shared --enable-static`。

---

## 二、两个关键发现（都会改动既有决策）

### 发现 1｜产物是 **LGPLv3**，不是 v2.1 —— 但自建时可以把它压回 v2.1

configure 行里有 **`--enable-version3`**。FFmpeg 官方对它的定义就是「upgrade (L)GPL to version 3」⇒ 所以产物落成 **LGPLv3**，这与 MPVKit 的 `LICENSE` 声明一致。

**但它同时给出了一条更好的路**：`--enable-version3` 是**构建方的选择** —— LGPL-2.1-or-later 的代码允许分发者选 v3，也可以不选。
⇒ **我们自建时不传这个 flag，全链就能停在 LGPL-2.1**，从而绕开 LGPLv3 的 §4(e)（挂钩 GPLv3 §6 的 Installation Information）—— 那正是 iOS 上最拧巴的条款。

**这修正了 `docs/04` §4 的 D3 推荐**：原推荐是"按 LGPL-2.1 声明"（只是声明层面）；现在升级为"**自建时不启用 `--enable-version3`，把 2.1 变成技术事实**"。

### 发现 2｜全链静态 —— 印证必须自建动态

| 产物 | 类型 |
| --- | --- |
| `Libmpv`（ios-arm64） | `Mach-O ... current ar archive` ⇒ **静态** |
| `Libavcodec`（ios-arm64） | `Mach-O ... current ar archive` ⇒ **静态** |
| FFmpeg configure | `--disable-shared --enable-static` |

⇒ LGPL 的「suitable shared library mechanism」路径**完全不成立**，只剩「提供可重链接材料」那条。
⇒ 与 `docs/04` §3、§7-R2 的判断一致：**必须自建动态产物**。P0-T5 的必要性已被证实。

---

## 三、审计明细

| 检查项 | Libavcodec | Libavfilter | Libavformat |
| --- | --- | --- | --- |
| x264 / x265 / libxvid 目标文件 | 0 | 0 | 0 |
| postproc / vidstab 目标文件 | 0 | 0 | 0 |
| frei0r / avisynth 目标文件 | 0 | 0 | 0 |
| zvbi / smbclient 目标文件 | 0 | 0 | 0 |
| GPL 编码器外部符号（`x264_*` / `x265_*` / `ff_postprocess`） | 空 | 空 | — |

**构建方式：白名单式裁剪**（作者对功能面与许可都做了收敛，这点值得肯定）：

- `--disable-muxers` / `--disable-encoders` / `--disable-decoders` / `--disable-filters` 全关，再逐项 `--enable-*` 白名单打开
- **编码器只留 7 类**：`aac` `alac` `flac` `pcm*` `movtext` `mpeg4` + **`h264_videotoolbox` / `hevc_videotoolbox` / `prores_videotoolbox`**（系统硬件编码，**非 GPL**）
- **解码器覆盖播放所需**：`h264` `hevc` `av1` `vp8/vp9` `mpeg4` `prores` `vc1` `wmv3` `snow` … 音频 `aac` `flac` `opus` `vorbis` `dca` `truehd` `eac3` … 字幕 `ass` `ssa` `srt` `subrip` `pgssub` `dvdsub` `dvbsub` `ccaption` `webvtt`
- **渲染通路齐全**：`--enable-vulkan` `--enable-libplacebo` `--enable-filter=libplacebo` `--enable-lcms2` + 12 个 `*_vulkan` 滤镜（`gblur` / `nlmeans` / `overlay` / `bwdif` …）
- 其它：`--enable-libdav1d`（AV1 解码）· `--enable-libuavs3d` · `--enable-gnutls` `--enable-gmp`（TLS）· `--enable-libfreetype` `--enable-libharfbuzz` `--enable-libfribidi` `--enable-libass` + `--enable-filter=ass` `--enable-filter=subtitles`
- 关闭项：`--disable-amf --disable-d3d11va --disable-d3d12va --disable-dxva2 --disable-vaapi --disable-vdpau --disable-xlib`（全平台非 Apple 的硬解后端）

---

## 四、audit 未覆盖项（诚实标注）

| 项 | 状态 |
| --- | --- |
| `Libswscale` / `Libswresample` | **未审计**（各 7.4 MB / 0.8 MB，未下载）。风险低：两者不承载 GPL-only 组件 |
| `MoltenVK` / `Libplacebo` / `Libass` / 字体链 / GnuTLS 链 等 20+ 个第三方库 | **未审计**。它们来自 `mpvkit/*-build` 系列仓库，声明许可为 Apache-2.0 / ISC / MIT / LGPL 等宽松许可 |
| `mpv` 侧的 `-Dgpl=false` | 已在 P0-T1 核实（二进制内含 meson 配置串），**本文不重复** |
| 真机运行验证 | 属 `P0-T5`，不在本 ticket |

---

## 五、构建方式存档（LGPL 合规材料之一）

> LGPL 要求分发时提供「构建方式」。以下是 `Libavutil.xcframework/ios-arm64` 二进制内嵌的完整 configure 行，**原文照录**：

```
--prefix=/Users/runner/work/MPVKit/MPVKit/dist/FFmpeg/ios/thin/arm64 --disable-armv5te --disable-armv6 --disable-armv6t2 --disable-bzlib --disable-gray --disable-iconv --disable-linux-perf --disable-shared --disable-small --disable-symver --disable-xlib --enable-cross-compile --enable-libxml2 --enable-optimizations --enable-pic --enable-runtime-cpudetect --enable-static --enable-thumb --enable-version3 --pkg-config-flags=--static --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages --enable-avcodec --enable-avformat --enable-avutil --enable-network --enable-swresample --enable-swscale --disable-devices --disable-outdevs --disable-indevs --disable-amf --disable-d3d11va --disable-d3d12va --disable-dxva2 --disable-vaapi --disable-vdpau --disable-muxers [白名单 muxer 略] --disable-encoders [白名单 encoder 略] --disable-decoders [白名单 decoder 略] --disable-filters [白名单 filter 略] --disable-debug --enable-stripping --enable-optimizations --disable-large-tests --ignore-tests=TESTS --arch=aarch64 --target-os=darwin --enable-neon --enable-asm --disable-programs --enable-gmp --enable-gnutls --enable-libfreetype --enable-libharfbuzz --enable-libfribidi --enable-libass --enable-filter=ass --enable-filter=subtitles --enable-vulkan --enable-lcms2 --enable-libplacebo --enable-filter=libplacebo --enable-libdav1d --enable-decoder=libdav1d --enable-libuavs3d --enable-decoder=libuavs3d
```

**mpv 侧的 meson 配置（P0-T1 已取，此处并存备查）**：

```
-Dlibmpv=true -Dgl=enabled -Dplain-gl=enabled -Diconv=enabled -Duchardet=enabled -Dvulkan=enabled -Dmoltenvk=enabled
-Djavascript=disabled -Dzimg=disabled -Djpeg=disabled -Dvapoursynth=disabled -Drubberband=disabled
-Dgpl=false -Dlibbluray=enabled -Dcplayer=false -Dvideotoolbox-gl=disabled -Dvideotoolbox-pl=enabled
-Dswift-build=disabled -Daudiounit=enabled -Davfoundation=enabled -Dcoreaudio=disabled -Dlua=disabled -Dios-gl=enabled
```

> mpv 版本 `v0.41.0`；FFmpeg 版本 `n9.0.2`（见 release tag `1.1.0-n9.0.2`）。

---

## 六、可复现命令

```bash
# 1. 下载（Go 代理视网络环境决定）
TAG=1.1.0-n9.0.2
for n in Libavutil Libavcodec Libavfilter Libavformat; do
  curl -sL -o $n.zip "https://github.com/mpvkit/MPVKit/releases/download/$TAG/$n.xcframework.zip"
  unzip -q -o $n.zip
done

# 2. 许可串（决定性证据）
strings -a Libavutil.xcframework/ios-arm64/Libavutil.framework/Libavutil | grep -iE "LGPL version|GPL version"

# 3. configure 行（决定性证据）
strings -a Libavutil.xcframework/ios-arm64/Libavutil.framework/Libavutil | grep -E "^--prefix="

# 4. GPL-only 目标文件
for n in Libavcodec Libavfilter Libavformat; do
  ar -t "$n.xcframework/ios-arm64/$n.framework/$n" | grep -icE 'x264|x265|postproc|vidstab|frei0r|avisynth|zvbi|smbclient'
done

# 5. GPL 外部符号
nm -g Libavcodec.xcframework/ios-arm64/Libavcodec.framework/Libavcodec | grep -iE "x264_|x265_|ff_postprocess"

# 6. 静态/动态
file Libavcodec.xcframework/ios-arm64/Libavcodec.framework/Libavcodec
```

---

## 七、对后续 ticket 的输入

| ticket | 输入 |
| --- | --- |
| `P0-T5` | 自建时**不要传 `--enable-version3`**，目标 = **动态 framework + LGPL-2.1 全链**；同时**必须**把 `--disable-shared --enable-static` 改成动态产出 |
| `P0-T6` | §5 的两段配置串 + §6 的复现命令，直接构成「构建方式」合规材料；另需补 §4 未审计项的核 |
| `P0-T7` | 本文替代 `docs/03` 预告的 `docs/04-libmpv产物实测报告.md`；`docs/04` §4 的 D3 推荐需按「发现 1」修正 |

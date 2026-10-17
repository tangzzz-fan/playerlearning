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

---

## 二、四件交付物（`docs/23` §五 要的那四件）

| # | 交付物 | 文件 | 状态 |
| - | --- | --- | --- |
| 1 | **库的对应源码**（含补丁 + 可复现的构建配置） | [`SOURCE.md`](SOURCE.md) | ✅ |
| 2 | **许可文本与说明** | [`licenses/LGPL-2.1.txt`](licenses/LGPL-2.1.txt) · 本文 §一 | ✅ |
| 3 | **"用户可替换库"的尽力说明** | [`REPLACEABILITY.md`](REPLACEABILITY.md) | ✅ |
| 4 | **修改声明** | [`MODIFICATIONS.md`](MODIFICATIONS.md) | ✅ |

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

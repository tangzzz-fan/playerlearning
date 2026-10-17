# "用户可替换库"的尽力说明（LGPL-2.1 §6）

> **这不是法律结论。** 这份文件只做两件事：说清**我们为了让库可被替换做了什么**，
> 以及**在 iOS 上哪些事我们做不到**。判断留给律师与商务，材料留在这里。

---

## 一、可核对的事实：库是"可替换"的物理形态

| 事实 | 值 | 命令 |
| --- | --- | --- |
| 它是一个**独立的动态库**，不是被静态链进 App 可执行文件 | `PlayerStackDemo.app/Frameworks/Libmpv.framework/Libmpv` | `ls …/PlayerStackDemo.app/Frameworks/` |
| 它的 install_name 走 **`@rpath`**，不是绝对路径 | `@rpath/Libmpv.framework/Libmpv` | `otool -D …/Frameworks/Libmpv.framework/Libmpv` |
| 它**对外还带着完整的头文件**（`mpv/*.h`、`render.h`、`client.h` …） | `Libmpv.framework/Headers/mpv/` | `ls Libmpv.framework/Headers/mpv` |
| 它的第三方依赖**全部在它内部**（FFmpeg 静态链入），链外只剩系统库 | `otool -L` 输出里只有 1 条非系统依赖 | `otool -L …/Frameworks/Libmpv.framework/Libmpv` |

**这四条合起来意味着**：替换 `Libmpv.framework` 这个文件，就替换了整条解码链 ——
不需要改动 App 的可执行文件，也不需要逐个替换 20 多个库。

---

## 二、iOS 上做不到的部分（**必须说清，不能含糊**）

| 做不到 | 为什么 |
| --- | --- |
| 让**终端用户**在已发布的 App 里换掉那个 dylib | App 分发时整个 `.app` 被 Apple 签名并封装；用户手上没有能替换其中文件的通道。iOS 不是桌面系统，没有"装个新 dylib 让旧 App 用"的机制 |
| 保留"用户自行重链接"的完整能力 | iOS 上不存在用户侧的重链接步骤；LGPL-2.1 §6 的"适当共享机制"在移动端没有现成的实现路径 |

这正是 `ksplayer-playbook/D` §4 把它称为**灰区**的原因。我们的做法是：
**把"技术上可替换"做到最彻底，把"分发上的限制"写在明处**，而不是用含糊表述掩盖它。

---

## 三、我们实际做的"尽力"（逐条对应 §6 的意图）

| §6 的意图 | 我们的做法 | 在哪 |
| --- | --- | --- |
| 库必须是**可替换的形态** | 动态 framework + `@rpath` + 独立于 App 可执行文件 | 本文 §一 |
| 必须能拿到**对应源码** | 上游 commit + 三个补丁 + 从真实构建日志提取的 meson 命令行 | [`SOURCE.md`](SOURCE.md) |
| 必须能**重建** | 一条构建命令 + 产物校验命令 | `SOURCE.md` §三 / §四 |
| 必须声明**改了哪些** | 三类改动，含"改了但无影响"的那一条 | [`MODIFICATIONS.md`](MODIFICATIONS.md) |
| 必须提供**许可文本** | LGPL-2.1 全文随分发附带（产物内不含，故外带） | [`licenses/LGPL-2.1.txt`](licenses/LGPL-2.1.txt) |
| 不得**进一步限制**用户权利 | 我们没有对 libmpv 附加任何额外限制条款 | — |

---

## 四、如果被要求，我们能在一小时内拿出什么

| 要求的形态 | 我们有什么 | 还缺什么 |
| --- | --- | --- |
| "给我对应源码" | 本仓库的 `compliance/` + `spike/p0-t5b-lgpl-dynamic-build/`（补丁、构建脚本、构建日志证据） | 一个**对公众可见的下载地址**（人要定） |
| "给我许可文本" | `compliance/licenses/LGPL-2.1.txt`（501 行，sha256 `20e50fe7…d3555d95`） | 商店页/网站上的挂载位置（人要定） |
| "让我能替换它" | 动态 framework + 头文件 + 重建步骤 | iOS 上与"签名分发"的冲突无法由我们解决 |
| "你们改了什么" | `MODIFICATIONS.md`（三类，逐条带影响） | — |

---

## 五、一句提醒（`D` §7）

**编解码专利池（H.264 / HEVC）与 LGPL 是两件不相干的事。**
"我们用了 LGPL-2.1、也交了源码"**不等于**"没有专利授权问题"。
本目录不处理、也不减轻那一类风险。

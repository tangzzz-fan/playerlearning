# PITFALLS 日志

> **规则**（来自 [`docs/03`](03-路线图.md) §四）：**每踩一个坑即落一条**，不等阶段性总结。
> **写法**：现象 → 根因 → 处置 → 防再犯。
> **维护**：新坑追加在末尾，编号不复用。条目一旦解决不删除，保留为"曾经踩过"的证据。

---

## P-001 · SPM 会下载 package 里**全部** `.binaryTarget`

**现象**：引入 MPVKit 时，SPM 缓存里出现 `Libmpv_GPL_xcframework_zip`、`Libavutil_GPL_xcframework_zip` 等**带 `_GPL` 后缀**的文件 —— 我们并不想用 GPL 档。

**根因**：SPM 解析依赖时会下载 `.binaryTarget(url:)` 声明的**所有**产物，它无法预判最终会用哪个 target/product。

**处置**：确认**实际链接**的是哪个 product（查 `project.pbxproj` 里的 `MPVKit` 引用），别被缓存文件名误导。

**防再犯**：看**链接结果**（`otool -L` / `nm -u`），不看**下载缓存**。

---

## P-002 · `raw.githubusercontent.com` 在此网络极不稳

**现象**：20.9 MB 的 mkv 素材**两次**下载被超时截断，只拿到 256 KB（无报错，文件看似存在）。

**根因**：`raw.githubusercontent.com` 走 CDN，长连接易被中断，且 `curl` 无 `--retry` 时静默返回部分内容。

**处置**：改用 **jsDelivr** —— `https://cdn.jsdelivr.net/gh/<owner>/<repo>@<ref>/<path>`，1 分钟下完。

**防再犯**：① 大文件尽量走 jsDelivr；② **下完必须 `file` 校验**（`Matroska data` vs 256 KB 的残片）；③ 加 `--retry 5 --retry-delay 3`。

---

## P-003 · 真机 `devicectl` 的两个坑

**现象 A**：`devicectl device process launch` 报 `the device was not, or could not be, unlocked`。
**现象 B**：`devicectl device capture screenshot --output X` 失败。

**根因**：A —— 真机 launch **要求设备已解锁且亮屏**（自动锁屏后立刻失效）；B —— 参数名是 `--destination`，不是 `--output`。

**处置**：A —— 用**轮询重试**（每 3 秒一次，最多 5 分钟）扛过锁屏窗口；B —— 用 `--destination <path>`。

**防再犯**：真机脚本一律**内建 launch 重试循环**，不要期待一次成功。

---

## P-004 · 签名身份里的 **OU 字段不是 Team ID**

**现象**：用 `security find-certificate` 读出的 `88D39V32YV` 当 `DEVELOPMENT_TEAM` 用，构建签名失败。

**根因**：`88D39V32YV` 是证书的**成员 ID（organizationalUnit）**，不是 Team ID。

**处置**：Team ID 从 Xcode 配置读 —— `defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists`。本机实际有 `YXFC65VYTW`（个人）与 `3GMJYX32U9`（公司）。

**防再犯**：Team ID 只从 Xcode 账号配置取，不从证书字段猜。

---

## P-005 · dylib 的 `install_name` 默认是**构建目录的绝对路径**

**现象**：自建的 `Libmpv.framework/Libmpv` 一旦装进 App 就崩（`Library not loaded`）。

**根因**：mpvkit 的流水线产出的 `install_name` 是
`/private/tmp/.../dist/libmpv/ios/thin/arm64/lib/libmpv.2.dylib` —— 一个指向**构建机临时目录**的绝对路径。

**处置**：打包后必须跑 `install_name_tool -id "@rpath/Libmpv.framework/Libmpv"`（已落成 `spike/p0-t5b-lgpl-dynamic-build/postprocess-framework.sh`），且 App 侧要有 `@executable_path/Frameworks` 这条 rpath。

**防再犯**：**任何自建 dylib 都必须核 `otool -D`**；`install_name` 不是 `@rpath/...` 就是定时炸弹。

---

## P-006 · ⚠️ `strings` 命中**不能**作为链接证据，`nm -u` 才能

**现象**：对产物扫 `strings` 报 `gnutls` 1 处、`gmp` 4 处、`x264` 7 处、`vdpau` 14 处 —— 看起来像许可污染。

**根因**：全部是误报，各有不同来路：

| 命中 | 真实来路 |
| --- | --- |
| `gnutls` | FFmpeg 的**错误提示文案**（`https or dtls protocol not found, recompile FFmpeg with openssl, gnutls or securetransport enabled.`） |
| `gmp` | base64 数据块与 MIME 串里的**随机字节巧合** |
| `x264` | mpv 选项名（`vd-lavc-assume-old-x264`）+ h264 解码器**读 SEI 里编码器版本**的字符串 |
| `vdpau` | 产物**自带的 configure 行**（里面写着 `--disable-vdpau`）+ OpenGL 扩展名（`glVDPAURegisterVideoSurfaceNV`） |

**判定**：`nm -u` 的 **920 个导入符号里零命中** ⇒ 无真实链接。

**防再犯**：**许可核查一律以 `nm -u`（未定义符号）为准**；`strings` 只用来**找线索**，不用来下结论。这条能省掉每次几十分钟的重复排查。

---

## P-007 · FFmpeg 5+ 把协议/编解码开关移到了 `config_components.h`

**现象**：用 `grep CONFIG_HTTPS_PROTOCOL config.h` 检查 TLS 是否启用，**返回空**，误判为"没启用"。

**根因**：FFmpeg ≥ 5.0 把 decoder / encoder / muxer / demuxer / protocol 的开关放进 **`config_components.h`**；`config.h` 只留库级与特性级配置（如 `CONFIG_SECURETRANSPORT`）。

**处置**：查协议看 `config_components.h`，查特性看 `config.h`。

**防再犯**：核查 FFmpeg 特性时**两个文件都看**。

---

## P-008 · mpvkit 的 `buildALL()` **没有跳过逻辑**

**现象**：只改了 1 个构建参数，却要等 20 分钟全量重跑。

**根因**：`base.swift` L141 每个库的 `buildALL()` 开头就是
`try? FileManager.default.removeItem(at: URL.currentDirectory + library.rawValue)` —— **先删再建**，且 meson 对已配置目录会报错，无法增量。

**处置**：接受全量重跑；源码包有缓存时约 5 分钟，冷启动约 20 分钟。

**防再犯**：**改构建脚本前先把验证成本算进去** —— 能先做 40 秒的 `configure` 干跑就不要盲跑全量（见 P-011 的做法）。

---

## P-009 · mpvkit 构建脚本**硬编码 PATH**

**现象**：想用 shell PATH 前置把 meson 切到指定版本，无效。

**根因**：`BaseBuild.defaultPath` 硬编码为
`/Library/Frameworks/Python.framework/Versions/Current/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`。

**处置**：所幸 **mpv 只要求 `meson_version: '>=1.3.0'`（只有下限无上限）**，本机 1.12.1 直接满足 —— 不需要 pin CI 的 1.4.2。

**防再犯**：读构建脚本时**先找硬编码的 PATH / 环境变量**，再判断"能不能靠 shell 覆盖"。

---

## P-010 · 复用公司团队的 **wildcard 描述文件**可以免建 App ID

**现象**：真机部署需要签名，但不想在公司账号里新建 App ID / 描述文件。

**根因**：本机已存在 `3GMJYX32U9.*` 的 **wildcard 描述文件**，可部署**任意** bundle id。

**处置**：直接用 `DEVELOPMENT_TEAM = 3GMJYX32U9` + 任意 bundle id（spike 用 `com.p0t5b.*`）。

**防再犯**：spike / 一次性验证**一律用 wildcard**，不在公司账号留下垃圾资源。

---

## P-011 · 「压回 LGPL-2.1」的门槛是**依赖链**，不是开关

**现象**：把 FFmpeg 的 `--enable-version3` 去掉后，configure **直接报错拒绝**：
`gmp is version3 and --enable-version3 is not specified.`

**根因**：`--enable-version3` 只是**声明**；真正要求 v3 的是**被链进来的库**。
链路是：`--enable-gnutls` → `nettle`（LGPLv3+/GPLv2+）→ `gmp`（同）。三者任一被静态链入，产物就**必然**是 LGPLv3。

**处置**：把 TLS 后端从 GnuTLS 换成 Apple 系统 **SecureTransport**（`Security.framework`），整条 v3 链消失 ⇒ 产物自报 `LGPL version 2.1 or later`。

**防再犯**：**改许可声明之前，先把依赖图走一遍**。开关是果，依赖是因。

---

## P-012 · SPM **拒绝空 target** ⇒ 骨架票必然要带上每个模块的第一个真实类型

**现象**：`P1-T1` 只想建 `PlayerCore` / `PlayerUI` 两个空 target 做骨架，`swift build` 直接失败。

**根因**：SPM 规定 target 必须至少有一个源文件（`target 'X' referenced in product 'X' is empty`）。

**处置**：骨架票必须**同时落地每个模块的第一个真实类型** —— 本票落的是 `PlayerResource`（`PlayerCore`，`Sendable` 值类型）与 `PlayerRootView`（`PlayerUI`，App shell 的根视图）。

**防再犯**：**拆 ticket 时不要把"建工程"单独拆成一张票** —— 它天然与"第一个类型的落地"绑定。这是 `P1-T1` 与 `P1-T2` 在文件层面必然有重叠的唯一原因。

---

## P-013 · Swift 协议元类型的拼写：`P.Type` 才对，`(any P).Type` 是**另一个类型**

**现象**：注册表写 `var kernelTypes: [(any PlayerKernelProtocol).Type]`，测试里 `[StubA.self, StubB.self]` 直接报
`cannot convert value of type 'A.Type' to expected element type '(any P).Type'`，并且后续 `ObjectIdentifier` / `init()` 全崩。

**根因**：`P.Type`（协议的**存在元类型**，任意 conformer 的 `X.self` 都能放进去）与 `(any P).Type`（**存在类型的元类型**，是另一种东西）不是同一个类型。写成带括号的形式就把语义换掉了。

**处置**：统一用 `[any P.Type]` 或 `[P.Type]`。而且实测**两个额外事实**（都用最小探针验证过，不是猜）：
- 元类型**直接支持 `==`** ⇒ 不需要 `ObjectIdentifier` 绕路
- 从元类型**可以实例化**：`type.init()` ⇒ 协议里的 `init()` 需求是有意义的（注册表存"类型"、用时再实例化这条路走得通）

**防再犯**：涉及元类型 / 存在类型 / `any` 放置位置时，**先写 10 行探针验证**，不要在测试文件里边写边试（试错成本会被类型推断的错误信息放大）。

---

## P-014 · ⚠️ `AsyncStream` 的测试若**不给流收尾**，会永久挂死（而不是失败）

**现象**：变异测试里"删掉一次 `emit`"的变异体没被判死 —— 套件**卡住了**，6 分钟不动。

**根因**：`AsyncStream.next()` 在**没有新值且流未 finish** 时**永久 await**。测试写的 `await iterator.next()` 期望 2 个事件，实际只有 1 个 ⇒ 第二次 `next()` 永远等下去。于是变异体表现成"挂死"，而不是"失败"。

**处置**：给 fake 加**显式的流收尾** `finishEvents()`（`continuation.finish()` 并置空），并在测试里：
1. 动作做完后调 `finishEvents()`
2. 排空事件
3. **再断言一次 `XCTAssertNil(await iterator.next())`** —— 既证明"没有多余事件"，又保证不会挂死

**防再犯**：**任何以 `AsyncStream` 为边界的测试，都必须能"收尾 + 排空 + 断言 nil"**。否则它只有两种结局：过，或挂死。

---

## P-015 · 变异检查工具必须**崩溃安全**（否则强杀会把源文件留在变异态）

**现象**：`mutation_check.py` 因 P-014 挂死，被 `pkill` 之后，`FakeKernel.swift` **真的停留在变异态**
（`emit(.stateChanged(.readyToPlay))` 被删掉了）—— 因为 `finally` 没跑完。

**根因**：只靠 `try/finally` 还原，遇到 SIGKILL / 强杀 / 崩溃就失效；而且变异是**就地改写源文件**。

**处置**（`Tools/mutation_check.py` 已落成）：
1. **持久备份目录** `.mutation-backup/`（已 gitignore），不依赖进程存活
2. **启动自愈**：开跑前若发现备份残留 ⇒ 先还原（上次崩了）
3. **信号处理**：`SIGINT` / `SIGTERM` / `SIGHUP` 先还原再退出
4. **每个变异体带测试超时**（`subprocess timeout`）⇒ 挂死被判为 `TIMEOUT` 并计入**不通过**，而不是无限等
5. 每轮变异后立刻从备份回写，不等到最后
6. 支持 `--restore` 手动还原

**防再犯**：**任何"就地改源文件再跑"的工具，都必须先回答"进程被杀时会怎样"**。

---

## P-016 · 一个初始化器缺参错误，会**级联**出一串看似无关的假错误

**现象**：`FakeKernel(loadError: e)` 缺 `duration` 参数，编译器同时报出
`type 'Equatable' has no member 'failed'`、`no 'async' operations occur within 'await' expression` —— 看起来像枚举和并发出了问题。

**根因**：`FakeKernel(...)` 解析失败 ⇒ `kernel` 的类型未定 ⇒ 后续 `kernel.snapshot()` / `kernel.loadedResources` 全部推断失败 ⇒ 错误信息荒谬化。

**处置**：**从第一条错误开始修**。本例只改一处（给初始化器加默认值），4 个"错误"一次全消。

**防再犯**：**修编译错误只看第一条**。后续错误在高置信度上都是噪声。


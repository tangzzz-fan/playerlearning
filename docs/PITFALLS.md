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

> **补充（2026-10-13，`P1-T4` 遇到的约束）**：**`AsyncStream` 只能有一个消费者** —— 两个 `for await` 循环订阅同一个流会**互相抢事件**（不是广播）。
> 影响：`PlayerTimeModel.updates(from:)` 的签名因此是"**一个事件流 → 一个更新流**"。若将来需要多处订阅同一内核事件流，必须在更上游做**扇出**，而不是各自订阅。

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

> ### 📌 2026-10-13 补充：**SIGKILL / 会话中断**这一路，信号处理兜不住 —— 必须靠"事后核对"
>
> **实际发生**：`./Tools/gate.sh` 在后台跑变异检查时，**整个会话被中断**（进程收到 SIGKILL）。
> `SIGKILL` **不可捕获** ⇒ `guard()` 没机会执行 ⇒ 源文件**真的留在了变异态**：
>
> ```diff
>  Sources/PlayerCore/FakeKernel.swift
> -        emit(.stateChanged(.readyToPlay))
> +
> ```
>
> **发现方式**（不是设计出来的，是撞上的）：之后跑测试，**5 个与本次改动毫无关系的既有用例集体失败**，
> 证据是 `snapshot.state → .preparing` —— 正好对应变异体「fake: load 不再上报 .readyToPlay」。
> 由此反推出"源文件在变异态"，`git diff Sources/` 一分钟内定位。
>
> **最有价值的一点**：故障的表象是**"5 个不相关的测试挂了"**，很容易被误判成"刚才改的东西有问题"。
> 判据是**相关性**：改动只碰测试框架，却让"内核状态机"类用例挂掉 ⇒ **先怀疑工作区，不要先怀疑自己的改动**。
>
> **防再犯（追加两条）**：
> 7. **会话中断 / 强杀之后，第一件事是 `git diff Sources/`（或 `git status --short`）**，再谈跑测试。
> 8. `Tools/mutation_check.py --restore` 是**幂等**的兜底入口（备份目录在，就能全量还原）；备份是**持久**的，不依赖进程存活 —— 这正是第 5 条设计的回报。
>
> ⇒ 结论修正：**崩溃安全设计能让"可恢复"，但恢复动作必须由人/流程触发。** 工具只能保证"备份还在"。

---

## P-016 · 一个初始化器缺参错误，会**级联**出一串看似无关的假错误

**现象**：`FakeKernel(loadError: e)` 缺 `duration` 参数，编译器同时报出
`type 'Equatable' has no member 'failed'`、`no 'async' operations occur within 'await' expression` —— 看起来像枚举和并发出了问题。

**根因**：`FakeKernel(...)` 解析失败 ⇒ `kernel` 的类型未定 ⇒ 后续 `kernel.snapshot()` / `kernel.loadedResources` 全部推断失败 ⇒ 错误信息荒谬化。

**处置**：**从第一条错误开始修**。本例只改一处（给初始化器加默认值），4 个"错误"一次全消。

**防再犯**：**修编译错误只看第一条**。后续错误在高置信度上都是噪声。

---

## P-017 · 变异体存活有**两种截然不同**的原因，别条件反射地补测试

**现象**：状态机的变异体「`canTransition` 忽略同态判定」**存活** —— 把
`newState != state && Self.isLegal(...)` 改成只留 `Self.isLegal(...)`，测试全绿。

**根因**：那个守卫是**死代码**。`isLegal` 的表里根本没有 `(x, x)` 分支，自迁移一律落到 `default: false`，所以 `newState != state` 这个前置条件**永远不改变结果**。

**处置**：**不是补测试，是删代码** —— 而且更好的做法是**让两处逻辑同源**：
把判定收进一个私有方法 `outcome(for:)`，`canTransition` 与 `transition` 都从它取结果。这样"查询与实际结果必须一致"从"要靠测试守着"变成"结构上不可能不一致"。

**防再犯**：变异体存活先问一句 —— **"把变异体代入后，逻辑上真的改变了行为吗？"**

| 判定 | 处置 |
| --- | --- |
| 真改变了行为，但测试没抓到 | **补测试**（这才是覆盖不足） |
| 没改变行为（等价变异 / 死代码） | **删那行代码**。补测试是徒劳 —— 它永远杀不死等价变异 |

> 次要收益：这类"存活"其实是最有价值的信号之一。它把**没人敢删的冗余**指了出来 —— 本次靠它删掉了一个真实存在的冗余守卫。

> **反例（不适用于上一条，别误删）**：`P1-T4` 的 `guard !seconds.isNaN else { return 0 }` 是**等价变异** —— 因为 Swift 的 `Swift.max(0, .nan)` 恰好返回 `0`，删掉守卫结果不变。
> 但**这条不能删**：它依赖的是 `max` 对 NaN 的**未定义/未承诺**行为。守卫的作用是把"**恰好对**"变成"**明确对**"。
> ⇒ 判据要加半句：**"逻辑上真改变行为吗？如果没改 —— 行为是*被规定*的，还是*恰好*对的？"** 恰好对的，保留守卫并补一条测试把语义钉住。

---

## P-018 · 单元测试各自全绿 ≠ 部件能组合（集成测试首跑 8/8 全崩）

**现象**：`P1-T5` 写下第一条集成测试（`FakeKernel` → `PlayerStateMachine` + `PlayerTimeModel`），**8 个测试全失败**，证据非常集中：

```
不应出现被拒的状态：[.readyToPlay, .playing, .paused, .playing]
```

**根因**：`FakeKernel.load()` **跳过了 `.preparing`**，直接发 `idle → readyToPlay`；而状态机的迁移表（正确地）只允许 `idle → preparing`。
关键点是：**两边的单元测试各自都过** —— 因为它们测的都是**自己的内部一致性**，没有任何一条测试在测**两者的接口约定**。

**处置**：**修 fake 让它保真**（`load` 先发 `.preparing`），**而不是放宽状态机**。
理由：放宽状态机会"永久掩盖"这类序列缺陷，而修 fake 只是让替身更接近真内核 —— 真内核本来就是 `load → preparing → readyToPlay`。

**防再犯**：
1. **单元测试全绿不等于部件能组合。** 对每一对"边界 + 消费者"至少写一条集成测试（本项目的缝正是 `PlayerKernelProtocol`，所以"内核 → 状态机 / 时间模型"必须各有一条）。
2. **测试替身要保真到状态序列**，不只是方法签名。签名对了、序列错了，是最难查的一类假绿。

---

## P-019 · macOS 没有 `timeout`（那是 GNU coreutils），而且**它静默失败**

**现象**：`timeout 180 swift test ... | grep -E "..."` 输出为空。我把它读成"跑了，但没有匹配行"，于是又跑了一遍并开始怀疑测试挂死。

**根因**：macOS 是 BSD userland，**没有 `timeout` 命令**。它报的 `command not found` 进了 stderr，而我的管道只过滤 stdout ⇒ **看起来像"命令跑了但没结果"**。

**处置**：不要依赖 `timeout`。需要超时就用：① 工具自带的超时（Python `subprocess.run(timeout=)` 可用，`Tools/mutation_check.py` 就是这么做的）；② `perl -e 'alarm 180; exec @ARGV' -- <cmd>`。

**防再犯**：⚠️ **管道里"空输出"不等于"没有结果"** —— 空输出时**先确认命令真的执行过**（看 `$?`、看 stderr、或先不加管道跑一次）。
> 这条和 `P-014` 是同一类错误的两副面孔：**把"没有现象"当成"没有发生"**。

---

## P-020 · ⚠️⚠️ `cmd > file` 里 `cmd` 不存在时，**重定向照样执行** —— 本次把仓库根的 `Package.swift` 截成 0 字节

**现象**：构建报 `error: '/Users/jove/Developments/playerlearning/Package.swift' is empty`。查证：**仓库根的 `Package.swift` 变成 0 字节**，时间戳与一次探针脚本的运行时刻完全一致。

**根因**：那个探针脚本干了这件事：

```bash
rm -rf /tmp/probe-X && mkdir -p /tmp/probe-X/Sources/A && cd /tmp/probe-X
cat > Package.swift <<EOF
...
EOF
```

沙箱的 `rm` shim 失败了，随后 `mkdir` **也报 command not found** ⇒ **`cd` 失败，CWD 仍是仓库根**。
而 `cat` 同样 `command not found` ⇒ **`cat` 从未运行** —— 但 shell **已经先执行了 `> Package.swift` 这个重定向**，把**仓库根**那个同名文件清零了。

**这就是最阴的地方**：命令没跑，**文件却已经被动**，而且没有任何报错指向它。

**处置**：
1. `git checkout -- Package.swift` 还原（**已跟踪文件 = git 是最强兜底**）。
2. 全面查损：`git status --short` + `find . -name "*.swift" -size 0`。结论：**只有 `Package.swift` 受损**（`Sources/A/A.swift` 因目标目录不存在，重定向本身就失败了，未创建）。
3. 根包门禁复跑：`./Tools/gate.sh` → **G1 达成**，无残留影响。

**防再犯（四条，都要）**：
1. **探针/临时脚本写文件一律用绝对路径** —— 绝不"先 `cd` 再相对写"。
2. **`>` 的危险性独立于命令是否存在**："命令没跑"**不等于**"文件没被动"。
3. **在仓库内跑临时脚本本身就是高危**：优先在 `/tmp` 用绝对路径；能用编辑器/写文件工具就别用 heredoc。
4. **危险操作后立刻 `git status --short` 核对** —— 本次正是靠它发现的。已跟踪文件让损失可控，**这条是最后一道防线**。

---

## P-021 · SPM 的**路径依赖标识是「目录名」**，不是 manifest 里的 `name`

**现象**：
```
error: unknown package 'PlayerStack' in dependencies of target 'PlayerMPV';
       valid packages are: 'playerlearning' (at '/Users/jove/Developments/playerlearning')
```

**根因**：对 `.package(path:)`，SPM 用**目录名**作为 package identity，**manifest 里的 `name: "PlayerStack"` 不参与**。
⇒ 直接写 `.product(name: "PlayerCore", package: "PlayerStack")` 解析失败；而裸字符串（`.byName`）在跨包时同样不可靠。

**处置**：**显式命名路径依赖**，把标识与目录名解耦：

```swift
dependencies: [.package(name: "PlayerStack", path: "..")]
// 之后
.product(name: "PlayerCore", package: "PlayerStack")
```

**防再犯**：跨包引用**一律用 `.package(name:path:)` + `.product(name:package:)`**。
顺带一个后果值得记：如果只写 `.package(path: "..")`，**仓库目录一改名，`MPV/Package.swift` 就会断** —— 而仓库命名（`D1`）目前还没定。

---

## P-022 · actor 的 `deinit` 访问不了非 `Sendable` 的隔离状态

**现象**：
```
error: cannot access property 'handle' with a non-Sendable type 'OpaquePointer?' from nonisolated deinit
```

**根因**：actor 的 `deinit` 是 `nonisolated`，而 `OpaquePointer?` 不是 `Sendable`。

**处置**：**不要用 `nonisolated(unsafe)` 绕**（那是把安全洞焊进代码）。改用**所有权持有者**：

```swift
private final class MPVHandleOwner: @unchecked Sendable {
    let pointer: OpaquePointer
    deinit {
        mpv_set_wakeup_callback(pointer, nil, nil)
        mpv_terminate_destroy(pointer)
    }
}
```

actor 只持有一个 `var owner: MPVHandleOwner?` ⇒ **释放时机自动跟随生命周期**，`@unchecked` 也是成立的（`let` 指针 + 访问由 actor 串行化）。

**防再犯**：包装 C 资源时，**把"释放"放进一个拥有所有权的引用类型**，而不是依赖调用方记得调 `shutdown()`。
> 显式 cleanup 一定会被忘记；`deinit` 不会被忘记。另外：这个模式让 `shutdown()` 退化成"把 `owner` 置 nil"，不再需要自己管两套路径。

---

## P-023 · ⚠️ `swift test` 的 "All tests" 小结是**按 test bundle 各打一次**，取最后一行会**少算**

**现象**：加了 `PlayerUITests`（9 条）后，`swift test | tail` 显示 **75 tests** —— 与加之前**一模一样**。一度以为新 target 没被执行（`--list-tests` 明明能看到那 9 条）。

**根因**：SPM 会为**每个 test bundle** 各自跑一遍并各打一次 `Test Suite 'All tests'` 小结。实际输出是：

```
Test Suite 'PlayerUITests.xctest' passed
	 Executed 9 tests, with 0 failures          ← bundle 1
Test Suite 'All tests' passed
	 Executed 9 tests, with 0 failures
	 …（PlayerCoreTests 的各 suite）
Test Suite 'PlayerCoreTests.xctest' passed
	 Executed 75 tests, with 0 failures         ← bundle 2
Test Suite 'All tests' passed
	 Executed 75 tests, with 0 failures         ← 这是"最后一行"，但它只是 bundle 2
```

⇒ `tail -1` 拿到的是**最后一个 bundle 的小结**，不是全局总数。真实总数是 **84（75 + 9）**。

**处置**：`Tools/gate.sh` 改为**按 bundle 配对后求和**（`grep -A1 "'*.xctest' passed"` → 提取计数 → `awk` 求和），并打印 bundle 数以便核对。

**防再犯**：**报测试数不要用 `tail -1`**。要么按 bundle 汇总，要么用 `swift test --list-tests | grep -c` 直接数条目。
> 这条与 `P-014`/`P-019` 同族：**"看起来没变" 不等于 "没发生"**。凡是"改动后数字完全没动"，先怀疑**采集方式**，而不是接受结论。

---

## P-024 · ⚠️ 受限 shell 里 SwiftPM **直接失败**，而报错正文指向的是 `Package.swift`

**现象**：`swift build` / `swift test` 报

```
error: 'playerlearning': Invalid manifest (compiled with: ["…/swiftc", "-vfsoverlay", …, "Package.swift", "-o", "…/playerlearning-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
```

正文写着 **「Invalid manifest」并打印一整行 swiftc 命令** —— 极易被读成"`Package.swift` 写错了"，于是去改 manifest。

**根因**：本会话的 shell 已经在**受限 profile** 里，而 macOS **不允许在受限进程里再 apply 一层 deny-default 沙箱**。SwiftPM 编译清单 / 跑插件时会自己套沙箱 ⇒ **内层那次 apply 被拒**。`Package.swift` 本身没问题。

**处置**：命令后加 `--disable-sandbox` 立刻恢复（实测 `Build complete! (9.21秒)`）。已落成脚本内建：

| 文件 | 做法 |
| --- | --- |
| `Tools/gate.sh` | 开头 probe，失败则给 `swift build` / `swift test` 都补 `--disable-sandbox`，并打印一行提示 |
| `Tools/mutation_check.py` | `swift_escape_args()` 同一 probe，注入 `["swift", "test", *args]` |

**判据**（一条命令，别猜）：

```bash
sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok
# 退出码 0        ⇒ 不需要逃逸参数
# 非 0（本机 71）  ⇒ 需要
```

**防再犯**：
1. 看到 **`Invalid manifest` 先往日志末尾找 `sandbox_apply`** —— 别去改 `Package.swift`。
2. 两个脚本都写成**条件式**（probe 通过就是 no-op）⇒ 正常终端与受限 shell 都能跑。
3. ⚠️ **绝不把这个参数写进工程文件**（`Package.swift` / `project.yml` / scheme）—— 那会削弱正常终端与发版构建的隔离。**它只属于"这一次命令"。**

> 与 `P-019`/`P-023` 同族但**方向相反**：那两条是"空输出被当成没发生"，这条是**"报错正文指错了地方"**。共同点：**症状与根因差一层，别停在第一句。**
> 沙箱逃逸这一段知识的正文在技能 `apple-build-sandbox`，本项目的两个脚本是它的落地。

---

## P-025 · ⚠️ `#expect` 不能直接比较**存在元类型**（`any P.Type`），尽管普通表达式可以

**背景**：测试框架由 XCTest 迁移到 **Swift Testing** 时，机械改写断言并**不代表语义等价**。

**现象**：把

```swift
XCTAssertTrue(registry.kernelTypes[0] == KernelStub<StubTagB>.self)   // ✅ 能编译
```

改成

```swift
#expect(registry.kernelTypes[0] == KernelStub<StubTagB>.self)          // ❌ 编译失败
```

报

```
macro expansion #expect:1:61: error: binary operator '==' cannot be applied to operands of type
'any PlayerKernelProtocol' and 'any PlayerKernelProtocol.Type'
```

**根因**：`#expect` 的宏展开会把**两个操作数各自捕获成变量**（便于失败时打印子表达式值），
存在元类型的 `==` 推断因此断裂。**同样的表达式写在普通函数里完全合法** —— 这是探针实测，不是猜：

```swift
protocol P { init() }
struct A: P { init() {} }
let arr: [any P.Type] = [A.self]
let x: any P.Type = A.self

arr[0] == x                                                          // ✅ true（普通表达式）
func same(_ l: any P.Type, _ r: any P.Type) -> Bool { l == r }
same(arr[0], x)                                                      // ✅ true（包一层函数）
```

> 顺带修正 `P-013` 的措辞：**具体**元类型（`X.Type`）支持 `==`；本条的坑出在**存在**元类型（`any P.Type`）上，
> 且只在**宏展开**的环境里触发。

**处置**：**包一层普通函数**，让宏只看到一个 `Bool`（`Tests/PlayerCoreTests/PlayerKernelRegistryTests.swift`）：

```swift
private func isSameKernelType(
    _ lhs: (any PlayerKernelProtocol.Type)?,
    _ rhs: any PlayerKernelProtocol.Type
) -> Bool {
    guard let lhs else { return false }
    return lhs == rhs
}
```

参数用 `Optional` 而不是在调用处写 `first ?? SomeType.self`：**兜底会把 nil 掩盖成假绿**。

**防再犯**：
1. **元类型 / 存在类型（`any`）/ 元类型数组**出现在断言里 ⇒ 先写探针（同 `P-013`），别在测试文件里边写边试。
2. **迁移断言框架时，"能编译"与"断言等价"是两件事。** 宏会改变表达式的类型推断环境 —— 这类错误只在编译期暴露，不会伪装成"测试通过"，已经是运气好的那种。

---

## P-026 · 迁移到 Swift Testing 的四处连带改动（框架换了，管道也得换）

**背景**：项目测试由 XCTest 全部改为 **Swift Testing**（`@Test` / `#expect` / `#require`，`@Suite`）。断言只是第一层，还有四处会连带断。

| # | 连带项 | 症状 / 原因 | 处置 |
| --- | --- | --- | --- |
| 1 | **门禁的计数解析** | XCTest 是 `Executed 75 tests, with 0 failures`；Swift Testing 是单行 `✔ Test run with 94 tests in 9 suites passed after …`。旧正则匹配不到 ⇒ 旧 `gate.sh` 打印空计数 | 换正则；**并且必须校验"真的取到了汇总行"**，取不到就 `fail` |
| 2 | **默认并行执行** | XCTest 是串行的；Swift Testing **默认并行**。触及 `CAMetalLayer` / Metal / 全局共享状态的套件可能因此 flakey | 给这类套件显式加 `@Suite(.serialized)`（本例 `WindowEmbedOutputTests`） |
| 3 | **`XCTestExpectation` 没有对应物** | `expectation(description:)` / `wait(for:timeout:)` 不存在 | 换 `withCheckedContinuation`（本例）或 `confirmation`。跨线程回调还要处理非 `Sendable` 捕获 |
| 4 | **`XCTUnwrap` → `try #require`** | 逐处改写 | 注意 `#require` 也受第 1 类宏展开限制（见 `P-025`） |

**第 1 条最危险，值得单独说**：它属于 `P-023` 家族 —— **"退出码 0"不等于"测试跑了"**。
如果只换正则不校验，一旦正则失配，门禁会**打印空计数却依然判绿**。所以 `gate.sh` 现在是：

```bash
summary="$(grep -Eo 'Test run with [0-9]+ tests?( in [0-9]+ suites?)? (passed|failed)[^.]*' /tmp/gate-test.log | tail -1 || true)"
if [ -z "$summary" ]; then
  tail -20 /tmp/gate-test.log
  fail '未找到测试汇总行 —— 测试可能根本没执行（P-023 / P-026）'
fi
```

> ### 📌 补充：这条**第一次是踩出来的**，而且踩的方式比正则本身更值钱
>
> 第一版正则写的是 `'Test run with [0-9]+ tests? (passed|failed)[^.]*'`
> —— **没算上 Swift Testing 汇总行里的 ` in 9 suites`**，于是一条都匹配不到。
>
> 结果不是"打出空计数"，而是**整个门禁在 `[3/4] swift test` 之后无声退出，退出码 1，
> 一行错误信息都没有**。原因：
>
> ```
> set -euo pipefail
> summary="$(grep -Eo '…' /tmp/gate-test.log | tail -1)"   # grep 无匹配 ⇒ 退出码 1
>                                                          # ⇒ pipefail ⇒ 管道 1
>                                                          # ⇒ $() 赋值失败 ⇒ set -e 终止脚本
> ```
>
> **三个开关（`-e` / `-u` / `pipefail`）叠在一起，把"没匹配到"放大成了"脚本静默死掉"。**
> 而且死因**写在日志之后**，看起来像"卡在跑测试"。
>
> **修法有两层，缺一不可**：① 正则容下 ` in N suites`；② **`|| true` 兜住**，把"没取到"交给显式的 `if [ -z ]` 分支报错。
>
> **防再犯（追加）**：**凡是 `$( … | grep … )` 形式的赋值，都要问一句"没匹配时会怎样"**。
> 在 `set -euo pipefail` 下答案是"静默死" —— 要么 `|| true` + 显式判空，要么干脆别用管道。
> 这条与 `P-019`（空输出 ≠ 没发生）是同一族：**没有报错的退出，比报错更难查。**

> ### 📌 追加 2：`P-023` 的坑**没有因为换框架而消失，只是换了签名**
>
> 修完上面两个坑之后，门禁打印出 `Test run with 86 tests` —— 而实际是 **95 条**（86 + 9）。
>
> **根因与 `P-023` 一模一样**：`swift test` 会为**每个 test bundle** 各打一行
> `Test run with N tests …`，所以 `tail -1` 只拿到**最后一个 bundle**，剩下的被丢掉。
> XCtest 时代那行叫 `Executed N tests, with 0 failures`；换成 Swift Testing 之后叫
> `Test run with N tests in M suites passed after …` —— **格式换了，按 bundle 各打一次的机制没换。**
>
> ⇒ 门禁改为**跨所有 run 求和**，并且核对 run 数：
>
> ```bash
> runs="$(grep -cE 'Test run with [0-9]+ tests?' /tmp/gate-test.log || true)"
> [ "${runs:-0}" -eq 0 ] && fail '未找到任何测试汇总行 —— 测试可能根本没执行'
> total="$(grep -Eo 'Test run with [0-9]+ tests?' /tmp/gate-test.log | grep -Eo '[0-9]+' | awk '{s+=$1} END {print s+0}')"
> failedRuns="$(grep -E 'Test run with [0-9]+ tests?' /tmp/gate-test.log | grep -c 'failed' || true)"
> ```
>
> **教训（比结果值钱）**：**"换个框架"时，要按「机制」而不是「字符串」去想兼容性。**
> 我第一版只把 `Executed N tests` 换成 `Test run with N tests`，**机制层面的"按 bundle 重复输出"被漏掉了** ——
> 于是同一个坑以新面目又踩一次。`P-023` 的正文至今有效，它的**签名会随工具链变**。

**防再犯**：**换测试框架 = 换门禁管道**。改断言的同时，把 `gate.sh` / `mutation_check.py` 的解析与超时策略一起过一遍。

---

---

# 📥 移植区：来自其他项目的通用坑（2026-10-13）

> **来源项目**：`Marquee`（`docs/PITFALLS.md`，E/F/G/R/V 各节）· `HabitLoop`（`docs/PITFALLS.md`，12 条）·
> `Self-Skills-Init/meta/inbox/pitfalls-2026-10-03.md`（跨项目待回流清单）。
> **移植原则**：只搬**与本项目技术栈相关、且与语言/工具链/流程有关**的条目；完全绑定原项目业务的（图标网格、StoreKit、
> Carbon 热键、日期语义等）**不搬**。编号续排（本项目规则：只增不删、编号不复用），每条标注来源，便于回溯。
> **去重**：与既有条目同源的，只记"同源"不重复展开。

## P-027 · 失败分支匹配不到已知签名时**什么都不列**（跨 4 次命中，本项目已应用）

**症状**：脚本报「✗ 失败（exit N）」，**后面一片空白**。最需要线索的时候没有线索。

**根因**：失败分支的输出靠 `grep -E '<已知签名>'` 过滤，而**未预料到的失败类型一条都不匹配** ⇒ 什么都不打印。

**处置**（已落成 `Tools/gate.sh` 的构建 / 测试两个失败分支）：

```bash
excerpt="$(grep -E 'error:|✘|Expectation failed|recorded an issue|BUILD FAILED' /tmp/gate-test.log | head -30 || true)"
[ -n "$excerpt" ] || excerpt="$(tail -20 /tmp/gate-test.log)"   # ← 空则回退打日志末尾
printf '%s\n' "$excerpt"
fail '测试未全绿（日志 /tmp/gate-test.log）'
```

**同族第二个坑（本项目这次才踩到）**：`grep … | head` 在**无匹配**时退出码非 0，
而它在 `if …; then` 的**分支体**里 ⇒ **`set -e` 会先杀掉脚本**，`fail` 那句根本轮不到执行。
所以必须 `|| true` 兜住。

**来源**：`meta/inbox/pitfalls-2026-10-03.md` §一 `failure-branch-prints-nothing`（HabitLoop + meta-selftest-project，跨 4 次）·
`HabitLoop` #6。

**防再犯**：**失败分支的输出是最容易被漏测的路径** —— 改完门禁脚本，**故意让它失败一次**看输出。

---

## P-028 · agent 会话里的 `grep` 是 **toybox**，而它的失配是**完全静默**的

**症状**：`grep -n "A\|B" file` 返回**空**，据此得出"文件里没有"的结论。实际文件里有。

**根因**（三层，越往下越值钱）：

1. `grep` 的 BRE（基本正则）**不支持 `\|` 作为"或"**（GNU 的扩展）。要"或"就用 `-E` + `|`。
2. macOS 自带的是 **BSD grep** —— `\s` / `\d` / `\w` **不是字符类**，会被当字面量 `s` / `d` / `w`，
   于是**返回空、退出码 1、一个字都不报**。正解是 POSIX 字符类：`[[:space:]]` / `[0-9]` / `[[:alpha:]]`。
3. ⚠️ **订正（Marquee 同日实测）**：agent 会话的 `PATH` 首部是沙箱 shim 目录，
   `grep sed find ls head tail cat wc …` 共 22 个命令被换成了 **toybox** 0.8.13；
   **你自己的终端走 `/usr/bin/grep`（BSD），agent 会话走 toybox** —— 同一条命令、两种结果。
   更致命的是回退条件：shim **只在 stderr 出现 `Unknown option` 时**才 exec 真工具
   ⇒ **语义差异永远不触发回退，一律静默失配**。

**结论（本项目本次实际撞上两次）**：搜索**一律用工具版的 Grep（ripgrep）**，或在脚本里用 `grep -E` + POSIX 字符类；
**绝不用 `\|`、绝不用 `\s`/`\d`**。并且：**"我在终端里跑是好的"对 agent 会话没有任何证明力。**

**来源**：`Marquee` V140 + V141（含其自身的订正）· 本项目本次两次实测复现。

**补（`P5-T5` 交付当天，又踩同一脚 —— 值得把"复现"留在正文里）**：
`grep -n "VideoTrack\|testSelectingVideoTrack" <xcodebuild 日志>` 返回空 ⇒ 我据此写下
**"新增的两条用例根本没跑"**，而日志里它们**两条都 ✔ passed**。
两次（同一批日志、不同时刻）犯的是同一个错：**知道有这条坑，仍然用了 `\|`**。
⇒ 这条坑的真正难点不在"知不知道"，而在**"搜日志时的手感"** ——
排查现场最容易顺手敲出 `\|`。**判据：脚本/核查里的多模式搜索一律 `grep -E "a|b"`，或者直接用工具版 Grep。**
（代价具体：一次错误的"用例没跑"结论，会让人去怀疑测试发现机制 —— 方向全错。）

**防再犯**：**"返回空"与"表达式错"必须能区分开。** 一条会静默失配的正则，比一条报错的正则危险得多。

---

## P-029 · `#expect(...)` 的宏展开里**不能调用 `mutating` 方法**

**症状**：`#expect(model.apply(.currentTimeChanged(0.1)) == nil)` 报 `$0 is immutable` / 类型推断混乱。

**根因**：`#expect` 会把表达式重写成"先捕获操作数"，`mutating` 调用落在不可变上下文里。

**处置**：**先赋给局部变量再断言**（本项目 `PlayerTimeModelTests` 全程遵守）：

```swift
let update = model.apply(.currentTimeChanged(0.1))
#expect(update == nil)
```

> 这与 `P-025` 是同一棵树的两根枝：**`#expect` 的宏展开会改变表达式的求值/类型环境**
> —— 一个是 `mutating`，一个是存在元类型。

> **追加（2026-10-13，`P2-T6` 实测）**：`#expect` 的第二个参数类型是 **`Comment?`，不是 `String`**
> ⇒ **不接受字符串拼接**：`#expect(x, "第一句" + "第二句")` 报
> `cannot convert value of type 'String' to expected argument type 'Comment?'`。
> 处置：写成**单个字符串字面量**（可含 `\(插值)`），或显式构造 `Comment(rawValue:)`。
> 长消息想换行时，**别用 `+` 断行** —— 那会变成编译错误，而报错位置指向 `#expect` 而非拼接处。

> **再追加（2026-10-13，`P2-T12`）**：⚠️ **同一天内第二次命中**，而且这次犯的正是本条目已经写着的那句
> —— `let next = try #require(state.setDecoderSampleRate(44100))` 仍然是「在宏里调 `mutating`」。
> ⇒ 说明「先赋局部量」这条**光记住不够，得变成手癖**：
> **只要 `#expect` / `#require` 的表达式里出现 `set` / `mutate` / `apply` 这类动词，就先怀疑它**。

**来源**：`Marquee` E32。

---

## P-030 · xcodegen：**默认不生成 scheme**，且新增源文件后必须重新 generate

| 子坑 | 症状 | 处置 |
| --- | --- | --- |
| **默认无 scheme** | `xcodegen generate` 成功，但 `xcodebuild -scheme X` 报找不到；Xcode 里只有自动创建的 **user scheme**（在 `xcuserdata/`，随时可能不在） | 在 `project.yml` 里**显式声明 `schemes:`**（本项目本次亲测命中：生成后 `xcodebuild -list` 无 Schemes 段）。**不要依赖 Xcode 自动创建的 user scheme** |
| **新增/删除源文件后不重新 generate** | 报错出现在**调用方**（"找不到某类型"），而不是新文件本身，极易查错方向 | 改动文件集合后跑 `xcodegen generate`；更彻底的做法是用 Xcode 16+ 的 `type: syncedFolder`（文件系统同步组） |
| `schemePathPrefix` 默认值 | 默认 `"../../"` 是给**非 workspace** 工程的；workspace 形态要用 `"../"`。且它是**字符串拼接**不是路径解析，自己再补 `../` 会叠加 | 先确认 scheme 实际落在哪，再决定是否改；**不要想当然改成 `"../"`** |

**来源**：`Marquee` F41 · F42 · V139。

---

## P-031 · shell 里三个静默杀手（中文变量名 / heredoc / 管道）

| # | 症状 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | `line 98: code?: unbound variable`，那个 `?` 是被截断的汉字 | `$code）` 里**多字节字符被吞进变量名**。**只在特定 locale 下复现** | **一律写 `${code}`** —— 凡是要接中文，就加花括号 |
| 2 | heredoc 里的命令失败后，**下一行的兜底逻辑没跑** | `set -e` 在 `cmd <<'PY' … PY` 失败时**立刻中止脚本**，`[ $? -eq 0 ] \|\| FAIL=1` 轮不到执行 | 用 `if ! cmd <<'PY' … PY; then FAIL=1; fi` —— `if` 的测试位置不受 `set -e` 约束 |
| 3 | `$(grep … \| tail -1)` 无匹配时**整个脚本无声退出** | `-e` + `pipefail` 把"没匹配到"放大成"脚本死掉"，且死因写在日志之后 | `\|\| true` 兜住 + 显式判空（本项目 `P-026` 已展开） |

**来源**：`HabitLoop` #1 · #5 · `Marquee` F43。

---

## P-032 · Swift 6 并发的四个小坑（都与 `Sendable` 有关）

| # | 症状 | 处置 |
| --- | --- | --- |
| 1 | `stored property 'fileManager' of 'Sendable'-conforming struct … has non-Sendable type 'FileManager'` | **不要存**，改成计算属性 `private var fileManager: FileManager { .default }`。**别去折腾 `@unchecked Sendable`** |
| 2 | `NSLock.lock()` 在 async 上下文编译失败（`unavailable from asynchronous contexts`） | 把加解锁收进一个同步闭包（`withLocked`），异步的事放到闭包**外** |
| 3 | 模块缺 `import Foundation` 会让 **`Equatable` 静默合成失败**（`URL` / `Date` / `UUID` 场景） | 用到这几个类型就显式 `import Foundation`；`CGImageDestination*` 同源要 `import ImageIO` |
| 4 | `nonisolated deinit` 不能碰非 `Sendable` 存储属性（`OpaquePointer` 这类） | **本项目已有等价条目 `P-022`**（所有权持有者 + 把释放放进引用类型的 `deinit`）—— 同源，不重复展开 |

**来源**：`HabitLoop` #2 · `Marquee` F44 · G51（第 4 条与 `Marquee` G50 同源）。

---

## P-033 · 测试夹具必须**确定性**

**症状**：`Expectation failed: store.load() == sampleDatabase()` —— 看起来像"落盘实现有问题"。

**根因**：`Habit(id: UUID = UUID())` 每次构造都生成新 id；"写进去的库"与"读回来的库"是**两次独立构造**。

**处置**：测试夹具**固定 UUID / 固定时间 / 固定路径**，不依赖默认随机值。

**分诊规则（比条目本身值钱）**：判据红了，**先分"实现错"还是"期望错"**，别急着改实现。

**来源**：`HabitLoop` #3。

---

---

---

## P-034 · ⚠️ 不在门禁里的包，**编译破坏没有任何信号**（跨层改协议时尤其致命）

**现象（本项目真发生过，代价是两个提交）**：
`P2-T4` 给 `PlayerKernelEvent` 新增了 `.videoSizeChanged`，`MPVKernel` 里针对该枚举的 `switch` 因此**不再穷尽** ——
即**编译失败**。但当时：

| 检查 | 结果 |
| --- | --- |
| 根包 `swift build` | ✅ 通过 |
| 根包 `swift test` | ✅ 110 tests 全绿 |
| 变异测试 | ✅ 50/50 杀死 |
| `./Tools/gate.sh` | ✅ **EXIT=0** |

**"全绿"，而 MPV 包其实编译不过。**

**根因**：`MPV/` 是**独立 SPM 包**（自己的 `Package.swift`）。根包的 `swift build` 根本不会碰它；
而它唯一的消费者（Demo / 真机）在本机**因为缺少那个 104 MB 自建产物，从未被构建过**
⇒ 一条**从未被执行到的构建路径**，把破坏藏了整整数个提交。

**怎么发现的**：本机第一次把产物 stage 到位，第一次跑
`xcodebuild -scheme PlayerMPV -destination 'generic/platform=iOS Simulator' build` →

```
MPVKernel.swift:199:9: error: switch must be exhaustive
```

**处置**：`Tools/gate.sh` 增加 **[4/5] MPV 包构建**：

- 产物**存在** ⇒ 真的构建，计入门禁；
- 产物**不存在** ⇒ `SKIP`，但**必须同时打印"本次未验证 MPVKernel 的编译，其破坏不会被这个门禁发现"**。
  ⚠️ 只打一个 `SKIP` 是**不合格**的 —— 那会让"绿"被读成"全绿"（同 `P-027`：失败/跳过分支必须给信息）。

**防再犯**：
1. **每新增一个"独立包"，当天就要把它接进门禁** —— 哪怕只接 `build`（先不求 `test`）。
2. **跨层改协议（新增 enum case / 改 struct 字段）之后，必须把所有实现方都真编译一遍。**
   编译器的穷尽性检查是**免费且最强**的回归网 —— 但它只在**你编译那个 target 时**才生效。
3. **"门禁通过"的语义必须写明覆盖面**。判据：问一句「**本仓库有几个 SPM 包？每个都在门禁里吗？**」
   —— 本项目现在是 **2 个**（根包 `PlayerStack` + `MPV/`），**都在**。

> 与 `P-018`（单元测试全绿 ≠ 部件能组合）是同一族，但更早一步：**那条是"跑了但没测到组合"，
> 这条是"根本没跑"**。**没被执行的检查，比失败的检查更危险 —— 因为它返回的是绿。**

---

---

## P-035 · ⚠️ 装配层对"被拒事件"的 `return`，会把**失败**变成**静默**

**现象**：`P2-T6` 要让 `MPV_EVENT_END_FILE` 的错误走到 `.failed`。按票面只需改 `MPVKernel`，
但复核发现：即便内核 `emit(.stateChanged(.failed))`，**`PlayerController` 的更新流里一条都没有** ——
UI 永远停在原状态，**且没有任何报错、没有任何日志**。

**根因**：装配层是「先过状态机，只上报 `.applied`」：

```swift
case .stateChanged(let newState):
    guard machine.transition(to: newState) == .applied else { return }
    continuation?.yield(.stateChanged(newState))
```

而 `PlayerStateMachine` 当时把四条边**明确列为非法**（`PlayerStateMachineTests.swift` L33/L39/L42/L45 有断言守着）：
`.idle → .failed` · `.readyToPlay → .failed` · `.paused → .failed` · `.finished → .failed`。
于是三条真实路径全部被 `return` 吞掉：
① 容器解析成功（`.readyToPlay`）之后解码才失败；② 暂停中网络流断掉（`.paused`）；
③ `mpv_create` / `mpv_initialize` 失败时状态还是 `.idle`。

**判据**：**状态机的"拒绝"语义对「非法迁移」成立，对「事实回执」不成立。**
`.failed` 不是"有人做了不该做的操作"（那才该拒），而是"内核观察到的事实"。
**拒绝一个事实不会让它不发生，只会让它消失。**

**处置**：
1. **规则反转** —— `.failed` 成为**唯一一条与源态无关**的边：`if newState == .failed { return true }`。
2. 用**穷尽断言**守住整类问题，而不是补四条：
   `testFailureIsReachableFromEveryState` —— 对全部 7 个状态断言 `transition(to: .failed) != .rejected`。
3. 装配层补两条用例（`.readyToPlay → .failed`、`.paused → .failed` 必须上报），钉住"拒绝即静默"这一行为。
4. **反转流程**：先在票面（`docs/03` 📌）**列出被反转的断言原文与行号**，再改 —— 有先例的规则不能悄悄翻。

**防再犯**：**凡是"按条件决定要不要上报"的分支，都要问一句「被丢掉的那一支，谁会知道？」**
若答案是"没人"，那它就不是过滤，而是一个**静默丢事件的洞**。

> 同族：`P-019`（空输出 ≠ 没发生）· `P-023`（退出码 0 ≠ 测试跑了）· `P-034`（不在门禁里 ⇒ 返回绿）。
> 共同点：**失败被"优化"掉了，而优化者以为自己在做校验。**

---

## P-036 · ⚠️ 提交之后工作区被外部工具改回旧版 ⇒ 下一次 `git add -A` 会**悄悄回退已提交的内容**

**现象**：`295e0c8` 已提交并推送了 `docs/03` 的 `P2-T6` 内容（📌 规则反转记录、票面状态）。
几分钟后再看该文件：**表格被加了列宽填充，而整块 📌 不见了**，`P2-T6` 行回到"⬅ 下一步"。

判据一眼可辨：

```bash
git grep -c "规则反转" HEAD -- "docs/03-路线图.md"   # → 1   （提交里有）
grep -c   "规则反转"        "docs/03-路线图.md"      # → 0   （工作区里没有）
```

即**工作区比 HEAD 更旧** —— 某个外部编辑器/工具拿着一份**过时的缓冲区**保存覆盖了它
（表格填充说明该工具做过格式化，所以不是随手的 `git checkout`）。

**为什么危险**：接下来只要有人（人或 agent）跑一次 `git add -A && git commit`，
就会把**已经提交并推送的内容**作为一个"新提交"再改回去 —— 而 `git status` 只会显示
`M docs/03-路线图.md`，看起来像是**本次的正常改动**。日志里不会留下任何"回退"痕迹。

**处置**：`cp` 备份当前工作区版本 → `git checkout -- <file>` 从 HEAD 恢复 → 在此基础上重做本次编辑。

**防再犯**：
1. **动手前永远先 `git status --short` + `git diff --stat`**，并问一句「**这文件我改过吗？**」
   出现"我没碰过的文件有差异"⇒ **先查，别 `git add -A`**。
2. **永远不要用 `git add -A` / `git add .` 提交**——按文件显式 `git add <paths>`。
   这条把上面那类事故从"会发生"降级为"不会发生"。
3. 判断"工作区是不是比 HEAD 旧"有一条廉价探针：`git grep -c <本次提交里的关键词> HEAD -- <file>`
   与直接 `grep -c` 同一个文件对比，两者不一致就说明工作区被动过。

> 与 `P-015`（SIGKILL 中断把变异留在源文件里）同族：**都是"工作区状态与你的记忆不符"**。
> 共同防御只有一条 —— **状态先核对，再动手**。

> **追加（2026-10-13，同一天内第二次命中 —— 所以这条要当"常态风险"处理，不是偶发）**：
> 恢复后继续工作约 30 分钟，`docs/03` **又被覆盖了一次**，这次是**混合态**：
> `P2-T6` / `P2-T7` 的内容在，**只有 `P2-T9` 那一行被回退**成旧文本，且表格被重新加了列宽填充。
> ⇒ 说明那个外部写入者持有的是**某个中间时刻**的整份快照，落盘时会把**之后所有提交**一起抹掉。
>
> **升级后的判断**：只要某个文件**在编辑器里开着**，它就可能在任何时刻被旧缓冲覆盖。
> **这条不是一次事故，而是一条持续存在的风险** ⇒ 处置也要常态化：
> 1. **每个节点动手前**先跑一次「HEAD 关键词 vs 工作区关键词」对比（见上），别只在怀疑时跑；
> 2. **改完立刻提交**，把"未提交窗口"压到最短；
> 3. 长时间手改同一份文档时，**建议先关掉编辑器里的那个文件**（或至少确认它没在做 format-on-save）。

---

## P-037 · SwiftPM 包的测试入口：**没有 `<包名>-Package` scheme**，直接用产品 scheme

**现象**：给 `MPV/` 加了 `.testTarget` 之后，`xcodebuild -list` 里**仍然只有一个 scheme**（`PlayerMPV`），
没有常见的 `PlayerMPV-Package`。按经验去试 `-scheme PlayerMPV-Package` ⇒

```
xcodebuild: error: The workspace named "PlayerMPV" does not contain a scheme named "PlayerMPV-Package".
```

**根因**：在**包目录**里跑 `xcodebuild` 时，Xcode 建的是一个**隐式 workspace**，只按 *product* 建 scheme；
`<包名>-Package` 那个 scheme 是 **Xcode app 里打开包**时才生成的，CLI 路径下不存在。

**处置**：**直接用产品 scheme 跑 `test`** —— 加了 `testTarget` 之后它会自动带上测试：

```bash
cd MPV
xcodebuild -scheme PlayerMPV \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath DD-Test test
```

**另外两条同批踩到的**：

| 子坑 | 现象 | 处置 |
| --- | --- | --- |
| **别写死模拟器机型** | `-destination 'platform=iOS Simulator,name=iPhone 18 Pro'` 会在换机/升级后失效 | `xcrun simctl list devices available -j` 里**动态挑**可用 iPhone（优先 `state == "Booted"`）。已落成 `gate.sh` 的 `pick_simulator()` |
| **汇总行别用 `[^.]*` 截片段** | 想提取 `Test run with 7 tests in 1 suite passed after 7.057 seconds.`，写 `-Eo '…tests?[^.]*'` 会在 `7.057` 的小数点处断掉，打印出 `after 7` 残句 | **整行取回**（`grep -E … \| tail -1`），别用 `-o` 截。这是"把签名卡太死"的典型后果（`P-027` 同族） |

> `-derivedDataPath` 必须给，且要进 `.gitignore`：`MPV/DD-Test/` 有 **149 MB**。
> 本轮把忽略规则由 `MPV/DD-iOS/` 放宽成 **`MPV/DD-*/`** —— 否则下次换个名字又漏。

---

## P-038 · "只在变化时通知"的信号，回答不了"当前值是什么"

**现象**（`P2-T8` 实测）：换文件（`loadfile … replace`）之后，画面**确实在放** ——
事件流里 `currentTimeChanged` 从 0.1 一路推到 1.9 —— 但状态**永久停在 `.readyToPlay`**，
再也回不到 `.playing`。UI 会显示"就绪/等待"，而视频在播。

**根因**：`.playing` 只由 `pause` 属性的 **`MPV_EVENT_PROPERTY_CHANGE`** 驱动。
而 `pause` 是**变化通知**：换文件前后它的值**都是 `no`**，**没有变化 ⇒ mpv 不发通知**。
于是"当前值"这件事被交给了**一个只报告差异的信号** —— 差异为零时，它什么都不说。

**判据**：**问"现在是什么"和问"变了没有"是两个不同的问题。**
凡是靠 `observe` / 事件 / KVO 建立的订阅，都只回答后者。
在**状态被重建**的时刻（换文件、重连、重载、恢复会话、重放），必须**主动读一次当前值**。

**处置**：`MPV_EVENT_FILE_LOADED` 之后调用 `emitPauseState()` —— 用 `mpv_get_property`
同步读一次 `pause` 并上报对应状态（`.playing` / `.paused`）。

**防再犯**：新增一个"由订阅驱动的状态"时，问一句：
**「它被重建的时候，谁会来告诉新值？」** 答案是"没人" ⇒ 补一次主动读取。

> 与 `P-036` 同族：都是**"没有消息"被当成"没有变化"**。这条在**信号层**，那条在**工具层**。

---

## P-039 · ⚠️「我写了这条分支」≠「那个事件会到达」：`keep-open` 下 `.finished` 曾是**死状态**

**现象**（`P2-T8` 实测）：素材 2 秒，播完之后**等 15 秒，`.finished` 一条都没有**。
而代码里明明有"EOF → `.finished`"的完整实现，`P2-T6` 还专门为它写了 `PlaybackEndReason`。

**根因**：我们给 mpv 设了 **`keep-open=yes`**（为了"播完停在末帧"这个正常播放器行为）。
在这个模式下，mpv 到 EOF **不会发 `MPV_EVENT_END_FILE`**，它只是把 `pause` 置 `yes`、把画面停住。
所以那个 `END_FILE` 分支**从来没有机会执行** —— 代码覆盖了，**路径没覆盖**。

**为什么这种坑特别难发现**：症状是**没有任何症状**。没有报错、没有警告、
已有的测试还都绿着（因为没有任何测试断言过 `.finished` 会出现）。

**处置**：观察 **`eof-reached`**（`MPV_FORMAT_FLAG`），变真时上报 `.finished`。
mpv 文档正好点明 `eof-reached` **只在用 `--keep-open` 时才有意义** —— 两个设定本来就该配对。

**防再犯**：
1. **对每条"处理某事件"的分支，都要有一条"我见过它被走到"的证据**（测试/日志/截图），
   而不是"我写了处理逻辑"。这与 `P-017`（变异不变红 = 断言盲 or 死代码）是同一条判据的**运行期版本**。
2. 引入一个会**改变上游行为**的选项（这里是 `keep-open`）时，
   **回头清点一遍"哪些事件因为它的存在而不再发生"** —— 选项文档里通常写了，但不会替你连起来。

> 同族三条，正好构成一张网：
> `P-017` 变异不变红（测试没覆盖）· `P-034` 不在门禁里（根本没跑）· 本条（跑了，但那条分支永远不进入）。
> 共同点：**"存在"与"被执行"是两件事。**

---

## P-040 · `print` 到管道是**块缓冲**：进程一被 terminate，输出连同缓冲一起消失

**现象**：给 Demo 加了 `-traceUpdates`（把每条更新 `print` 出去），用
`xcrun simctl launch --console … -traceUpdates > /tmp/log` 抓取；
**`[trace]` 一行都没有**。而同一份代码在应用里明明生效了（截图里状态、画面尺寸都在变）。

**根因**：`print` 写的是 **stdout，连到管道时是块缓冲**（4 KB 级）。
排查端到端免不了 `simctl terminate` —— 进程被收掉时缓冲**从未 flush**，
于是"日志里什么都没有"，看起来像"这段代码没执行"。

**判据**：**"没有输出"不能推出"没有执行"**（与 `P-014` 同源）。
这条在本机早有记录（沙箱化进程启动阶段被杀 → 一行输出都没有），这次换了个触发方式又踩到。

**处置**：诊断输出走 **无缓冲** 的 `FileHandle.standardError.write(...)`：

```swift
FileHandle.standardError.write(Data("[trace] \(update)\n".utf8))
```

（stderr 默认无缓冲；若坚持用 stdout，就得每行 `fflush(stdout)`。）

**防再犯**：**任何"要被工具抓取"的诊断输出，一律无缓冲直写**。
判据问法：**「进程被杀的那一刻，我这条日志还在缓冲里吗？」**

---

---

## P-041 · 「变异体存活」有三种成因，**只有一种是测试的问题**

**现象**：`./Tools/gate.sh` 的变异步骤报

```
SURVIVED  decoder: UTF-8 BOM 不剥掉（首条字幕带不可见字符）
```

**三条可能的成因**（本项目此前默认按第 ① 条处理，这次不是）：

| # | 成因 | 处置 |
| --- | --- | --- |
| ① | **测试盲区** —— 用例只覆盖了守卫为真的一侧 | 补测试（已抓到 4 次） |
| ② | **实现真错** —— 代码确实依赖那行 | 修实现 |
| ③ | **等价变异体** —— 那行代码在语义上**本来就不起作用**，改不改都一样 | 删代码 / 改变异体 |

**这次的判据（20 行探针实测，不是推断）**：

```
String(data: EF BB BF + "中", encoding: .utf8)             → 首码位 U+4E2D  ⇒ Foundation 自己吞了 BOM
String(data: FF FE + "中"(utf16LE), .utf16LittleEndian)    → 首码位 U+FEFF  ⇒ 显式端序解码器**不**吞
```

⇒ UTF-8 那条 `dropFirst(3)` 是**冗余**的（因此那条变异体永远杀不死），
而 UTF-16 的两条 `dropFirst(2)` 是**承重**的（可以杀死）。处置：删掉冗余代码 + 把变异体改指向 UTF-16。

**防再犯**：**变异体存活时，先回答「这个改动在语义上真的改变了行为吗」** ——
用探针回答（`P-013` 的精神：先测量再结论），答「否」就先删代码或改变异体，答「是」才去补测试。

> 与既有的「**变异体存活几乎总是测试的盲区，先怀疑测试**」并列而**不冲突**：
> 那句话是**默认倾向**，不是结论 —— 顺序应当是「**先分类（①/②/③），再动手**」。
> 把 ③ 当成 ① 会白补一堆不可能失败的测试，还顺手把一行死代码正当化了。

---

## P-042 · 写死「素材参数」的断言，会在换素材时**假红**（且红得像回归）

**现象**：把端到端样例从"自造的 640×360 / 44.1 kHz 片段"换成真实视频后，
两条断言立刻失败：

```
G2：端到端缺关键事件：videoSizeChanged((640.0, 360.0))
G3：状态行一直没出现「输出 44100 Hz」
```

**这不是回归** —— 实测（`AVURLAsset` 量的，不是估的）：

| 素材 | 尺寸 | 音轨采样率 | 时长 |
| --- | --- | --- | --- |
| 自造片段（`SampleClipWriter`） | 640×360 | 44100 Hz | 5.00 s |
| **MDN `flower.mp4`（CC0）** | **960×540** | **48000 Hz** | 5.01 s |

**判据**：断言里出现的是**性质**还是**具体数值**？

| 类型 | 写法 | 换素材时 |
| --- | --- | --- |
| 性质 | `画面 [1-9][0-9]*×[1-9][0-9]*` · `输出 [1-9][0-9]* Hz` | 依然成立 ✅ |
| 数值 | `640×360` · `44100 Hz` | **假红** ❌ |

**防再犯**：写涉及素材的断言前先问「**这个数字是这段素材的，还是这件事的性质？**」
—— 是素材的就不要写进断言（把它换成"非零 / 非空 / 有推进"）。

> 与 `P-030`（写死机型名）同族：**写死一个会变的具体值**。
> 差别在于这条更隐蔽 —— 机型名失效会立刻报"找不到设备"，而素材参数失效看起来**像功能回归**，
> 于是排查会从代码开始，方向全错。

---

## P-043 · 「相对调整」读**异步回执的状态** ⇒ 连点会丢操作

**现象**：写 `adjustSubtitleDelay(by:)` 的测试时，连续三次调用（`+0.5`、`+0.5`、`-1.0`）
期望内核依次收到 `0.5, 1.0, 0`，实际收到 `0.5, 0.5, -1.0`。

**根因**：相对调整读的是 `subtitles.delay`，而它只在**内核回执**到达后才更新。
三次调用間に回执没回来 ⇒ 三次都基于同一个陈旧值（`0`）计算。

**这不是测试写法问题，是用户体验问题**：用户连点五次 `+0.5 s`，
字幕只挪了 0.5 秒 —— **四次操作被静默丢弃**。
症状是"延迟按钮不灵"，而不是"延迟算错"，所以很难联想到"状态更新是异步的"。

**处置**：把「我们发下去的值」**本地即时生效**，并立即发布给界面；
内核回执到达时若同值会被去重，**不同值则覆盖本地值（自我纠正）**。

**⚠️ 与 `P2-T5`（`play/pause` 不做乐观上报）看似矛盾，实则判据不同**：

| | 内核会不会"改主意" | 做法 |
| --- | --- | --- |
| `pause` | **会**（缓存中 / EOF / `keep-open` 都可能让它自己变） | 只 observe，不乐观上报 —— 乐观就是撒谎 |
| `sub-delay` / `sub-visibility` | **不会**（无条件生效的可设置属性） | 本地即时生效 + 以内核回执为准 |

**判据**：**"我们知道自己发下去的是什么"** ⟺ 可以本地先生效；
**"内核可能不完全照办"** ⟺ 必须等回执。两者都要保证"回执能覆盖本地值"。

**防再犯**：写任何 `delta` 式操作（音量 ±、延迟 ±、进度 ±）之前先问：
**"这个相对量是基于谁算的？它更新得够快吗？"** —— 基于异步回执的，连点必丢。

---

## P-044 · 内核报告的**引用型 id** 可能指向已不存在的对象

**现象**：MPV 包测试 `testSwitchingFilesClearsPreviousSubtitleTracks` 失败 ——
换文件后 `tracks` 已空，但 `selectedTrackID` **不是 nil**。
于是 `PlayerSubtitleState.isDisplaying`（当时写成 `isVisible && selectedTrackID != nil`）
报告"正在显示字幕"，而屏上**一个字都没有**。

**根因**：mpv 的 `sid` 是"**请求的**轨道 id"，换文件后它**不会自动清零**，
仍然指向上一个文件的轨道编号。那个编号在新文件里可能根本不存在。

**这不是内核的 bug**（记住 sid 是有意的：新文件若有同号轨道就被自动选中）。
**是我们的模型假设错了**：把「引用的 id 非空」当成了「对象存在」。

**判据**：
| 写法 | 换文件后的行为 |
| --- | --- |
| `isVisible && selectedTrackID != nil` | ❌ 说谎（非 nil 但解析不到轨） |
| `isVisible && selectedTrack != nil` | ✅ 正确（**用清单去解析** id） |

**防再犯**：**凡是内核/外部系统给的"引用型状态"（id / handle / 索引），
都不能当作"目标存在"的证据** —— 必须拿它去**当前清单**里解析一次。
同族：`P-018`（单测全绿 ≠ 能组合）。

---

## P-045 · `@Suite(.serialized)` 只序列化**套件内部**；跨套件仍然并行

**现象**：给 MPV 包新增一个字幕测试套件后，同一次改动**两次运行失败在不同的测试上**
（一次是新的字幕测试、一次是既有的 `testLoadingMissingFileReportsFailure`），
**单独复跑两次又全绿**。

**根因**：Swift Testing 默认并行，而 `.serialized` 的作用域是**它自己那棵子树**。
两个顶层套件之间**照旧并行** ⇒ 两个真实 mpv 实例（视频解码 + VideoToolbox）互抢资源 ⇒
非确定性失败。**失败位置会漂移**，这正是"资源争抢"而非"实现出错"的指纹。

**处置**：把需要同一份稀缺资源（真实内核实例 / 模拟器 / 端口）的用例
**全部放进同一个 `@Suite(.serialized)`**，不再按主题拆套件。
**宁可文件长，也不要失败漂移** —— 漂移的失败会训练人去"重跑一次"，那是最坏的习惯。

**防再犯**：看到"**换一次运行，失败换了个地方**"这句话，先怀疑并行资源争抢，
而不是逐条去查那些失败的用例。

---

## P-046 · 异步确立的"拖拽起点"，会被**同步的第一下**点击吃掉

**现象**：进度条"点一下没反应，得拖一下才生效"。

**根因**：视图层的手势回调是**同步**的，而装配层的按下处理是 `async`：

```
onBegan()  ─┐
            ├─ 视图层：同一个 runloop 内连续调用，同步
onChanged() ─┘
```

原写法 `public func beginScrub() async` 意味着拖拽状态要等**下一个 runloop** 才确立，
而 `updateScrub` 内的 `guard scrub.isScrubbing else { return }` 于是把**第一次点击整个丢掉**。
`onEnded` 同样被 `guard isScrubbing` 挡掉 ⇒ 全程无操作。

**判据**：**「状态的建立」与「状态的消费」如果跨了 await，前者就必须是同步的。**
可以异步的是**副作用**（这里：向内核发 pause / seek），不可以异步的是**状态本身**。

**处置**：`beginScrub` / `endScrub` 改为同步，内核动作放进 `Task {}`。
效果：手势 `onBegan` 当场把 `isScrubbing` 立起来，紧随其后的 `onChanged` 一定命中。

> 与 `P-043` 是**同一类**：那条是"读异步回执导致连点丢操作"，这条是"异步确立导致首次点击丢操作"。
> 共同点：**把异步边界放在了状态上，而不是副作用上。**

---

## P-047 · 「目录里有任何文件」当缓存命中 ⇒ 换素材被旧缓存**静默挡住**

**现象**：把样例视频从 MDN `flower.mp4`（5 s）换成 Sintel trailer（52 s / 720p）之后，
重新跑，播出来的**还是那个 5 秒的旧片子** —— 而且 `source` 字段如实写着"缓存"，看不出异常。

**根因**：缓存命中写成"目录里第一个大于 4 KB 的文件"，与**候选 URL 无关**。
于是候选列表怎么改都没用，旧文件永远先被命中。

**处置**：改成**按候选文件名精确匹配**（`cachedClip(for: url, ...)`）。
副产品：候选链因此可以"部分命中" —— 主源已下载过就直接用，其余不必再试。

**防再犯**：**缓存的键必须与被缓存对象的身份一致。**
"目录里有东西就算命中"这种写法在任何会换内容的场景下都会变成"改了不生效"，
而它**不会报错** —— 只会让你以为改动没编译进去。

---

---

## P-048 · `stop` 之后再 `play` 什么都不做 —— 因为**命令的语义里包含"销毁"**

**现象**（实测反馈）：点「停止」之后再点「播放」，**画面不动，也不报错**。
播完之后点「播放」同样如此。

**根因**：mpv 的 `stop` 命令是「**停止播放并清空播放列表**」。
此后没有文件可播，而 `play()` 当时只做一件事 —— `setProperty("pause", "no")`：

```
stop  → 播放列表空 ⇒ 没有东西可以被 pause
play  → pause=no  ⇒ 无事发生（属性设成功了，但它指的是"虚空"）
```

`keep-open=yes` 下播完停在末帧是同一类问题的另一种形态：
`pause=no` 会在**末帧原地**立刻再次 EOF，画面一动不动。

**判据**：**命令的语义里如果包含"销毁"，那之后再发"设置"类命令就是在对空对象说话。**
「停止 → 播放」在用户语义里是「**从头再播一次**」，所以必须把文件**重新放回去**
（`loadfile`），而不是只改一个开关。

**处置**：内核记住 `lastResource`；`play()` 时若播放列表为空 ⇒ 重新 `loadfile`；
若处于 `.finished` ⇒ 先 `seek 0` 再放开暂停。

> 关联判据：**`pause=no` 不等于「正在播放」**。`stop` 之后播放列表为空，
> 而 mpv 的 `pause` 同样是 `no` —— 少这层分辨，"停止后按暂停"会把状态读成 `.playing`。
> 所以 `emitPauseState()` 与 `pause` 属性回调都先问一句「**有没有东西可以被 pause**」
> （`playlist-count > 0`）。
> 一句话：**属性的真值，对"没有对象"的情形是没有意义的。**

---

## P-049 · 前提不满足时**静默 return**，界面就成了"点了没反应"

**现象**（实测反馈）：刚进 App 就点「播放」/「停止」，**毫无反应**。

**根因**：内核的 mpv 句柄是**懒创建**的（首次 `load` 才建）。在那之前：

```swift
public func play() async {
    guard let handle = owner?.pointer else { return }   // ← 静默返回
```

`play` / `pause` / `stop` / `seek` / 字幕命令**全部**走这条 `guard`。
它们既不报错也不改状态，**从调用方完全看不出发生了什么** —— 包括
装配层（没有事件）、界面层（没有变化）、用户（没有反馈）。

**判据**：**"不报错"不等于"做到了"。** 一个命令有前置条件时，
**前提不满足必须能被上层看见**，否则它就退化成一个只会消耗点击的黑洞。

**处置（两层，缺一不可）**：
1. 装配层给出**可用性**：`hasLoadedResource` ⇒ `canPlay` / `canStop` / `canSkip`。
2. 界面**如实地灰掉**（`.disabled` + 压透明度 —— 系统那点变灰在视频画面上看不出来），
   状态行直说「未加载文件 · 点右侧文件夹图标选视频」。
   字幕入口同理：没有文件时**没有东西可以挂字幕**，灰掉比"选完文件才发现没反应"诚实。

**顺带**：这条改动**暴露了一个既有测试的不真实场景** —— 它没加载视频就直接调
`loadSubtitle`，改成"先有视频"后才通过。**守卫的价值之一就是逼测试描述真实路径。**

---

---

## P-050 · 协议的**默认实现**会把"签名写错"变成"什么都没发生"

**现象**：给内核加了日志转发能力，跑起来**一行内核日志都没有**。
而代码看上去完全正确 —— 调用了、编译过了、运行也不报错。

**根因**：协议要求的是

```swift
func enableLogging(_ handler: @escaping @Sendable (String) -> Void) async
```

而我写的是

```swift
public func enableLogging(level: String = "v", handler: ...)   // ← 多了一个带默认值的参数
```

**带默认参数的方法不满足单参数要求**（默认值不参与协议匹配）。
于是编译器**静默选中了协议的默认实现**（`public extension` 里那个空的 no-op），
我自己的实现**从来没被调用过**。

**判据**：**默认实现是"可选能力"的好工具，但它同时也是"签名写错"的完美掩体。**
凡是给协议加了默认实现，就要多问一句：**「我这个实现真的被选中了吗？」**
—— 最省事的验证方式是让实现**自报一行**（这次就是这么抓到的：日志能力自己先打一行 `[mpv/request]`）。

**处置**：签名改成与协议逐字一致；`enableLogging` 里**先自报一行**（含 `handle=ready/pending` 与返回码），
这样"日志没出来"与"日志通道没打开"不再长得一样。

---

## P-051 · 把"**读不到**"当成"**确定为零**"，守卫会把所有上报挡光

**现象**：网络流播放时界面**永久停在 `.readyToPlay`** —— 而画面尺寸（1280×720）与
时长（52.2 s）都照报，说明解码是好的，只有**状态**不动。

**根因**（我上一轮自己引入的）：

```swift
private func isPlaylistEmpty(_ handle: OpaquePointer) -> Bool {
    (getInt64(handle, "playlist-count") ?? 0) == 0     // ← `?? 0`
}
```

这个函数是 `emitPauseState()` 的**守卫**。`?? 0` 把"**属性读不到**"变成了"**确定播放列表为空**"，
于是守卫判定"没有东西可以被 pause"而**直接 return** ⇒ 播放/暂停状态**再也不会被上报**。

**判据**：**"不确定"必须与"确定为零"分开处理。**
一个**守卫**遇到不确定时应当**放行**（保守做法是继续尝试），
而不是把不确定解释成"条件不满足" —— 后者会让一条正常的路径**彻底静默**。

**处置**：读失败时返回 `false`（不阻断）：

```swift
guard let count = getInt64(handle, "playlist-count") else { return false }
```

> 与 `P-049` 同族但**更深一层**：那条是"命令前提不满足时静默 return"，
> 这条是"**守卫把一个本可行的路径误判成前提不满足**"。
> 共同点：**失败路径必须可见，而不是被一个默认值抹平。**

---

## P-052 · **验证环境的能力缺口**会伪装成产品缺陷

**现象**：`mpv` 直连 `http://127.0.0.1:8765/xxx.mp4`（宿主 `python3 -m http.server`），
状态序列是 `playing → paused → finished`，**14 毫秒内"播完了"**，`currentTime` 一直是 0。

**差点走错的方向**：去改我们的代码（加 `--force-seekable`、改 EOF 判定、怀疑 `PlaybackEndReason`）。

**日志给的原话**（这就是为什么必须有 `P-050` 那条通道）：

```
[mpv/demux] Stream is not seekable.
[mpv/ffmpeg] Cannot seek backward in linear streams!
[mpv/ffmpeg/demuxer] mov,mp4,...: stream 0, offset 0x30: partial file
[mpv/lavf] EOF reached.
[mpv/cplayer] got EOF with no data before it      ← 一个包都没读到就 "EOF"
[mpv/cplayer] You can force it with '--force-seekable=yes'.
```

`python -m http.server` **不支持 Range 请求**（连 `Accept-Ranges` 都不发）⇒
流被判为**不可 seek 的线性流** ⇒ 而 **mp4 的索引（moov）需要回退读取** ⇒
一个包都读不到就"EOF"⇒ 界面诚实地显示"播完了"。

**判据**：**服务器不支持 Range 是"测试环境缺了一项能力"，不是"我们的播放器坏了"。**
真实的 CDN 都支持 Range。**为了让测试通过去改产品，会把一个环境局限固化成产品行为**
（比如 `force-seekable=yes` 会让 mpv 把整个流缓存进内存 —— 为小文件换来的"能播"，
代价是大文件的几十上百 MB 常驻）。

**处置**：新增 `Tools/serve-range.py`（支持 Range 的极简服务器，**替代 `python -m http.server`**）。
换上去之后立刻正常：`playing` → 时间推进到 **19.25 / 52.21 s** → server 侧 8 次 range 请求。
**一行产品代码都没改。**

> ⚠️ 但**不把这条当成"产品无需改进"**：确有简陋的 HTTP 服务器不支持 Range。
> 若要兼容它们，`force-seekable=yes` 是一个**有代价的选项**（内存），
> 已登记为 `docs/03` 里的**待决策项**，而不是顺手加上。

---

## P-053 · **终态不许被跳过**：重播只报 `.playing` ⇒ 界面永远回不到播放中

**现象**（董事长真机反馈，复现入口 `-exerciseFinish`）：播到末帧后点「播放」，
**画面已经在从头重播，界面却一动不动** —— 按钮不换成暂停、状态行还写 `finished`、进度条也不动。
用户的原话是「**点了没反应**」，而实际发生的是「**界面不认**」。

**根因不在界面，也不在状态机 —— 在内核报错了边**：

```
播完 → .finished（终态）
点播放 → mpv: pause=no + seek 0（画面确实重播了）
      → 内核只报 .stateChanged(.playing)
      → 装配层的状态机：(.finished, .playing) 是【非法迁移】（docs/03 明确记录过这条"刻意保留的拒绝"）
      → **如实拒收** ⇒ 界面停在 .finished
```

真机实测的原始快照：
```
[finish] 播到末尾 → state=finished t=52.21/52.21 progress=1.000
[finish] 点播放 3 秒后 → state=finished t=2.75/52.21 progress=0.053   ← 时间在走，状态没回来
```

**判据**：**拒收非法迁移是对的，错的是内核发了一条非法的边。**
`.finished` 是终态 ⇒「再播一次」在语义上就是**重新开始**，必须重新走一遍
`preparing → readyToPlay`。**内核不能用一个"终态直接跳播放中"的快捷上报，去偷掉装配层的这条规则** ——
否则「界面正确」这件事就永远建立在内核"记得报对边"上，而它报错时不报错、只表现为界面不动。

**处置**：`MPVKernel.play()` 在"停在片尾"时补报 `.preparing` → 重走 `.readyToPlay`，
之后由 `emitPauseState()` 报 `.playing`。**没有翻转任何既有先例** —— 终态语义原样保留，只是把该报的边补齐。

> 同一处顺带修掉一个**真实存在的时序竞态**：EOF 时 mpv 的两条上报**只差 9 毫秒**
> （`pause=yes` 3.215 / `eof-reached=yes` 3.224），**谁先到没有保证**。
> 原实现拿本地 `state` 当"是不是停在片尾"的判据 —— 而 `state` 只是"最后一次上报"的副本。
> ⇒ 改读 mpv 自己的 `eof-reached`（读不到时退回 `state`，同 `P-051`：不确定不能当成确定）。
> 判据同 `P-038`：**问现在是什么，别信本地记的那一份。**

---

## P-054 · 用例的断言**对缺陷恒真**，加上时序不真实 ⇒ 一条早就该红的用例一直是绿的

**现象**：`testPlayAfterFinishRestartsFromBeginning` **长期全绿**，而真机上就是 `P-053` 那个"界面不认"。
同一条用例被加强之后才抓得住它。

**两条成因，缺一不可**：

① **断言写的是"量落在某个区间"**：`state == .playing && currentTime < duration - 0.5`。
   而"停在末帧不动"的 `currentTime` **本来就**小于片尾 —— 这一半断言对缺陷**恒真**。
   ⇒ **该断言的是"量在变"（时间从片尾回到开头并继续推进），不是"落在哪"**。

② **用例的时序不真实**：它在"刚播完立刻"就调 `play()`。真机上用户是**几秒后**才点的，
   而多出来的这一拍恰好会改变上报顺序（见 `P-053` 的 9 ms）。⇒ **用例必须还原"用户会等"这个事实**。

③ 还有一层**更强的断言不能省**：只断言"时间推进"抓不到 `P-053`——
   那里**时间确实推进了**，坏的是状态轨迹。⇒ 必须连 **`finished → preparing → readyToPlay → playing`**
   整条轨迹一起断言。

**判据**：**一条从没红过的用例，和一条不可能红的用例，看起来一模一样。**
写"缺陷条件下也成立"的断言，等于给自己发了一张"已验证"的假证书。

**处置**：加 1.5 s 沉降等待 + 断言轨迹 + 断言时间真的推进（三条一起）。

---

## P-055 · 同一仓库挂在**两套 Xcode 环境**上，团队号却是**写死的单值** ⇒ 报错指向"账号"这个假方向

**现象**：在换了机器（或换了真机）之后，真机构建报

```
error: No "iOS Development" signing certificate matching team ID "UKXWZ3FS84" with a private key was found.
error: Provisioning profile "iOS Team Provisioning Profile: *" doesn't include the currently selected
       device "Tang的iPhone" (identifier 00008140-001E09D1262B001C).
```

而所有人（包括我上一轮）都会顺着这两条去查：登没登 Apple ID？证书过期没？账号权限够不够？
**全是假方向** —— `-allowProvisioningUpdates` 只会再送你一条 `No Accounts`，把你钉在"账号问题"上。

**根因**（两层，都在"环境"里，不在"账号"里）：

① `Demo/project.yml` 的 `DEVELOPMENT_TEAM` 是**写死的单值**，而同一个仓库在**两套环境**里跑：
   家里那台 = `UKXWZ3FS84`（`zhenzhi Tang` 个人号）· 本机 = `3GMJYX32U9`（公司号）。git 里只留得下一个值。
② 一台机器能不能签，只取决于**本机**这两样东西，与账号无关：
   - 钥匙串里有没有**该 team 且带私钥**的 `Apple Development` 证书；
   - 该 team 的通配描述文件里**有没有这台设备**。

本机实况：三个开发证书分属 `88D39V32YV` / `YXFC65VYTW` / `3GMJYX32U9`，**没有 `UKXWZ3FS84` 的私钥**；
且 `UKXWZ3FS84` 通配描述文件覆盖的 6 台设备里是 **另一台** iPhone（`…000A288836FB001C`），不是当前这台。

**判据**：**报错里出现 team ID 时，先问"这是哪台机器的 team"，别问"账号怎么了"。**
"签名"是**环境 × 设备 × 证书**三者的交集，缺一不可；账号只是生成证书/描述文件的**上游**，不是构建时的判据。

**处置**（口径 = 构建时命令行覆盖，仓库不动）：

```bash
xcodebuild … -destination 'id=<本机真机 UDID>' DEVELOPMENT_TEAM=<本机 team> build
```

- `project.yml` 保留一个值（当前 = 家里那台），**不为换环境反复改仓库**（否则两台机器会互相把对方的值改回去）；
- 落地前先验两件事再构建：`security find-identity -v -p codesigning`（找带私钥的证书）
  · `security cms -D -i <profile>` 看 `TeamIdentifier` 与 `ProvisionedDevices`（找覆盖本机设备的那一份）。

---

## P-056 · 「**立刻**失败」与「**超时**失败」是两种病 —— 别拿查网络的时间去查权限

**现象**（真机直连宿主机的局域网地址）：

```
[mpv/ffmpeg] tcp: Connection to tcp://192.168.2.217:8765 failed: No route to host
```

**6 毫秒**就返回了。而同一时刻：宿主机防火墙是**关的**、服务确实在 `*:8765` 上 `LISTEN`、
同一台宿主机自己 `curl` 拿到 `206`。

**真因**：iOS 14+ 把「访问本地网络」变成了一项**用户授权**。Demo 的 `Info.plist` 里没有
`NSLocalNetworkUsageDescription` ⇒ **授权入口不存在** ⇒ 系统直接把连接掐掉。
补上这个 key 之后，同一条 URL 立刻通了（`preparing → readyToPlay → playing` 只用 100 ms）。

**判据**：**"立刻失败"说明包根本没发出去** —— 那是**门禁**（权限 / 策略 / 配置）在拒绝；
**"超时失败"才是路径不通**（路由、AP 隔离、防火墙丢包）。两者的排查方向完全相反，
而错误文案里都只有一句 `No route to host`。**下次先量"花了多久"**，再决定查哪边。

> ⚠️ 这**不只是演示需要**：局域网 NAS / 自建 HTTP 源是播放器的常见来源，
> 产品第一次做局域网点播时同样必须有这个 key。

---

## P-057 · 两个 target 共用一个 `Info.plist` 路径 ⇒ **后写的整个覆盖前一份**，静默丢配置

**现象**（真机 App 少了 `UISupportedInterfaceOrientations` / `UILaunchScreen`）：
`Demo/project.yml` 里 iOS target 与 macOS target 都写了 `info.path: Info.plist`。
xcodegen **两个都往同一个文件写** —— 不合并、不报错，**macOS 那份把 iOS 那份整个盖掉**。
生成出来的文件里只剩 `LSMinimumSystemVersion`。

**为什么难发现**：iOS 侧**照常能编译、能装、能跑**。丢的是"横屏支持"和"启动屏配置"
这类**只在特定路径上才被看见**的东西 —— 没有人会专门去验它，直到某天横屏不好使。

**判据**：**多个来源写同一个生成物路径时，"不报错"完全不等于"没被覆盖"。**
要么各给一个路径（这里就是），要么在生成之后**断言"该有的项在不在"**。

---

## P-058 · 日志**断流** ≠ 被测对象卡死：先确认取证通道还活着

**现象**：弱网跑取证时，`devicectl --console` 的输出**在第 2 秒就没了**。
据此判断"播放卡住了、没恢复"——**判断错了**：同一份日志的第 2 秒里 mpv 明确在打
`Still buffering (buffer went from 22% -> 35%)`，是**进度在走**。

**真因**：当时开着 `-traceUpdates`，它同时打开 mpv 的 **verbose** 日志 ——
那点量把 console 桥打爆了。**取证工具先于被测对象挂了。**

**判据**：**"我没有再看到输出"只说明**通道**断了，不说明**对象**不动了。**
先问一句"取证通道还在吗"（看采样心跳还在不在），再去解读最后几行。

**处置**：给 `-directURL` 也挂上**每秒一条**的状态采样（`[status] state=… t=… progress=… buffering=…`），
判定改用低频状态行（实测 107 秒只 107 行），**不再依赖 verbose 日志**。

---

## P-059 · 会话代理会劫持**回环**请求：`127.0.0.1` 上的服务"明明活着却连不上"

**现象**：模拟器里的 mpv 加载 `http://127.0.0.1:8765/master.m3u8`
⇒ 内核 `state=failed`、`track-list/count = 0`，而**服务端一条请求都没收到**。
同一时刻宿主 `curl` 同一个 URL ⇒ **502**。

**真因**：本会话的环境变量里有 `HTTP_PROXY=http://127.0.0.1:53670`（会话出网代理）。
mpv 内嵌的 curl 与命令行的 curl 都**默认尊重它** ⇒ 请求被送去代理，而代理到不了回环地址 ⇒ 502。

**判据**：**"服务端没收到请求" + "本地 curl 不是 200" 两条同时成立 ⇒ 先查代理。**
⚠️ 这与 `P-056` 是**两种病**：那次（`No route to host`，**6 毫秒**返回）是 **iOS 本地网络权限**；
这次是**路径被改道**。三者的排查方向各不相同，而外部症状都只是"连不上"。

**处置**：
- 跑本地服务的测试：`env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy <命令>`
- 自测用 `curl --noproxy '*'`；`--noproxy '*'` 仍不通才是真的没监听
- 真机不受影响（`devicectl` 起进程**不继承** shell 的代理变量）——
  所以"模拟器连不上、真机反而通"是**这个原因的特征形态**，不是玄学

---

## P-060 · mediamtx 找不到配置文件 ⇒ 用的是**空配置**，不是内置默认值

**现象**：`ffmpeg -c copy -f rtsp rtsp://127.0.0.1:8554/live` ⇒
`Could not write header: Server returned 400 Bad Request` —— 看起来像 ffmpeg 或编码参数的问题。

**真因**在**另一头**（mediamtx 日志）：
```
INF [RTSP] [conn 127.0.0.1:64333] closed: path 'live' is not configured
```
mediamtx 启动时打的是 `configuration file not found …, using an empty configuration`
—— **空配置里没有任何 `path`**，而常见教程依赖的 `all_others` 通配**并不存在**。

**判据**：**链路上两端的文案可以毫无关系**（这里 400 与 "path not configured" 没有一个词相同）。
⇒ 排查流媒体链路时 **必须两头都看日志**，只盯发起端会一路查错方向。

**处置**：显式给一份最小配置：
```yaml
paths:
  all_others:
```

---

## P-061 · 守护进程不能靠 `nohup … &` 活着

**现象**：`nohup python3 Tools/serve-range.py … &` 起好、当场 `curl` **200**；
下一轮调用时同一 URL 变成 **000**（连接失败）—— 进程已经不在了。

**真因**：工具调用结束时会清理**该次调用的整个进程组**。
`nohup` 只挡 `SIGHUP`，挡不住这个 —— 它解决的是"挂断"，不是"进程组被收"。

**处置**（二选一）：
- 用**工具托管的后台任务**（长时任务机制）—— 进程活到显式停止；本轮 `mediamtx` / `serve-range.py`
  / `ffmpeg` 推流三个都是这么起的
- 或者把「**起服务 → 跑验证 → 停服务**」放进**同一个调用**，不跨调用留活进程

⚠️ 别把"当作没死"当默认：**上一轮的成功不能证明这一轮还活着**（与 `P-038` 同族 ——
问现在是什么，别信记忆里的那一份）。

---

## P-062 · 服务端的 `Broken pipe` 在流媒体里通常是**"客户端主动断开"**，不是故障

**现象**：用 `Tools/serve-range.py` 发 HLS 时，服务端刷出一整段 traceback：

```
Exception occurred during processing of request from ('127.0.0.1', 5xxxx)
Traceback (most recent call last):
  File "…/socketserver.py", line …, in _handle_request_noblock
  …
BrokenPipeError: [Errno 32] Broken pipe
```

看起来像服务端写崩了 —— 而同一时刻**客户端其实正常播着**。

**真因**：HLS 客户端（mpv / lavf）会**预读若干个分片**，解析出自己需要的部分后
就**丢掉不再用的连接**（`seek` / 换清晰度更会**整批重来**）。此时服务端还在 paced 写 ⇒ `EPIPE`。

**判据**：
- **"客户端提前断开"是流媒体的常态**，不是故障 —— 它和"服务端写不出去"（磁盘满 / 权限）
  是**两种病**，而症状都是 `EPIPE`；
- 要判"是不是故障"，**看客户端有没有拿到它要的东西**（片子在不在播），
  而不是看服务端有没有报错。

**处置**：覆写 handler 的 `handle_one_request` **和** `finish`，捕获
`BrokenPipeError` / `ConnectionResetError`，降级成一行
`[net] 客户端提前断开：GET /… —— 正常（播放器预读后丢弃连接），非故障`。
⚠️ `finish()` **必须一起覆写** —— 收尾的 `flush` 同样会撞上已断的连接，只覆写前者会漏出去。

**为什么必须修，而不是"忍一下"**：**噪音会把真错误埋掉**（同 `P-058` 的形态 ——
取证通道自己先吵起来，然后你就不再看它了）。

⚠️ **复现要发 `RST`**：普通 `close()` 只发 `FIN`（半关闭），服务器**仍可以写**，测不出 `EPIPE`。
需要先 `SO_LINGER = (1, 0)` 再 `close()`。本次验证：`--throttle 3000`，
客户端读 200 字节后断开 ⇒ 修复前整段 traceback / 修复后 5 行 `[net]`、零 traceback。

---

## P-063 · "取证断流"要么是**通道**断、要么是**对象**停 —— 用**业务计数值**分

**现象**：真机 RTSP 长跑时，每秒一条的采样**整整空了 214.7 秒**
（`[status]` 与 `[mem]` **同时**空），而 App 没崩、恢复后状态照旧（仍是 `.playing`）。

两种可能，**排查方向完全相反**：

| 可能 | 含义 |
| --- | --- |
| **通道断**（日志桥/console 转发挂了） | 对象**一直在跑**，只是没人记录 |
| **对象停**（进程被挂起 / 冻结） | **真的没在跑** |

**判据**：看**断点前后的业务计数值**（这里是播放位置 `t`），而不是看"日志有没有"：

```
断点前  172.1 s   t = 169.08
断点后  386.8 s   t = 169.75      ← 墙钟 +214.7 s，业务只 +0.67 s
```

⇒ **对象真的停了**（若 `t` 也 +214 s，那才是通道的问题）。

⚠️ 与 `P-058` 是**一对**：那次是**通道**断（mpv 明明在打 `Still buffering`、进度在走），
这次是**对象**停。**两次都表现为"日志没了"，处置完全不同** ⇒
先分这一点，再去解读最后几行。

**顺带（同一次观察，服务端一侧可独立证实 —— 比只看客户端日志强）**：
挂起后 14 秒，mediamtx 报 `reader is too slow, discarding 14 frames`，
再过 1 秒 `write tcp …: i/o timeout` 拆连接。
⇒ **"客户端不再读了"这个事实，两端都能看见**。

---

## P-064 · `#expect` 的说明参数**只能是一个字符串字面量** —— 拼接会让它变成 `String`

**现象**：写一条信息量很足的断言时把说明拆成两段拼接，编译直接失败：
```swift
#expect(
    snapshot.videoTracks.selectedTrackID == nil,
    "内核还没回读之前就显示「已切到某档」，等于界面在替内核说话；"
        + "实测 selectedTrackID=\(String(describing: snapshot.videoTracks.selectedTrackID))"
)
// error: cannot convert value of type 'String' to expected argument type 'Comment?'
```

**根因**：`#expect(_:_:)` 的第二个形参是 `Comment?`（一个 `ExpressibleByStringInterpolation` 的**专用类型**），
而 `"a" + "b"` 求值出来的是**普通 `String`** —— 两者之间**没有隐式转换**。
字面量（含插值）能直接构造 `Comment`，**运算结果不能**。

**处置**：整段写成**一个字面量**，需要换行就用长字面量 + 插值，**不要在参数位置做字符串运算**：
```swift
#expect(
    snapshot.videoTracks.selectedTrackID == nil,
    "内核还没回读之前就显示「已切到某档」；实测 selectedTrackID=\(String(describing: snapshot.videoTracks.selectedTrackID))"
)
```

**防再犯**：这不是运行时问题，**编译期必现** —— 写完一条长说明的断言就立刻编一次，
别攒到最后一次性编（攒着会把"写法错"和"逻辑错"混在同一批报错里）。

---

## P-065 · `swift test` 的汇总**不是一份**：多个测试目标各打一份，`| tail` 只会看到一个

**现象**：我给 `PlayerUITests` 新增了 16 条用例，重跑全量测试，汇总行**纹丝不动**：
`✔ Test run with 229 tests in 21 suites passed`。第一反应是"新用例根本没被编译进去"。

**真因**：根包有**两个**测试目标（`PlayerCoreTests` / `PlayerUITests`），
每个目标是一个**独立的测试进程**，**各打一份** `Test run with …` 汇总 —— 而我一直用
`swift test … | tail -30` 收口，于是**永远只看到排在最后的那一份**（Core 的 229）。
真实的输出是两份：

```
✔ Test run with  92 tests in 12 suites passed after 0.702 seconds.   ← PlayerUITests
✔ Test run with 229 tests in 21 suites passed after 0.008 seconds.   ← PlayerCoreTests
```

**后果（比数字本身严重）**：前几轮我报的「根包 229 tests 全绿」**只覆盖了 `PlayerCoreTests`** ——
UI 那 92 条**从来没进过证据**。数字对、结论窄：这类偏差不会被任何断言抓到，
只会让"我们验了多少"悄悄少一块。

**处置 / 判据**：
- 收集测试输出**不要用 `tail` 当"全量"**：写到文件，再 `grep -n "Test run with"` 逐份读。
- **判据：汇总行出现几次，就有几个测试目标。** 数字要以**逐份相加**为准，不能以最后一行为准。
- 与 `P-027`（失败行不在常见匹配模式里）同族：**取证形态本身会掩盖一半事实**。

**防再犯**：报"测试全绿"时，**路径上几个测试目标，就给几份数字**（本仓库 = 2）。

---


> ### 与既有条目同源、故不重复展开的（仅登记映射，便于日后合并检索）
>
> | 其他项目的条目 | 本项目已有 |
> | --- | --- |
> | `Marquee` V137（嵌套沙箱，`swiftc -disable-sandbox`；官方那三个参数无效） | **`P-024`** |
> | `Marquee` R117（变异不变红 = 断言盲 or 死代码） | **`P-017`** |
> | `Marquee` G50（Swift 6 `nonisolated deinit` + 非 Sendable） | **`P-022`** |
> | `HabitLoop` #6（swift-testing 失败行不在常见匹配模式里） | **`P-027`** |
> | `Marquee` F39/F40（宿主沙箱里 `xcodebuild` 编不过 SwiftUI 宏；判据：SwiftPM 能过、`xcodebuild` 不能 ⇒ 环境问题） | **`P-024`** + 技能 `apple-build-sandbox` |






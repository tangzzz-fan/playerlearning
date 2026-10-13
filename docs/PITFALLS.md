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






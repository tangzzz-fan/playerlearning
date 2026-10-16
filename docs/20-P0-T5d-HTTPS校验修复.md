# `P0-T5d` HTTPS 证书校验修复 —— **一行产品选项** + 一处配方修复

> **2026-10-16 · 起点**：[`docs/18`](18-P0-T5c-HTTPS行为验证.md)（`P0-T5c` 验出"HTTPS 只加密、不校验证书"）
> **终点**：不受信任的证书被拒 / 装进信任库的 CA 被接受 —— **六条探针 + 真机**全部符合预期。
> 票面：[`docs/03`](03-路线图.md) `Phase 0` 📌 · [`docs/04`](04-开工前准备清单.md) §3（P0 票面表）。

---

## 一、结论先说

| # | 结论 |
| - | --- |
| 1 | **真因有两层，而起作用的是第一层**：mpv 的 `--tls-verify` 在**代码里默认是 `false`**（`stream_lavf_params` 的 `defaults` 里没有这一项 ⇒ 零值；手册**根本没写默认值**），而它**无条件**把 `tls_verify=0/1` 传给 lavf ⇒ **FFmpeg 一直在走"不校验"那条分支** |
| 2 | **修法就是一行产品选项**：`tls-verify=yes`。**FFmpeg 不需要改** —— verify=1 时 FFmpeg 不设 `BreakOnServerAuth`，改由 SecureTransport 做**它自己的默认认证**，而实测**它是正确且完整的**（校根、校主机名、查系统信任库） |
| 3 | ⚠️ **更正 `docs/18` 的一处结论**：那里写的"**在这个产物上不存在任何会校验的配置**"**是错的**。它建立在"`verify=1` 已经在生效"这个**没被验证的假设**上，而实际 mpv 一直在传 `0`。⇒ 教训同 `P-073`：**默认值/参数值必须实测，不能从上游源码的默认值推** |
| 4 | 顺带修好一处**配方缺陷**：产物里有一处改动（VideoToolbox 像素缓冲的 **Metal 兼容**）**不在配方里**，而"给这个目录加补丁"这个动作会**把它清掉**（`P-078`）⇒ 已固化成独立补丁 |
| 5 | 顺带发现 mpvkit 的补丁机制**在"补丁里再套补丁"时会静默失败**（`P-079`）：`try!` 吞掉了 `git apply` 的失败 ⇒ 产物少一处改动而**零报错** |

---

## 二、验证矩阵（模拟器，iPhone 18 Pro / iOS 27）

**所有探针只改一个变量**（服务器证书的签发根 / 名字），播放器与代码完全不动：

| # | 场景 | 签发根 | 名字 | 期望 | 实测 |
| - | --- | --- | --- | --- | --- |
| ① | **明文 http 对照** | — | — | 能播 | **`playing`** ✅（无回归） |
| ② | HTTPS · 根未受信任 | CA1（当时未装信任库） | 匹配 | 必须失败 | **`failed`** ✅ |
| ③ | HTTPS · 名字不匹配 | CA1 | `wrong.example.com` | 必须失败 | **`failed`** ✅ |
| ④ | HTTPS · **根装进信任库** | CA1（`simctl keychain add-root-cert`） | 匹配 | **必须通过** | **`playing`** ✅ |
| ⑤ | HTTPS · 根受信任但名字不匹配 | CA1 | `wrong.example.com` | 必须失败 | **`failed`** ✅ |
| ⑦ | HTTPS · **另一个根**（从未装过） | CA2 | 匹配 | 必须失败 | **`failed`** ✅ |

**这六条为什么足以定案**：

- **④ vs ⑦ 只差"哪个根"**（同一份代码、同一个名字、同一种证书形状）⇒ **系统信任库确实被查询**，
  而不是"什么都放行"或"什么都拒绝"；
- **⑤**（根受信任、名字不匹配仍失败）⇒ **主机名校验也在生效**；
- **②③** ⇒ 未受信任必失败；
- **①** ⇒ 明文路径无回归。

> ④ 正是 `P0-T5c` 报告里那条"**无法进行**"的判据 —— 当时连"证书完全正确"的那台都打不开
> （因为 `verify=0` 之下，`tls-ca-file` 一给就让 `import_pem` 失败 ⇒ 连接直接断）。
> 现在它成了**决定性的一条**。

### 真机（iPhone 16 Pro）

| 场景 | 期望 | 实测 |
| --- | --- | --- |
| 明文 http 对照（`http://192.168.2.217:8768/…`） | 能播 | **`playing`**，`t=12.00/52.21` 持续推进 ✅ |
| HTTPS · 根未受信任（证书 SAN 与连接地址一致） | 必须失败 | **`failed`** ✅ |

⚠️ **真机上不装 CA**：那要动用户手机的信任设置（系统设置 → 证书信任），属**不可逆的真实动作** ⇒
正向那一条只在模拟器上验。这不是"没验"，是**刻意的边界**（同 `docs/18` §六 的处理）。

> 真机这一格**必须跑**：本轮的模拟器绿灯一度是**理由错的**（见 §五 5.3 `P-081`）——
> 模拟器上"能跑"是因为 app 从**构建树**里加载了同一个 dylib，而不是从装箱的框架里。

---

## 三、根因：两层，各在哪一环

```
mpv  --tls-verify (代码默认 false，手册未写默认值)
      └─ av_dict_set(dict, "tls_verify", "0")        ← 无条件传，第 1 层
            └─ lavf: s->verify = 0
                  └─ tls_securetransport.c:
                        if (!s->verify) continue;     ← 校验分支被跳过（第 2 层的放大器）
                              ⇒ 任何证书都接受
```

| 层 | 在哪 | 证据 |
| --- | --- | --- |
| **1（起作用的是它）** | mpv `stream/stream_lavf.c`：`{"tls-verify", OPT_BOOL(tls_verify)}` + `defaults` 里**没有** `tls_verify` + `av_dict_set(dict, "tls_verify", opts->tls_verify ? "1" : "0", 0)` | 手册 `DOCS/man/options.rst:5605` 只写"Verify peer certificates"，**没写默认值**；代码里是零值 ⇒ false |
| 2 | FFmpeg `tls_securetransport.c`：`if (s->ca_file \|\| !s->verify)` 才设 `BreakOnServerAuth` | 上一轮（`P0-T5c`）已经查到，但当时把它当成了唯一的因 |

**有意思的是第 2 层在 verify=1 时并不咬人**：verify=1 且没给 `ca_file` ⇒ FFmpeg 不设 break ⇒
SecureTransport 按**它自己的默认行为**完成认证 —— 而实测它做得很完整（见 §二）。
⇒ **不需要给 FFmpeg 打补丁**。（那条"补丁"我写过、也构建验证过，最后**删掉了**：
它把认证从系统默认行为换成我们自己的 `SecTrustEvaluate` 调用，**没有任何可量化的收益**，
却多一份上游维护成本 —— 铁律 1。）

---

## 四、改动（产品侧只有一行）

`MPV/Sources/PlayerMPV/MPVKernel.swift` · `applyNetworkOptions`：

```swift
// ⚠️ 必须显式打开证书校验（P0-T5d）。这是一条默认值陷阱：
//    mpv 的 --tls-verify 在代码里默认是 false（defaults 里没有这一项 ⇒ 零值；
//    手册也没写默认值），而它无条件把 tls_verify=0/1 传给 lavf
//    ⇒ 不写这一行，FFmpeg 永远走"不校验"那条分支。
setOption(handle, "tls-verify", "yes")
```

**它的接受性由既有用例兜底**：`testEveryConfiguredOptionIsAcceptedByMPV`
（选项名写错时 mpv 只返回负值、不报错 —— 那条用例把"我设了"变成"它认了"）。

---

## 五、配方修复（两处，都不影响产品行为）

### 5.1 `P-078`：产物里有、配方里没有

FFmpeg 源码树里躺着一处**未提交改动**：`libavcodec/videotoolbox.c` 把像素缓冲的
`kCVPixelBufferOpenGLESCompatibilityKey` 换成 **`kCVPixelBufferMetalCompatibilityKey`**（MoltenVK 互操作要它）。

- **它在不在产物里**？符号级证据：`nm -u Libavcodec` 里 `kCVPixelBufferMetalCompatibilityKey` **1 命中**、
  `kCVPixelBufferOpenGLESCompatibilityKey` **0 命中** ⇒ **在**；
  而配方（`spike/` 的 01/02 两个补丁）里**没有它**。
- **危险之处**：mpvkit 的 `base.swift` 把 `git checkout .` 关在"补丁目录存在"这个条件里 ⇒
  **目录不存在时手工改动被保留并编译进产物**；一旦为别的目的创建这个目录，
  **同一次构建就会把它清掉**。

⇒ 处置：固化为独立补丁 `spike/p0-t5b-lgpl-dynamic-build/ffmpeg/0001-videotoolbox-metal-compatibility.patch`，
并在重构建后**验证它仍在新产物里**（符号检查）。

### 5.2 `P-079`：嵌套补丁会**静默失败**

第一版把 FFmpeg 补丁**装在一个 git patch 里**（外层 patch 创建内层 patch 文件）送进 mpvkit。
实测：`0001`（Metal）应用成功、`0002`（TLS）**悄悄没上** ——
mpvkit 那边是 `try! Utility.launch(... "apply" ...)`，**失败不抛**；
而外层 patch 传递时那行"只有空格的上下文行"被弄坏了（`git apply` 的 trailing-whitespace 警告正是它）。

⇒ 处置：**不再嵌套**。`build.sh` 直接把 `ffmpeg/*.patch` **拷**进 mpvkit 的补丁目录：

```bash
if [ -d "$HERE/ffmpeg" ]; then
  mkdir -p "$SRC/Sources/BuildScripts/patch/FFmpeg"
  cp "$HERE"/ffmpeg/*.patch "$SRC/Sources/BuildScripts/patch/FFmpeg/"
fi
```

**判据**：构建日志里必须有 `copied 1 ffmpeg patch(es)`，且构建后**用符号检查确认补丁落地**
（`nm -u` 那一项）—— 不能只看"我传了补丁"。

### 5.3 `P-081`：漏跑 postprocess ⇒ **真机崩、模拟器"能跑"**

配方是**两步**，第一步只管编译；**第二步** `postprocess-framework.sh` 才把
产物 dylib 的 `install_name` 从**构建树绝对路径**改成 `@rpath/Libmpv.framework/Libmpv`。

漏跑它的后果**很有欺骗性**：

| 环境 | 表现 | 原因 |
| --- | --- | --- |
| 真机 | app 启动即崩（`Library not loaded: /private/tmp/…/libmpv.2.dylib`） | 那个路径在手机上不存在 |
| **模拟器** | **一切正常，探针全过** | 模拟器**跑在宿主机上** ⇒ 那个 `/private/tmp/…` 路径**真的存在**，于是它加载的是**构建树里的那份**（内容恰好相同 ⇒ 结论侥幸没错，但**证据路径不对**） |

**处置**：构建后**必核** `otool -D … == @rpath/Libmpv.framework/Libmpv`；
并且**"模拟器通过"不能替代"真机验证"**（本轮真机那条就是因此才补上的 —— 见 §二）。

---

## 六、仍未覆盖 / 边界

| 项 | 说明 |
| --- | --- |
| 真机上"装 CA 后能播" | **刻意不验**：要动用户手机的信任设置（不可逆真实动作）⇒ 正向只在模拟器验 |
| `simctl keychain reset` 到底会不会撤销信任 | **实测不会**（reset + 重启后同一个 URL 仍能播）⇒ 本轮改用"**换一个从未装过的根**"来闭合因果，比"撤销"更干净。见 `P-079` 姊妹条目（`P-080`） |
| 撤销 / 过期 / 吊销（OCSP）路径 | **未验**：需要可控的 CRL/OCSP 环境 |
| 公网真实站点的 HTTPS 播放 | **未验**：本会话出网要过 MITM 代理，证书链不是"真实世界"的那一条 |

---

## 七、方法（可复现）

```bash
# ① 造两个根（一个用来"装进信任库"，一个用来做"从未装过"的对照）
#    证书硬要求：SAN 必填 · EKU=serverAuth · RSA≥2048 · 有效期 ≤825 天
# ② 起三台服务器，只换证书：CA1/名字匹配(8443) · CA1/名字不匹配(8445) · CA2/名字匹配(8447)
python3 Tools/serve-range.py --port 8443 --root /tmp/vidprobe2 \
  --tls-cert /tmp/pl-tls/server.crt  --tls-key /tmp/pl-tls/server.key
python3 Tools/serve-range.py --port 8445 --root /tmp/vidprobe2 \
  --tls-cert /tmp/pl-tls/mismatch.crt --tls-key /tmp/pl-tls/mismatch.key
python3 Tools/serve-range.py --port 8447 --root /tmp/vidprobe2 \
  --tls-cert /tmp/pl-tls/other.crt   --tls-key /tmp/pl-tls/other.key

# ③ 装/不装信任，各跑一次（⚠️ 清代理变量，P-059）
xcrun simctl keychain <UDID> add-root-cert /tmp/pl-tls/ca.crt
env -u HTTP_PROXY -u HTTPS_PROXY xcrun simctl launch --terminate-running-process \
  --console-pty <UDID> com.playerstack.demo -- -directURL https://127.0.0.1:8443/sintel_trailer-720p.mp4

# ④ 判据：看服务端日志里有没有 `[tls] 握手失败：… certificate unknown`
#    —— 那是"客户端真的校验并拒绝"的直接证据（只看客户端"没收货"分不清"被拒"与"没连上"）
```

**重构建产物**（改了配方之后）—— ⚠️ **两步，缺一不可**：

```bash
cd /Users/tango/Developments/playerlearning
WORK=/tmp/p0t5b-build spike/p0-t5b-lgpl-dynamic-build/build.sh            # ① 编译（应用 ffmpeg/0001）
WORK=/tmp/p0t5b-build spike/p0-t5b-lgpl-dynamic-build/postprocess-framework.sh  # ② 修 install_name
./Tools/stage-libmpv.sh                                                  # ③ 装入 MPV/Library

# ④ 两条必核（都在产物上，不在日志里）：
nm -u MPV/Library/Libmpv.xcframework/ios-arm64/Libmpv.framework/Libmpv \
  | grep -c kCVPixelBufferMetalCompatibilityKey                          # 补丁落地 ⇒ 必须 ≥1
otool -D MPV/Library/Libmpv.xcframework/ios-arm64/Libmpv.framework/Libmpv \
  | tail -1                                                              # ⇒ 必须是 @rpath/Libmpv.framework/Libmpv
```

> 本轮实测：`build.sh` 6 分 56 秒（把其余 20 个依赖的 builder 临时注释掉、只跑 FFmpeg + mpv；
> **跳过的库其产物 105 个文件逐字节未变**，等价可证）。

---

## 八、一句话

**真因是 mpv 的 `--tls-verify` 默认 `false`（手册里根本没写默认值），而它把 `tls_verify=0`
无条件传给 FFmpeg ⇒ 一行 `tls-verify=yes` 就让校验真正发生（不受信任必失败 / 装进信任库必通过 /
名字不匹配必失败 / 明文无回归，六条探针全中）；FFmpeg 不需要改 ——
上一轮"没有会校验的配置"那句结论是**建立在没被验证的假设上**的，
顺带还把产物里"不在配方中"的一处改动和补丁机制的静默失败都补上了。**

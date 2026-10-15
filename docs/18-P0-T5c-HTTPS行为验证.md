# `P0-T5c` HTTPS 行为验证 —— **结论：HTTPS 只提供加密，不校验对端身份**

> **2026-10-16 · 模拟器（iPhone 18 Pro / iOS 27）+ 真机（iPhone 16 Pro / Tango）**
> 上一环：[`docs/07`](07-P0-T5b验证报告.md) §六 未验项 #1 ——
> 「**SecureTransport 的实际 TLS 行为**：只验了「协议已启用」，**未做 HTTPS 实际流播放**。
> ⚠️ **这是本次唯一带风险的替换**」。本票就是去关掉它。
> 票面与先例登记在 [`docs/03`](03-路线图.md) 的 `Phase 0` 📌。

---

## 一、结论先说

| # | 结论 |
| - | --- |
| 1 | **「HTTPS」在这个产物上只保密、不认证**：不受信任的自签、甚至**名字不匹配**的证书，**真机与模拟器都照播**。同一台服务器，宿主 `curl`（`libcurl … (SecureTransport)`，**同一个 TLS 后端**）则**拒绝** |
| 2 | 根因**不在我们的代码**，在 FFmpeg 的 SecureTransport 后端：校验只在 `ca_file != nil` 时才被触发；而这个产物 **`HAVE_SECITEMIMPORT 0`** ⇒ **CA 文件永远加载不了**（实测：给了 `tls-ca-file` 之后，连证书完全正确的那台也打不开） |
| 3 | ⇒ **在这个产物上不存在任何"会校验证书"的配置**。三条路全堵：`verify=1`+无 CA ⇒ 不触发；`verify=1`+有 CA ⇒ 加载失败；`verify=0` ⇒ 明示不校验 |
| 4 | 它**长期没被发现**，是因为三件事凑在一起：`tls_verify` **默认值就是 1**（读代码会以为在校验）· mpv 511 行 verbose 日志里**关于 TLS 一个字都没有** · 而症状（"HTTPS 能播"）恰好是**期望**的结果 |
| 5 | 修复需**重构建产物**（打补丁或换后端）+ **产品级决策** ⇒ 见 §五，**已留待拍板，未擅自动** |

> ⚠️ **顺带更正一条推断**：`P0-T5b` 之后的侦察写的是「SecureTransport = 走 **iOS 系统信任库**」。
> 依据是导入符号里有 `SecTrustEvaluate` / `SecTrustSetAnchorCertificates`。**实测证伪**：
> 系统信任库**从未参与** —— 那条 `SecTrustEvaluate` 根本执行不到（§四）。

---

## 二、判据与结果

票面（`docs/03` 的 `Phase 0` 📌）定的四条判据：

| # | 判据 | 结果 |
| - | --- | --- |
| ① | 对照：同一台服务器、同一路径的**明文 http 能播** | ✅ 通过 · `state=playing`（排除"连不上/路径错"） |
| ② | **不受信任的证书必须失败** | ❌ **未通过 —— 播了**（模拟器 + 真机） |
| ③ | **名字不匹配的证书必须失败** | ❌ **未通过 —— 播了** |
| ④ | 装 CA 进信任库后同一个 URL 必须能播 | ⛔ **无法进行**：校验路径本身是坏的（§三 E4），装 CA 救不了一条走不到的代码 |

⇒ **票面结论：`SecureTransport` 换掉 gnutls 这件事，确实兑现成了「唯一带风险的替换」——
风险的内容是"HTTPS 形同只有加密"。** 这不是"未验"，是**已验证的缺陷**。

---

## 三、实测矩阵（同一份客户端代码，只换服务器证书）

### 3.1 默认配置（产品现在就是这样）

| # | 场景 | 服务器证书 | 期望 | 实测（模拟器） | 实测（真机） |
| - | --- | --- | --- | --- | --- |
| E0 | 明文对照 | 无 | 播 | ✅ `playing` | — |
| E1 | **根不受信任** | 自签 CA1 签发 · SAN=`127.0.0.1` | 必须失败 | ❌ **`playing`** | ❌ **`playing`** |
| E2 | **名字不匹配** | CA1 签发 · SAN=`wrong.example.com` | 必须失败 | ❌ **`playing`** | —（未跑，E1 已足够） |
| E3 | **对照：宿主 curl** | 同 E1 / E2 | 拒绝 | ✅ `000`（拒） | ✅ |

E1 的真机证据（**服务器侧**日志：不受信任的自签证书 + 真机 IP）：

```
[range] serving /tmp/vidprobe2 on https://0.0.0.0:8446 …
[tls] 客户端要先用 `xcrun simctl keychain <udid> add-root-cert <ca.crt>` 信任签发者
[range] 192.168.2.253 "GET /sintel_trailer-720p.mp4 HTTP/1.1" 206 -      ← 真机真的连上了、取走了数据
[range] 192.168.2.253 "GET /sintel_trailer-720p.mp4 HTTP/1.1" 206 -
```

**为什么 E3 这条对照是必需的**：只看到"客户端收货了"是不够的 —— 它与"压根没连上 / 路径写错"
**看起来一样**（`P-056` 的判据）。E3 用的是**同一个 TLS 后端**（`curl -V` → `libcurl/8.7.1 (SecureTransport)`），
它拒了 ⇒ **SecureTransport 有能力校验，是我们的配置路径没走到校验**。

### 3.2 反证：给 `tls-ca-file` 之后（说明"那条路是坏的，不是生效的"）

临时给内核加 `tls-ca-file = <CA1 的 PEM>`（实验代码，**已撤**），三个正交探针：

| # | 场景 | 期望 | 实测 |
| - | --- | --- | --- |
| E4 | CA1 签发 · 名字匹配 · 指向 **CA1** | **应通过** | ❌ **失败** |
| E5 | CA1 签发 · 名字不匹配 | 失败 | 失败（原因不明，与 E4 同形） |
| E6 | **CA2** 签发 · 名字匹配 · 指向 CA1 | 失败 | 失败（同上） |

**E4 是最有价值的一行**：证书、名字、CA 全对，它**还是打不开** ⇒ 说明失败**不在"校验太严"，
而在"CA 文件根本没被读进来"** ⇒ 直接把根因指向 `import_pem`（§四）。

---

## 四、根因（从源码到符号，逐环闭合）

| # | 环节 | 证据 |
| - | --- | --- |
| 1 | 只有一条 TLS 后端 | `config.h`：**`CONFIG_SECURETRANSPORT 1`** · `CONFIG_OPENSSL 0` |
| 2 | FFmpeg **认为**它在校验 | `libavformat/tls.h:93`：`{"tls_verify", "Verify the peer certificate", …, { .i64 = **1** }, …}` —— **默认值就是 1** |
| 3 | 但校验只在一条分支里 | `tls_securetransport.c` 的 `tls_open`：<br>`if (s->ca_file \|\| !s->verify) SSLSetSessionOption(…, kSSLSessionOptionBreakOnServerAuth, true);`<br>而 `SecTrustEvaluate` **只在** `errSSLServerAuthCompleted`（= 那个 break 触发）里执行 |
| 4 | 所以 `verify=1` + 无 CA ⇒ **什么都不发生** | 不设 break ⇒ 那个分支永不进入 ⇒ 不校验。<br>（实测 E1/E2 与此完全一致） |
| 5 | 而"给个 CA"这条路也堵死 | `import_pem` 开头：`#if !HAVE_SECITEMIMPORT return AVERROR_PATCHWELCOME;`<br>`config.h`：**`HAVE_SECITEMIMPORT 0`** |
| 6 | 符号级复核（防"配置与产物不一致"） | 产物 `nm -u`：`SecItemImport` **0 命中**；对照 `SSLHandshake` / `SecTrustEvaluate` **有命中**（dump 有效） |

**⇒ 逻辑闭合**：`verify=1` 是给读代码的人看的，实际执行路径只有两条 ——
「有 CA（走不通）」和「没 CA（什么都不做）」。**没有任何组合会做校验。**

> 补充一句为什么 `kSSLSessionOptionBreakOnServerAuth` 的缺席等于"不校验"：
> 该选项的作用正是**把校验时机交回调用方**；FFmpeg 只在"要注入自定义 CA"或"明确不校验"时才打开它，
> 于是"默认应该由 SecureTransport 自己认证"这条假设**在实测中不成立**（E1/E2/E3 三行合起来就是它的证伪）。

---

## 五、修复路径（**三条，需拍板；都不是"一行开关"**）

| # | 做法 | 得到什么 | 代价 |
| - | --- | --- | --- |
| **A** | **给 FFmpeg 打补丁**：`ca_array == nil` 时**无条件**打开 `kSSLSessionOptionBreakOnServerAuth`，并跳过 `SecTrustSetAnchorCertificates`（让 trust 用它自带的系统锚点） | 那条 `SecTrustEvaluate` **真正跑起来**，且**用系统锚点** ⇒ **iOS 系统信任库真的生效**：`simctl keychain add-root-cert`、用户自签、MDM 下发的根**都能用** | 改上游代码 ⇒ 要重构建产物；将来升 FFmpeg 要重放补丁（**本项目已有 patch 机制**，`P0-T5b` 就是 5 处改动） |
| **B** | 换 **`--enable-openssl`** 重建产物（`docs/07` L162 已记的回退路径）+ **随包一份 CA 列表** | 真正校验（对着随包列表） | 重构建 + 产物体积增加 + **随包 ~200 KB CA** + 自维护根列表更新。⚠️ 注意：**换后端并不能免掉随包** —— OpenSSL 在 iOS 上也没有系统兜底路径（`/etc/ssl/cert.pem` 本机查过：**iOS 27 运行时里已不存在**）。而且信任模型从"系统库"变成"我们维护的列表"：**用户自己装的根不生效** |
| **C** | 接受现状，但**显式声明**："HTTPS 只加密、不校验证书" | 零成本 | 保留安全缺口。至少要写进对外文档，**不能让"支持 HTTPS"被读成"校了身份"** |

**我的推荐：A。**
- 它把"唯一带风险的替换"真正收敛，且**零随包资源**（不用多维护一份根列表）；
- 它得到的语义与 iOS 惯例一致（用户/企业自签可用），而 B 恰好相反；
- 补丁面很小（一个条件 + 一处跳过），且本项目**本来就在维护 FFmpeg patch**，边际成本低。

⚠️ 无论选 A 还是 B，都要**重构建产物**并重新验一遍 §三 的 E1/E2（不受信任必须失败）
与"装 CA 后必须通过"—— 后者在本轮**没法做**，因为当前根本走不到校验（判据 ④）。

---

## 六、没做的项（**没拍板就不动**）

| 项 | 为什么不动 |
| --- | --- |
| 改产品默认（把校验打开） | 那等于**改信任模型** = 产品级决策，且必须先把 A/B 定下来 |
| 重构建 104 MB 产物 | 属"改变产物"的动作；且要先定 A 还是 B |
| 给真机装根证书 / 改信任设置 | 那是**动用户手机的不可逆真实动作**，本票全程只用模拟器验信任相关的东西 |
| 保留 `tls-ca-file` 的实验开关 | 在这份产物上它**只会把 HTTPS 弄坏**（E4–E6）⇒ 撤掉，不留 footgun |
| 验证 `--enable-openssl` 是否真能校验 | 需要先重建产物（属上面第 2 条） |

---

## 七、方法与环境（可复现）

```bash
# ① 一次性证书（/tmp，不入仓库）。三项硬要求少一条会得到"另一种失败"：
#    SAN 必填 · extendedKeyUsage=serverAuth · RSA≥2048 · 有效期 ≤825 天
#    —— 造一个 CA + 由它签发的服务器证书（CN=连接地址，SAN 与之一致）
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 \
  -subj "/CN=PlayerStack Test CA" -addext "basicConstraints=critical,CA:TRUE"

# ② 起 HTTPS 服务器（本票给 Tools/serve-range.py 新增的开关）
python3 Tools/serve-range.py --port 8443 --root /tmp/vidprobe2 \
  --tls-cert /tmp/pl-tls/server.crt --tls-key /tmp/pl-tls/server.key

# ③ 模拟器上跑（⚠️ 必须清代理变量：代理会劫持回环请求，P-059）
env -u HTTP_PROXY -u HTTPS_PROXY xcrun simctl launch --terminate-running-process \
  --console-pty <UDID> com.playerstack.demo -directURL https://127.0.0.1:8443/sintel_trailer-720p.mp4

# ④ 真机跑（证书 SAN 要写宿主的局域网地址，否则多一个"名字不匹配"的变量）
python3 Tools/serve-range.py --port 8446 --host 0.0.0.0 --root /tmp/vidprobe2 \
  --tls-cert /tmp/pl-tls/lan.crt --tls-key /tmp/pl-tls/lan.key
xcrun devicectl device process launch --device <UDID> --console --terminate-existing \
  com.playerstack.demo -- -directURL https://192.168.x.x:8446/sintel_trailer-720p.mp4
```

**服务器侧的 `[tls] 握手失败：… unknown ca` 是"客户端**真的**校验并拒绝"的直接证据**（本票新增）——
只看客户端"没收货"是不够的：那与"没连上"**看起来一样**。

**本票踩到的两个环境坑**（都记入 `PITFALLS`）：
- `xcrun simctl launch --stdout=<path> --stderr=<path>` **落不下东西**（文件被创建、内容 0 字节）
  ⇒ 改用 `--console-pty` + 自己重定向（与真机那条 `devicectl --console` 同构）。
- **重装 app 会换数据容器路径** ⇒ 放在容器里的测试文件要用**装完之后**查到的路径，
  否则拿到的是上一次容器的路径（本票在这里空跑了一轮）。

---

## 八、一句话

**「SecureTransport 换 gnutls」这条唯一带风险的替换，兑现成了一个具体的安全缺陷：
这个产物上的 HTTPS 只加密、不认证 —— 不受信任、甚至名字不匹配的证书都会被接受
（真机与模拟器一致，宿主 `curl` 用同一个后端则拒绝）；根因是 FFmpeg 的校验只在
`ca_file` 非空时才触发，而这份构建 `HAVE_SECITEMIMPORT 0` 让 CA 文件永远加载不了。
修复要重构建产物，已按其代价列出三条路（推荐打一个小补丁、让系统信任库真正生效），
等拍板。**

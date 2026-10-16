# `P6-T5` HLS 直播源：起播 + 轨道清单

> **2026-10-16 · 真机 iPhone 16 Pro（Tango）· 三档 HLS 直播（滑动窗口 6 × 2 s）**
> 票面与判据见 [`docs/03`](03-路线图.md) 的 `Phase 6` 📌。
> 这一票补的是**两个已验证区域之间的一条缝**：直播只验过 RTSP（`P6-T1/T2/T3`），
> 多档只验过 HLS **VOD**（`P5-T5`）—— **「HLS 直播」这一格从来没有任何一票覆盖过**。

---

## 一、结论先说

| # | 结论 |
| - | --- |
| 1 | **HLS 直播能播、能切档、能持续** —— 42 s 全程 `playing`、**0 次 `failed`**、跨 ~20 次 playlist 重载 |
| 2 | **多档直播的档位清单与 VOD 一致**：3 条（`1280×720` / `854×480` / `426×240`），切到 `id=2` 后回读 `854×480`。滑动的 live playlist **不影响**档位枚举 |
| 3 | **起播 492 ms**（`file-loaded` 492.3 → 出画 492.4，几乎同时）。HLS 是**拉取式** ⇒ `P6-T4` 的短探测窗口规则**不作用于它**，而它本来就不慢（对比：HTTP mp4 178–234 ms · HLS VOD 463 ms） |
| 4 | **live playlist 下 `duration` = 滑动窗口的末端**，与 `t` 一起增长（实测 `t=40.74/42.16`）⇒ **UI 的进度百分比在直播下没有意义**（`progress` 实测在 0.53–0.96 之间抖，恒在 0.9 以上） |
| 5 | ⭐ **票面点名的那个"HLS 直播独有失败形态"没有发生，原因值得记**：把带宽限到 200 KB/s（远低于 720p 档需要的 ~362 KB/s）后，播放器**没有**回头去要已被删除的分片 —— 服务端 **0 次 404**，抓到的分片是 `105→106→107→**109**→110→**113**→**115**→**118**→…`（**中间是跳过的**）⇒ 它是**丢内容、追直播边缘**，不是"回退取已删分片 ⇒ 失败" |

---

## 二、判据结果（票面写下的五条）

| # | 判据 | 结果 |
| - | --- | --- |
| ① | 能起播并**持续 ≥ 30 s**（跨多次 playlist 重载） | ✅ 42 s 全程 `playing`；服务端可见 ~20 次 `v0/index.m3u8` 重载 |
| ② | **多档 HLS 直播的档位清单被枚举** + 切档后回读 | ✅ 3 档 → 切 `id=2` → `清晰度=854×480（共 3 档）` |
| ③ | 起播延迟用 `P6-T4` 的 `[startup]` 量出来 | ✅ **492 ms**（限速轮 2228 ms） |
| ④ | 直播的 `duration` 语义**如实记录** | ✅ 见 §四.1（**不是** VOD 的"总时长"） |
| ⑤ | 全程不 `failed`、`t` 持续推进 | ✅ 0 次；`t` 从 2.20 → 40.74 |

---

## 三、实测（两轮）

### 3.1 正常链路（不限速）

```
[startup] 出画=492ms · 内核说在播=492ms · 分段: handle-created=0.9 options-applied=1.1
          initialized=1.9 loadfile-sent=2.0 file-loaded=492.3 playing=492.3 vo-configured=492.4
[tracks]  可选档位 3 条 · 清晰度菜单会出现
[tracks]    id=1  1280×720  ← 当前
[tracks]    id=2  854×480
[tracks]    id=3  426×240
[tracks]  切到 id=2 854×480
[tracks]  切档 3 秒后 → state=playing t=4.20/5.54 … 清晰度=854×480（共 3 档）
[status]  41.130 state=playing t=40.74/42.16 progress=0.966 buffering=false …
```

**服务端侧证据**（每一行都是真机 `192.168.2.253` 发出的）：

```
"GET /master.m3u8"      206      ← 清单
"GET /v0/index.m3u8"    206      ← 三个 variant 各探一次
"GET /v1/index.m3u8"    206        这正是"3 条 video track"的来源
"GET /v2/index.m3u8"    206
"GET /v0/seg059.ts" … "GET /v0/seg080.ts"   22 个分片（每 2 s 一个）
"GET /v0/index.m3u8" × ~20                   ← **playlist 在被反复重载**（直播的标志）
```

⚠️ **要区分"直播"与"VOD"不能只看客户端**：`[status]` 里两种都是 `state=playing`。
判据在**服务端**：① playlist 被**反复**请求；② playlist 里**没有** `#EXT-X-ENDLIST`
（本轮的 variant playlist 实测没有，`EXT-X-MEDIA-SEQUENCE` 在增长）。

### 3.2 限速链路（200 KB/s，故意让播放器跟不上）

```
[startup] 出画=2228ms · … file-loaded=2141.0 vo-configured=2227.7
state 序列：idle → preparing → playing        ← **0 次 failed**
buffering 翻转 17 次                            ← 有缓冲提示
[status]   6.195 state=playing t=1.32/2.50  progress=0.531 buffering=true
[status]  24.694 state=playing t=12.03/17.34 progress=0.694 buffering=false
[status]  36.969 state=playing t=18.03/30.66 progress=0.588 buffering=true
[status]  49.154 state=playing t=32.03/42.11 progress=0.761 buffering=false
```

限速下 `t` 的推进会**慢于墙钟**（49 s 的墙钟只走了 32 s 的媒体）—— 这**不是**"落后量的漂移"，
而是"抓不快 ⇒ 边走边丢"。§五 有它的直接证据。

---

## 四、三个新认识（都是从这一轮的数据里读出来的）

### 4.1 `duration` 在 HLS 直播下 = **滑动窗口的末端**，不是总时长

`t=40.74/42.16`、`38.62/40.05`、`12.03/21.62` —— **分子分母一起涨**，且分母永远比分子大一小段。
对照 `docs/14` 记的 RTSP 直播（`duration` 语义与 VOD 不同）：**HLS 直播是同一族的第三种形态** ——
RTSP 的 `duration` 是"未知/0"，HLS 直播的是"**当前已加载到的末端**"。

### 4.2 ⇒ **直播下进度百分比没有意义**（`progress` 恒在 0.9 以上）

实测 `progress` 在 **0.53 – 0.96** 之间抖动（两轮 max 分别是 0.966 / 0.959）。
原因就是 4.1：分母在动，而且它总比分子大不到十几秒 ⇒ 比值天然贴着 1。

⚠️ **这是产品行为，不是缺陷**，但**UI 上是个坑**：进度条的含义在直播下与点播不同。
它属"要不要为直播换一套时间轴呈现"的产品决策 ⇒ 见 §七（**未定，不擅自动**）。

### 4.3 我们的低延迟默认值（`cache-secs=1`）**决定了**"跟不上时丢内容"

`P6-T3` 把 `cache-secs` 从默认 10 s 压到 1 s 是为了压落后量。它的直接后果在这里显形：
缓存小 ⇒ 网络跟不上时**优先保直播边缘、牺牲连续性**（§五的跳跃就是它）。

这是**直播下正确的取舍**（直播的价值在"现在"），但它与点播的直觉相反 ——
**点播会宁可缓冲也不跳**。两个语义共用一个 `cache-secs=1`，这是**已知的、可接受的**代价，
写在这里是为了将来有人问"为什么直播会跳帧"时能一眼找到原因。

---

## 五、票面点名的失败形态：**没有发生**，以及为什么

**原假设**：滑动窗口（`hls_flags delete_segments`）下，播放器一旦落后于窗口，
它要的分片**已经不存在了** ⇒ 症状是中途 `failed` 或卡死。

**实测（限速 200 KB/s，720p 档需要 ~362 KB/s ⇒ 必然跟不上）**：

| 观察 | 结果 |
| --- | --- |
| 客户端 `failed` | **0 次** |
| 服务端 **404** | **0 次** |
| 实际抓到的分片序列 | `105 → 106 → 107 → **109** → 110 → **113** → **115** → **118** → **120** → **122** → …` |
| 表现 | `state` 始终 `playing`，`buffering` 频繁翻转，`t` 慢于墙钟 |

**⇒ 播放器只向前要数据。** 它不会回头去取一个已被删除的分片（那样才会 404 / 失败），
而是**跳到当前清单里的新分片**、把中间那些丢掉。

**这条结论的价值**：它把"HLS 直播的窗口滑动"从"潜在崩溃点"降级为"**已知的丢帧行为**" ——
而这正是直播该有的取舍（`P6-T3` 的 `cache-secs=1` 让它更明显，§4.3）。
代价是**画面不连续**，收益是**不落后**。

---

## 六、方法与环境（可复现）

```bash
# 三档 HLS 直播（滑动窗口 6×2 s = 12 s；-re 实时；-g 48 ⇒ 每 2 s 一个关键帧）
mkdir -p /tmp/hls-live-ladder && cd /tmp/hls-live-ladder
ffmpeg -re -stream_loop -1 -i /tmp/vidprobe2/sintel_trailer-720p.mp4 \
  -filter_complex "[0:v]split=3[v1][v2][v3];[v1]scale=1280:720[v1o];[v2]scale=854:480[v2o];[v3]scale=426:240[v3o];[0:a]asplit=3[a1][a2][a3]" \
  -map "[v1o]" -map "[v2o]" -map "[v3o]" -map "[a1]" -map "[a2]" -map "[a3]" \
  -c:v libx264 -preset veryfast -g 48 -keyint_min 48 -sc_threshold 0 \
  -b:v:0 2500k -b:v:1 1200k -b:v:2 400k -c:a aac -b:a 128k \
  -f hls -hls_time 2 -hls_list_size 6 -hls_flags delete_segments \
  -hls_segment_filename "/tmp/hls-live-ladder/v%v/seg%03d.ts" \
  -master_pl_name master.m3u8 \
  -var_stream_map "v:0,a:0 v:1,a:1 v:2,a:2" "/tmp/hls-live-ladder/v%v/index.m3u8"
# ⚠️ 目录形状要与 P0/P5 那套一致（`/tmp/<root>/v%v/index.m3u8`）：多套一层子目录时
#    `-master_pl_name` 不落地，而**不报错** —— 症状是"找不到 master"（像产品问题）。

# 服务器（正常 / 限速各一台；HLS 的 m3u8 与 .ts 都要 Range）
python3 Tools/serve-range.py --port 8770 --root /tmp/hls-live-ladder --host 0.0.0.0
python3 Tools/serve-range.py --port 8771 --root /tmp/hls-live-ladder --host 0.0.0.0 --throttle 200000

# 真机（⚠️ 地址要问**路由表**，不要写死 en0 —— 见 P-076）
MACIP=$(ipconfig getifaddr "$(route -n get default | awk '/interface:/{print $2}')")
xcrun devicectl device process launch --device <UDID> --console --terminate-existing \
  com.playerstack.demo -- -directURL "http://$MACIP:8770/master.m3u8" -exerciseTracks
```

**判"是直播"的判据在服务端**（§3.1 的 ⚠️）：playlist 被反复请求 + 没有 `#EXT-X-ENDLIST`。

---

## 七、仍未覆盖 / 未定

| 项 | 说明 |
| --- | --- |
| **直播下的进度呈现** | §4.2：`progress` 恒在 0.9+，进度条语义在直播下不成立。**要不要为直播换一套时间轴**（比如只显示"LIVE"、或显示落后量）是**产品决策** ⇒ 未定，不擅自动 |
| HLS 直播的**低延迟**（LL-HLS / `#EXT-X-PART`） | 本轮是常规 HLS（2 s 分片 ⇒ 天然 ~6–8 s 落后）。**LL-HLS 未测**，需要一个支持 partial segment 的源 |
| 直播的**音轨跟随切档** | `P5-T5` 已答 VOD 下"不跟随"。直播下**未单独复验**（本轮三档音频同一参数 ⇒ 不可判，与 `docs/14` §8 那次的教训相同） |
| 真机 720p 档在**限速**下的画质/丢帧观感 | 本轮只记录"跳跃"这一行为，**没有**量"丢了多少比例"（需要逐帧对齐，属另一票） |

---

## 八、一句话

**HLS 直播这一格现在是绿的：能起播（出画 492 ms）、能枚举并切换三档、42 秒不失败；
`duration` 是滑动窗口的末端（所以直播下进度百分比没有意义，待产品决策）；
而票面担心的"落后于窗口 ⇒ 分片已删 ⇒ 崩"**没有发生** ——
播放器只向前要数据，跟不上就丢内容追直播边缘（0 次 404），
那是直播该有的取舍，也是 `P6-T3` 的 `cache-secs=1` 在带宽不足时的显形。**

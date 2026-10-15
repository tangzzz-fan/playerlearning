# 14 · `P5-T5`（可切清晰度）调研 —— HLS 多码率在 mpv 里到底长什么样

> 这张票卡在一个**必须先答的设计前提**上：HLS 的多个码率档，在 mpv 里是
> **"若干条 video track"**（⇒ 切清晰度 = 切轨道，轻量），
> 还是 **"只暴露被选中的那一条"**（⇒ 换档 = 重新加载，重）。
>
> 两者实现与 UI **完全不同**，所以不能照文档猜。本轮用真源实测把它钉死了。
>
> 报告日期 2026-10-15 · 环境 `ffmpeg 9.0.2` / `mediamtx v1.21.2`（**一次性环境，不入仓库**）

---

## 结论（先说）

**HLS 多码率在 mpv 里就是 `N` 条普通的 `type=video` 轨道，用 `vid` 切换。**

⇒ `P5-T5` 是**「视频轨道枚举 + `vid` 切换」**，**不是**「换档 = 重新加载」。
⇒ 不需要重建 demuxer、不需要重载 URL、不需要新的清晰度抽象 ——
**复用既有的 track-list 读取路径**，把 `type == "sub"` 的过滤条件泛化即可。

但它是**跨三层**的活（不是纯 UI）：`PlayerCore` 轨道模型 → 内核回读 + `vid` 命令 → UI 菜单。

---

## 一、证据：三档 HLS 造出来喂给 mpv，`track-list` 原样 dump

### 1.1 造源（本地三档阶梯，52 秒素材）

```bash
# 720p / 480p / 240p，各带一条 AAC
ffmpeg -y -i /tmp/vidprobe2/sintel_trailer-720p.mp4 \
  -filter_complex "[0:v]split=3[v1][v2][v3]; \
    [v1]scale=w=1280:h=720[v1out];[v2]scale=w=854:h=480[v2out];[v3]scale=w=426:h=240[v3out]" \
  -map "[v1out]" -map "[v2out]" -map "[v3out]" -map 0:a -map 0:a -map 0:a \
  -c:v:0 libx264 -preset veryfast -b:v:0 2500k \
  -c:v:1 libx264 -preset veryfast -b:v:1 1200k \
  -c:v:2 libx264 -preset veryfast -b:v:2 400k -c:a aac -b:a 128k \
  -f hls -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename "/tmp/hls-ladder/v%v/seg%03d.ts" \
  -master_pl_name master.m3u8 \
  -var_stream_map "v:0,a:0 v:1,a:1 v:2,a:2" "/tmp/hls-ladder/v%v/index.m3u8"
```

> ⚠️ **`%v` 不是 `%d`**：`%v` 是**档位号**，`%d` 是**分片号**。写错报
> `More than 1 variant streams are present, %v is expected either in the filename or in the sub-directory name`
> —— 它只说"你该用 `%v`"，不告诉你"你把哪个变量用错了"。

master 清单（ffmpeg 自己算出的带宽）：

```
#EXT-X-STREAM-INF:BANDWIDTH=4149862,AVERAGE-BANDWIDTH=2284533,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
v0/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2163405,AVERAGE-BANDWIDTH=1176792,RESOLUTION=854x480,CODECS="avc1.64001e,mp4a.40.2"
v1/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=909999,AVERAGE-BANDWIDTH=507418,RESOLUTION=426x240,CODECS="avc1.640015,mp4a.40.2"
v2/index.m3u8
```

投递：`Tools/serve-range.py --host 0.0.0.0 --root /tmp/hls-ladder`（模拟器可直连宿主回环）。

### 1.2 实测输出（内核 `state=playing` 时 dump 的原始行）

```
=== PROBE HLS state=playing t=5.416666666666667 ===
track-list/count = 6
[0] type=video id=1 codec=h264 lang=- title=- selected=true  demux=1280x720 ch=-1
[1] type=audio id=1 codec=aac  lang=- title=- selected=true  demux=-1x-1     ch=2
[2] type=video id=2 codec=h264 lang=- title=- selected=false demux=854x480  ch=-1
[3] type=audio id=2 codec=aac  lang=- title=- selected=false demux=-1x-1     ch=2
[4] type=video id=3 codec=h264 lang=- title=- selected=false demux=426x240  ch=-1
[5] type=audio id=3 codec=aac  lang=- title=- selected=false demux=-1x-1     ch=2
vid = 1
current-tracks/video/id = 1
video-params/w = 1280
video-params/h = 720
video-params/pixelformat = yuv420p
hls-bitrate = -99
```

**读法**：
- **三个 variant 全部展开成轨道**：`[0]/[2]/[4]` 是三条 video，`demux-w/h` 就是各自的分辨率
  ⇒ 分辨率**天然可以当档位标签**，不用另造；
- **音轨也被拆成三条**（`[1]/[3]/[5]`），与视频档一一对应 —— 这是 lavf 把每个 variant 当独立
  program 的副产物（见 §四 遗留问题）；
- `vid = 1` / `current-tracks/video/id = 1` ⇒ **切换的抓手就是 `vid`**；
- **`hls-bitrate` 读不到（`-99`）** ⇒ ❗别把"档位带宽"押在这个属性上，
  档位信息要取 `demux-w/h`（或自己去解 master 清单）。

### 1.3 探针纪律（沿用 `P-045`）

探针**放进已有的 `@Suite(.serialized)`**（`MPVKernelTests`），**不新开第二个套件** ——
`.serialized` 只管套件内部，两个都用真 mpv 的套件**仍然并行**。
用完**即撤**（`P-033`：夹具必须确定性，这条依赖外部 HTTP 服务，不能进正式套件）。
本轮的探针 + 一个 `#if DEBUG` 的 dump 方法已撤除，工作树无残留。

---

## 二、判定：为什么是"轨道切换"而不是"换档重载"

| 判据 | 实测 | 含义 |
| --- | --- | --- |
| 档位是否各自成轨 | ✅ `track-list/count = 6`，三条 video | **不用重载**：demuxer 已经同时认识三档 |
| 有没有"选中"概念 | ✅ `selected=true/false` 互斥 | 与字幕轨**同一套语义**，可直接复用 |
| 切换抓手 | `vid`（当前 1） | 与 `sid` 对称 —— 内核已有 `sid` 通道，加一条 `vid` 即可 |
| 档位标签从哪来 | `demux-w` / `demux-h` | 不需要解析 m3u8，也不需要 `hls-bitrate` |

⇒ **票面里那句"大概率是视频轨道枚举 + `vid` 切换"被证实**，且
**"实现上大概率"这个措辞可以去掉**。

---

## 三、`P5-T5` 的落地范围（三层，都不是纯 UI）

| 层 | 要动什么 | 现状 |
| --- | --- | --- |
| `PlayerCore` | 轨道模型：现在有 `SubtitleState/SubtitleTrack`，**没有视频轨对应物** | 新增（可参照字幕轨的形状，但**只读**：视频轨不涉及外挂/延迟） |
| `MPV` 内核 | `readSubtitleTracks` 里那句 `type == "sub"` 过滤 ⇒ 泛化；新增 `selectVideoTrack(id:)` 写 `vid` | 现**只有** `selectSubtitleTrack`（`P-034`：跨层改协议后**必须真编译 MPV 包**） |
| `PlayerUI` | 清晰度菜单（与字幕菜单同构） | 菜单骨架已有（字幕菜单），可复用 |
| `Demo` | 真机取证入口（列出可选档位 + 切换 + 回读分辨率） | `-traceUpdates` 的 `[status]` 行可扩 |

**设计上要明确的取舍**（留给实现时定，先记）：
- 档位**按分辨率去重**还是**按 `id` 全列**？（同一分辨率不同码率会很常见 ⇒ 去重后怎么选）
- **2D/3D 或非 HLS 源**（单码率 mp4）时，这个菜单应是**隐藏**还是**置灰**
  （单码率只有 1 条 video track ⇒ 菜单里只有一项，显示出来是噪音）

---

## 四、顺带拿到的：`P6-T1`（RTSP 直播）在**真机**上的第一份证据

同一批环境还做成了直播链路，**证明播放端已就绪**：

```
推流：ffmpeg -re -stream_loop -1 -i sintel_trailer-720p.mp4 -c copy \
        -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
服务：mediamtx（配置 `paths: all_others:`）
真机：-directURL rtsp://192.168.2.217:8554/live
```

mediamtx 侧确认出版：

```
INF [path live] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
INF [RTSP] [session 896b6692] is publishing to path 'live'
```

真机侧（每秒一条状态行）：

```
[direct] url=rtsp://192.168.2.217:8554/live
[status]  0.050 state=idle
[status]  1.068 state=preparing
[status]  2.134 state=playing t=0.00/2.09
[status]  5.313 state=playing t=3.75/5.18  buffering=true    ← 起播阶段一次性停顿
[status]  8.365 state=playing t=4.54/8.34  buffering=false   ← 自行恢复，无需操作
[status] 16.445 state=playing t=12.67/16.45                  ← 时间持续推进
```

**结论**：`rtsp://` **不需要改一行代码**（`-directURL` 原样交给内核），
`preparing → playing` ≈ 1 秒，起播有一次缓冲后自恢复。

### ❗ 直播暴露的一个**语义差异**（`P5-T5` / `P6` 都要用）

看分子分母：`t=12.67/16.45` —— **分母在持续增长**（`2.09 → 3.18 → … → 16.45`）。
也就是说直播下 `duration` 是**"已推流到的位置"**，不是总时长
⇒ 沿用 VOD 的 `progress = t/duration` 会让进度条**一直在 0.5~0.77 之间抖**
（实测抖动区间）。

⇒ **直播的进度表示必须与 VOD 分开**（进度条改为"已播/实时"或直接隐藏）。
这是 `P6-T2`/`P6-T3` 的输入，**不是缺陷**（`duration` 就是这个语义）。

### 遗留问题（**未验，别当成已知**）

1. **切换视频档之后，音轨会不会跟着切？** 每个 variant 的音轨是**独立一条**，
   切 `vid` 未必带动 `aid` ⇒ 可能"换了画面、声音还是旧档的"。
   **必须实测**（这是 `P5-T5` 实现时的第一条验证）。
2. **直播下 `track-list` 是否也长这样？** 本轮的多码率实测是 **VOD（HLS)，
   不是直播**。直播（RTSP/低延迟 HLS）的轨道清单**未测**。

---

## 四点五、真机 RTSP 连续跑 401 秒的观察（**含两个未解释项**）

先说结论：**没有崩**（`state=failed` **0 次**），但**进程被挂起过 214.7 秒** ——
后者比"崩不崩"更值得记。

### 数据（`[status]` 每秒一行，共 401 秒到人工 `terminate` 为止）

| 项 | 值 |
| --- | --- |
| 总时长 | **401 s**（6 分 41 秒） |
| `state=failed` | **0 次** |
| `buffering=true` | **3 次**（都在起播阶段，之后不再触发） |
| 内存 | 起播涨到 **155.9 MB 后持平**（第 400 秒仍是 155.9） |

### 但采样**空了 214.7 秒** —— 而且**播放也停了**

```
断点前  172.1 s   state=playing  t=169.08/172.05
断点后  386.8 s   state=playing  t=169.75/172.73
```

**墙钟走了 214.7 秒，播放位置只走了 0.67 秒** ⇒ **不是日志通道断，是整个 App（含 mpv）被挂起**
（判据见 `PITFALLS` 的 `P-063`：要用**业务计数值**分"通道断"与"对象停"）。

**服务端一侧独立印证**（真机 = `192.168.2.253`）：

```
23:07:34 WAR [RTSP] [session 72ee3138] reader is too slow, discarding 14 frames
23:07:35 INF [RTSP] [conn 192.168.2.253:59908] closed: terminated
23:07:35 INF [RTSP] [session 72ee3138] destroyed: write tcp 192.168.2.217:8554->192.168.2.253:59908: i/o timeout
```

客户端 172.1 s（≈23:07:20）→ 服务端 23:07:34 判"读得太慢"，
**差 14 秒 ≈ TCP 缓冲耗尽的时间**，两侧对得上。

### ❗ 未解释项 1：**挂起的根因没验证**

最像是 **iOS 后台 / 锁屏挂起**（Demo 未配 `UIBackgroundModes: audio`）——
**但这只是候选解释**：本轮**没有取到任何屏幕状态或进程状态的直接证据**，
"无人操作约 3 分钟后设备息屏"与"进程被挂起"之间**只有时间上的巧合**。

⇒ **这是只有人能做的验证**：把设备**自动锁屏关掉**（或保持屏幕常亮）再跑一次，
看那 214 秒还断不断。
**在验证之前，相关结论只能写成"观察到挂起"，不能写成"因为息屏"。**

### ❗ 未解释项 2：恢复后 `t` 出现一次**倒退**

`391.9 s` 那一行是 `t=86.12/175.42`，而前一行是 `t=173.50/175.42`。
直播下这属于"重定位"，但**触发条件不明**（`-stream_loop -1` 造成的推流时间戳回绕？
mpv 的落后追赶？）。⚠️ **本轮只有一次观测，不构成结论。**

---

## 五、环境怎么复现（**一次性动作，不入仓库、不算项目机器**）

```bash
# 1) 环境（已由董事长本机安装）
brew install mediamtx ffmpeg

# 2) 多码率 HLS 源
ffmpeg -i <源> … -f hls -var_stream_map … /tmp/hls-ladder/v%v/index.m3u8   # 见 §1.1
# 3) 投递（⚠️ 必须 --host 0.0.0.0 才够得着真机；模拟器用 127.0.0.1 即可）
python3 Tools/serve-range.py --port 8765 --root /tmp/hls-ladder --host 0.0.0.0

# 4) 直播源
mediamtx /tmp/mediamtx.yml            # 内容：paths:\n  all_others:
ffmpeg -re -stream_loop -1 -i <源> -c copy -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
```

**License 口径不变**：`ffmpeg` / `mediamtx` **只作"造源 / 验证"工具** ——
不进产物、不随仓库分发（`docs/02` 的分发口径不受影响）。

---

## 六、结论一句话

**`P5-T5` 的设计前提已答：HLS 多码率 = `N` 条 video track，切清晰度 = 设 `vid`。**
**`P6-T1` 的播放端已在真机证通（RTSP 原样可播），且顺带发现直播的 `duration` 语义与 VOD 不同。**

本轮的三个环境坑（代理劫持回环 · mediamtx 空配置 · `nohup` 守护进程不活）已记入
[`PITFALLS.md`](PITFALLS.md) 的 `P-059` / `P-060` / `P-061`。

---

## 七、后记：`P5-T5` 已按本报告的结论落地（2026-10-15）

本报告回答的是**"该做成什么样"**；**实现与验证记录在 [`docs/03`](03-路线图.md) 的 `P5-T5` 📌 里**，此处只留索引：

- **`PlayerCore`**：`VideoTrack` + `PlayerVideoTrackState`（只读、清单 + 选中项 + `hasAlternatives`）
- **跨层**：事件 / 快照 / 更新 / 协议 **四处贯穿**（协议新增 `selectVideoTrack(id: Int64)`）
- **`MPV` 内核**：`track-list` 的 `type` 过滤**泛化**（字幕轨与视频轨共用一条），新增 `vid` 写 + 回读
- **`PlayerUI`**：清晰度菜单，**`hasAlternatives` 为假时整条隐藏**（§三 那个取舍的落地）
- **`Demo`**：`-exerciseTracks` 取证入口（用法见 README ⑥d）

**§四 的两个遗留问题，交付后仍然成立**：
① **切 `vid` 会不会带动音轨** —— **仍未验**。`-exerciseTracks` 的日志末尾会显式打印这条边界，
   免得取证记录被读成"音轨也验过了"。
② **直播下的轨道清单** —— **仍未测**（本报告的多档实测是 VOD）。

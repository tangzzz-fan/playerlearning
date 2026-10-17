# playerlearning

做一个**自己的 iOS 优先 / macOS 跟进播放器**：libmpv 单内核，本地文件 + 网络点播 + 直播全都要，能播系统播放器播不了的格式（mkv / ASS 特效字幕 / 各种编码）。

**当前状态**：**`P7-T3` 帧的出口与下游已交付**（render API 上屏 + 吞吐实测 ⇒ 不上 GPU 桥，见 [`docs/25`](docs/25-RenderAPI上屏与吞吐.md)） · **Phase 0–5 均已交付** · **`M3` 达成**（真机校准 ✅ · 长跑经拍板取消 · 字幕菜单真机手势 ✅） · **Phase 7（macOS）`P7-T1` 完成**（`G7` 达成）。
**`G5` 三项已判定**（真机**可控弱网**：不崩 / 有缓冲提示 / 恢复后自动继续 —— [`docs/12`](docs/12-P5验证报告.md)）；
§二 口径里的「可切清晰度」（`P5-T5`）**设计前提已答**（= 视频轨道切换，见 [`docs/14`](docs/14-P5-T5-HLS多码率调研.md)），
但**尚未实现** ⇒ **`Phase 5` 仍不宣告关闭**。
**直播源环境已补**（`mediamtx` + `ffmpeg`，一次性动作、不入仓库）⇒ **`P6-T1` 的播放端已在真机证通**（RTSP 真机 `playing`，见 [`docs/14`](docs/14-P5-T5-HLS多码率调研.md)）。
真机已跑通 —— 两套环境各一台：家里 iPhone 16 Pro（`UKXWZ3FS84`）· 本机 Tang的iPhone（`3GMJYX32U9`），口径见 §⑦。

| 里程碑 | 状态 |
| --- | --- |
| M0 路线成立 | ✅ 自建动态 LGPL-2.1 libmpv 产物，模拟器与真机（iPhone 16 Pro）双通出画面 |
| M1 地基可测 | ✅ 内核边界已立（`PlayerKernelProtocol` / 注册表 / `FakeKernel` / 状态机 / 时间模型）· `PlayerCore` 零 UI 依赖 |
| M2 能看片 | ✅ 出画 + 出声 + `seek` 精确 + 播完报 `.finished`（[`docs/10`](docs/10-P2验证报告.md)） |
| M3 能顺手用 | ✅ **达成**：① 真机校准 ✅（真机出声出画 ≈0.20 s；模拟器那个 1.97 s 是 MoltenVK 管线编译的代价，**与音轨无关，真机未复现**）② 长跑**经董事长拍板取消**（不做长时任务；已跑的 ≈3 min/18 轮如实保留）③ 字幕菜单真机手势**经董事长实测确认可用** |
| 端到端素材 | **Sintel trailer 720p（CC BY · 1280×720 · 48 kHz 立体声 · 52 s）**运行时下载，另有 W3C 镜像与 MDN `flower` 两级备用；离线退回本地生成；**用哪一个是哪个会打印出来** |

**验收标准就一条：项目能正确运行，`swift test` 全绿**（命令见下）。

## 文档索引

| 文档 | 内容 | 何时读 |
| --- | --- | --- |
| [`docs/01-KSPlayer-设计思想与整体评估.md`](docs/01-KSPlayer-设计思想与整体评估.md) | 设计思想 8 条 + 长处 9 条 + 短处 15 条 + submodule 考证 + 整体判断 + §2.4 授权传导源 | **先读这份**，建立全局认识 |
| [`docs/02-自建播放器决策记录.md`](docs/02-自建播放器决策记录.md) | 11 条决策、逐条理由与被否方案、**§三 分发口径**、显式放弃清单、施工硬约束 10 条 | 动手前读，作为施工约束 |
| [`docs/03-路线图.md`](docs/03-路线图.md) | Phase 0–7 拆解、判定门 G0–G7、横切事项、里程碑定义、未定项与决策回访点 | 按 ticket 推进 |
| [`docs/04-开工前准备清单.md`](docs/04-开工前准备清单.md) | 环境体检实测、P0 ticket 表、决策项 D1–D5、风险登记 R1–R5 | 开工前必读 |
| [`docs/05-libmpv产物实测报告.md`](docs/05-libmpv产物实测报告.md) | `P0-T4`：上游产物的许可实测（发现其落在 LGPLv3） | 需要许可结论时 |
| [`docs/06-P0-T5a技术验证报告.md`](docs/06-P0-T5a技术验证报告.md) | `P0-T5a`：`wid` + MoltenVK 技术验证（模拟器 + 真机双通） | `P2` 接入前 |
| [`docs/07-P0-T5b验证报告.md`](docs/07-P0-T5b验证报告.md) | `P0-T5b`：**自建动态 LGPL-2.1 产物**（`G0` 达成）· 许可证据链 · 端到端 | 需要产物规格时 |
| [`docs/08-P1验证报告.md`](docs/08-P1验证报告.md) | `P1`：骨架与内核抽象 · **`G1` 达成** · 交付物清单 · 集成测试抓到的缺陷 | 进 Phase 2 前 |
| [`docs/09-P2就绪度分析与票面修正.md`](docs/09-P2就绪度分析与票面修正.md) | `P2` 开工前复核：**票面缺装配层的证据** · `MPVKernel` 六项缺陷 · 两处拍板决策 · `G2` 口径细化 | 需要 `P2` 决策依据时 |
| [`docs/12-P5验证报告.md`](docs/12-P5验证报告.md) | `P5`：真机局域网链路 · **`G5` 三项判定**（可控弱网 45 KB/s）· 请求头端到端证据 · 未覆盖项 | 需要网络点播证据时 |
| [`docs/13-P6-T0调研.md`](docs/13-P6-T0调研.md) | `P6-T0`：**产物已带 RTSP/RTMP**（运行时探针证据）· 无参考实现可抄 · 低延迟候选选项 · **缺什么才能验** | 进 `Phase 6` 前 |
| [`docs/14-P5-T5-HLS多码率调研.md`](docs/14-P5-T5-HLS多码率调研.md) | `P5-T5` 设计前提（**HLS 多码率 = N 条 video track，切清晰度 = 设 `vid`**）· 三档源造法 · **RTSP 真机打通证据** · 直播 `duration` 语义差异 | 做可切清晰度 / 直播前 |
| [`docs/15-P6-T2-延迟指标.md`](docs/15-P6-T2-延迟指标.md) | `P6-T2`：**延迟怎么量**（起播 / 落后量两个指标）· 方法 · 基线。⚠️ §四 起播那条口径已由 `docs/17` 修正（文内已加标注） | 要看延迟数字时 |
| [`docs/16-P6-T3-低延迟参数.md`](docs/16-P6-T3-低延迟参数.md) | `P6-T3`：低延迟默认值落地（`cache-secs=1` + `cache-pause-initial=no`）· **三段切分归因** · 代价量化 | 要改网络/缓存参数时 |
| [`docs/17-P6-T4-起播延迟.md`](docs/17-P6-T4-起播延迟.md) | `P6-T4`：**起播分段归因**（三段各由谁决定）· 两处修复 · 更正 `docs/15`/`docs/16`/`P-045` 三处既有记载 | 起播慢 / 要动探测窗口时 |
| [`docs/18-P0-T5c-HTTPS行为验证.md`](docs/18-P0-T5c-HTTPS行为验证.md) | `P0-T5c`：**HTTPS 行为验证** —— 结论：**这个产物的 HTTPS 只加密、不校验证书**（真机+模拟器都接受不受信任/名字不匹配的证书）· 根因 · 三条修复路径 | **用 HTTPS 前必读** |
| [`docs/19-P6-T5-HLS直播源.md`](docs/19-P6-T5-HLS直播源.md) | `P6-T5`：**HLS 直播源** —— 出画 492 ms · 三档直播枚举与切档正常 · **直播下 `duration` = 滑窗末端**（进度百分比无意义）· **落后于窗口不会崩，是丢内容追边缘** | 做直播 / HLS 相关改动前 |
| [`docs/20-P0-T5d-HTTPS校验修复.md`](docs/20-P0-T5d-HTTPS校验修复.md) | `P0-T5d`：**HTTPS 校验修复** —— **一行 `tls-verify=yes`** + 两处配方修复（产物里"不在配方中"的改动 · 嵌套补丁静默失败） | 用 HTTPS / 重构建产物前 |
| [`docs/23-上架准备清单.md`](docs/23-上架准备清单.md) | 上架物料与合规项（图标 / 隐私清单 / 导出配置），以及**只有人能做的**那 8 项 | 要传 App Store 前 |
| [`docs/24-RenderAPI取帧.md`](docs/24-RenderAPI取帧.md) | `P7-T3` 前半：**帧能不能取到手上**（`MPV_RENDER_API_TYPE_SW` 实测出帧）· 软件后端的代价 | 要动渲染结构前 |
| [`docs/25-RenderAPI上屏与吞吐.md`](docs/25-RenderAPI上屏与吞吐.md) | `P7-T3` 后半：**帧上屏**（`CVPixelBuffer`→Metal→图层）· **吞吐实测与"不上 GPU 桥"的结论** · 帧下游第一刀（效果 + 自绘叠加层） | 要改渲染 / 做字幕自绘 / 评估全景 3D 前 |
| [`docs/26-真机复验-render上屏.md`](docs/26-真机复验-render上屏.md) | **iPhone 16 Pro 上 render API 上屏打通** · 三层读数取证法 · 真机吞吐（4K 按上屏 11.5 ms）· `P-094` 那个坑的完整追查 | 要改渲染 / 要判断"真机行不行"前 |
| [`docs/27-自绘字幕数据源.md`](docs/27-自绘字幕数据源.md) | **自绘字幕通了**：文本来自 `SubtitleTimeline`、按 `time-pos` 对表 · 三张不同时刻的截图作判据 · 与 mpv 那条不能同开 | 要做字幕排版 / 动效 / 字幕检索前 |
| [`compliance/README.md`](compliance/README.md) | **LGPL 交付物总入口**：对应源码 + 许可文本 + 可替换性说明 + 修改声明（四件齐），每条事实都带可核对命令 | 上架前 / 有人来问许可时 |
| [`docs/PITFALLS.md`](docs/PITFALLS.md) | **踩坑日志**（现象 → 根因 → 处置 → 防再犯），**编号只增不删**、条数以文件自身为准（`P-085`：别把总数抄到这里），末段为**跨项目移植区**（来源 Marquee / HabitLoop / meta 待回流清单） | **动手前扫一遍**，能省掉重复排查 |

## 工程结构

```
Package.swift            ← 根包 PlayerStack：PlayerCore / PlayerUI 双 target（iOS 17 / macOS 14 / Swift 6）
Sources/
├── PlayerCore/          ← 内核边界与状态机（⛔ 禁止 import SwiftUI / UIKit / AppKit）
└── PlayerUI/            ← SwiftUI 视图层
Tests/
├── PlayerCoreTests/     ← 纯逻辑单测 + 集成测试（跑在 macOS）
└── PlayerUITests/       ← UI 侧的**纯逻辑**模型 + 视图模型（同样跑在 macOS，不起模拟器）
Tools/                   ← serve-range.py（Range/弱网取证服务器）· stage-libmpv.sh
MPV/                     ← ⚠️ 独立包 PlayerMPV：libmpv 适配器（只在 iOS 上编译，见下）
Demo/                    ← app shell（project.yml → xcodegen 生成，产物不入仓）
├── UITests/             ← UI 自动化（**刻意用 XCTest**，见下）
└── Sources/
```

**验收标准就一条：项目能正确运行，`swift test` 全绿。**

```bash
# ① 根包（纯逻辑，日常就是它）
swift build && swift test              # ⚠️ 受限 shell 需加 --disable-sandbox（见下）
#   ⚠️ 输出里有**两份** `Test run with …` 汇总（`PlayerCoreTests` + `PlayerUITests`，各自一个进程）
#      ⇒ 用 `| tail` 收口只会看到最后一份。**报"全绿"时几份数字都要给**（P-065）。

# ② MPV 包（libmpv 适配器，只编译 iOS）
./Tools/stage-libmpv.sh                # 产物 104 MB 且 gitignored ⇒ 换设备后**必须先跑一次**
cd MPV && xcodebuild -scheme PlayerMPV -destination 'platform=iOS Simulator' build

# ③ Demo app（手动跑起来看效果）
cd Demo && xcodegen generate           # 新增源文件后必须重跑（P-030）；.xcodeproj 不入 git
xcodebuild -project PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
  -destination 'platform=iOS Simulator' build

# ③b **UI 自动化**（`Demo/UITests`，4 条：控制层 / 点画面切换 / 全屏 / **键盘 F**）
#    不需要任何媒体或网络 ⇒ 确定性夹具（P-033）。跑在模拟器上，**不需要屏幕录制权限**。
bash ~/.workbuddy/skills/ios-build-test/scripts/ios-run.sh test \
  --project PlayerStackDemo.xcodeproj --scheme PlayerStackDemo --sim <udid> \
  --result-bundle /tmp/pl-ui.xcresult
#   ⇒ ** TEST SUCCEEDED ** · Executed 4 test（每条都把 [ui] 事实打到 stderr，日志里可读）
#   导出截图（XCUIScreen 截图挂在报告里，keepAlways ⇒ 成功也留）：
xcrun xcresulttool export attachments --path /tmp/pl-ui.xcresult --output-path /tmp/pl-ui-shots
#   ⚠️ UI 自动化**刻意用 XCTest**（`XCUIApplication` 在 Swift Testing 里没有等价能力）——
#      工具边界，不是"忘了迁移"（docs/03 L457–458 · docs/11 L41–45）
#   ⚠️ 它证的是**手指/键盘真的落到控件上**；链路与内核语义由 ④/⑤ 那三个入口证（互补）

# ④ 播放控制回归（`-exerciseControls` 跑「加载 → 播 → 停 → 再播」，逐拍打点）
xcrun simctl launch --console <udid> com.playerstack.demo -exerciseControls -traceUpdates
#   ⇒ [exercise] loaded→playing / stopped→idle / replayed→playing
#   ⚠️ 它证明"控制链路 + 内核语义"是通的（真 libmpv 上）；**不能**证明手指有没有点到按钮上 ——
#      那一段由 ③b 的 UI 自动化证。**两者互补，不互相替代**（2026-10-16 UI 自动化已恢复）。

# ⑤ 长跑稳定性（每轮走完 load→play→seek→pause→play→stop，逐轮打点内存）
xcrun simctl launch --console <udid> com.playerstack.demo -soakRounds 30
#   ⇒ [soak] round N/30 · t=… · footprint=… MB · state=idle
#   180 轮 ≈ 30 min（`M3` 门槛那个量级）。判据：**单调线性 = 泄漏；阶梯后持平 = 预热**。

# ⑤b **播完 → 再点播放**（`-exerciseFinish`，走与按钮完全相同的 action）
xcrun devicectl device process launch --device <真机 UDID> --console \
  --terminate-existing com.playerstack.demo -- -exerciseFinish -traceUpdates
#   ⇒ [finish] 播到末尾 → state/位置/进度 · 等 2 秒后 → … · 点播放 3 秒后 → …
#   ⚠️ 它证明的是**按钮按下之后**那段。重播必须走 `finished → preparing → readyToPlay → playing`；
#      界面停在 finished 就说明那条边没报（见 P-053）。

# ⑥ 网络点播验证（**必须用支持 Range 的服务器**，见 P-052）
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2     # 一个终端
xcrun simctl launch --console <udid> com.playerstack.demo \
  -directURL http://127.0.0.1:8765/sintel_trailer-720p.mp4 -traceUpdates
#   ⚠️ 别用 `python -m http.server`：它不支持 Range ⇒ mp4 会"14 毫秒就播完"，
#      那是**环境缺口**而不是产品缺陷。`-traceUpdates` 会同时打开**内核自己的日志**。

# ⑥b 请求头注入验证（`P5-T4`，验证自定义 HTTP 头能正确发送）
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2 --echo-headers  # 服务器回显请求头
xcrun simctl launch --console <udid> com.playerstack.demo \
  -directURL http://127.0.0.1:8765/sintel_trailer-720p.mp4 \
  -headers "X-Player-Test: yes,User-Agent: CustomUA/2.0" -traceUpdates
#   查服务器日志（stderr）看到 `X-Player-Test: yes` 与 `User-Agent: CustomUA/2.0` ⇒ 注入生效
#   格式：`Key: Value`（逗号分隔多个头），刻意与 mpv 的 `http-header-fields` 一致

# ⑥c **真机弱网判定**（`G5`：不崩 / 有缓冲提示 / 恢复后自动继续）—— 见 docs/12
#   ⚠️ 真机不能用 127.0.0.1：手机在另一台设备上 ⇒ 服务器要绑 0.0.0.0，URL 用宿主的局域网地址。
#   ⚠️ 也不要加 -traceUpdates：mpv 的 verbose 日志会把 devicectl --console 打爆，
#      日志**在第 2 秒就断流**，看起来像"播不动"（`P-058`）。判定用每秒一条的 `[status]`。
MACIP=$(ipconfig getifaddr en1 || ipconfig getifaddr en0)          # 本机局域网地址
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2 --host 0.0.0.0 --throttle 45000
xcrun devicectl device process launch --device <真机 UDID> --console \
  --terminate-existing com.playerstack.demo -- -directURL http://$MACIP:8765/sintel_trailer-720p.mp4
#   ⇒ 每秒一行：`[status] … state=playing t=…/… progress=… buffering=true|false …`
#   判据：state 始终 playing（不崩）· buffering 反复翻转（有提示）· t 在停住之后自行推进（自动继续）
#   参考值：720p 实时需 ≈146 KB/s；限到 45 000 B/s ⇒ 供给只有需求 1/3，缓存必然反复耗尽。
#   `--stall-at/--stall-for` 可造"挂住 N 秒再继续"（更长断网的恢复能力，尚未测）。

# ⑥d **可切清晰度**取证（`P5-T5`：HLS 多码率 = N 条 video track，切档 = 设 `vid`）
#   多码率源要现造（ffmpeg 一次性环境，不入仓库）。
#   ⚠️ 三档音频**刻意用不同采样率**（48000/44100/32000）：这样"切 vid 会不会带动音轨"
#      才是**可判**的（原来的源三档同为 48k ⇒ 切不切都报 48000，那个源本身答不出来）。
/opt/homebrew/bin/ffmpeg -y -i /tmp/vidprobe2/sintel_trailer-720p.mp4 \
  -filter_complex "[0:v]split=3[v1][v2][v3];\
    [v1]scale=w=1280:h=720[v1out];[v2]scale=w=854:h=480[v2out];[v3]scale=w=426:h=240[v3out];\
    [0:a]asplit=3[a1][a2][a3];[a1]aresample=48000[a1out];\
    [a2]aresample=44100[a2out];[a3]aresample=32000[a3out]" \
  -map "[v1out]" -map "[v2out]" -map "[v3out]" -map "[a1out]" -map "[a2out]" -map "[a3out]" \
  -c:v:0 libx264 -preset veryfast -b:v:0 2500k -c:v:1 libx264 -preset veryfast -b:v:1 1200k \
  -c:v:2 libx264 -preset veryfast -b:v:2 400k -c:a aac -b:a 128k \
  -f hls -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename "/tmp/hls-ladder/v%v/seg%03d.ts" -master_pl_name master.m3u8 \
  -var_stream_map "v:0,a:0 v:1,a:1 v:2,a:2" "/tmp/hls-ladder/v%v/index.m3u8"
#   （⚠️ 档位号是 `%v`，分片号是 `%d`；写错只报 "More than 1 variant streams are present"）

#   ⚠️ 真机不能走 127.0.0.1 ⇒ 服务器绑 0.0.0.0，URL 用宿主局域网地址。
MACIP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
python3 Tools/serve-range.py --port 8765 --root /tmp/hls-ladder --host 0.0.0.0
xcrun devicectl device process launch --device <真机 UDID> --console \
  --terminate-existing com.playerstack.demo -- \
  -directURL http://$MACIP:8765/master.m3u8 -exerciseTracks
#   ⇒ **[2026-10-16 真机实测过的输出]**（iPhone 16 Pro）
#     [tracks] 可选档位 3 条 · 清晰度菜单会出现
#     [tracks]   id=1  1280×720  ← 当前        ← 档位标签取 `demux-w/h`（不是 hls-bitrate，实测读不到）
#     [tracks]   id=2  854×480 · id=3  426×240
#     [tracks] 切档前音频：解码 48000 Hz / 输出 48000 Hz
#     [tracks] 切到 id=2 854×480
#     [tracks] 切档后音频：解码 48000 Hz / 输出 48000 Hz   ← **没跟着切**（见 docs/14 §8）
#     [tracks] 切档 3 秒后 → state=playing t=2.84/52.21 … 清晰度=854×480（共 3 档）
#   判据：① 菜单**只在多档时出现**（单码率下它是噪音）② 切档后回读的档位**必须是切走的那一档**
#         ③ 切档后 `t` 继续推进、`buffering` 不持续为真
#   单档源（普通 mp4）用同一条命令 ⇒ 应打出「不出现（只有一档 ⇒ 菜单是噪音）」。

# ⑥e **直播延迟测量**（`P6-T2`：口径 + 方法 + 基线，报告见 docs/15）
#   两个指标：A 起播延迟 · B 直播落后量（推流端已推媒体时间 − 播放端 time-pos）
#   ⚠️ A 的口径 2026-10-16 已修（`P6-T4`）：终点是**出画**，不是"首个 playing" —— 见 ⑥f
#   1) 源
mediamtx /tmp/mediamtx.yml
#   2) 推流（-re 实时 · **单次不 loop**，loop 会让媒体时间回绕、指标失效）
/opt/homebrew/bin/ffmpeg -re -i /tmp/vidprobe2/sintel_trailer-720p.mp4 -c copy \
  -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live -progress pipe:1 -nostats
#   ⇒ 周期性打印 `out_time=HH:MM:SS.ffffff` ← 「已推到的媒体时间」（权威值）
#   3) 播放（真机直连）
xcrun devicectl device process launch --device <真机 UDID> --console \
  --terminate-existing com.playerstack.demo -- -directURL rtsp://$MACIP:8554/live
#   ⇒ 每秒一行 [status] … t=…/… ← 「正在显示的媒体时间」
#   ⚠️ **两路必须合到同一时基**：out_time 是媒体时间、[status] 的时间戳是 App 自己的 origin，
#      直接相减得到的是垃圾。做法：用一个采集进程同时拉起两者，给**每一行**盖同一个墙钟。
#   ⚠️ **前提要验**：`-re` 的媒体时间推进速率应 ≈ 1.000×（实测 1.003×）。
#      不验这一条，落后量里就混进了推流端偏差 —— 而它看起来完全正常。
#   基线（2026-10-16 · 真机 iPhone 16 Pro）：起播 2063 ms · 落后量 ≈ 9000 ms（±50 ms，恒定）
#   ⚠️ **其中"起播 2063 ms"的口径已修**（`P6-T4`，见 ⑥f 与 docs/17）：那句 `playing` 落在 ~2 ms、
#      比文件打开还早，它不是在说"出画"；而且旧值是用每秒一行反推的（**±1 s 量化**），
#      与 ⑥f 的毫秒值**不可相减**。下面这两行"落后量"的口径不受影响。
#   「恒定」是判据：不是漂移 ⇒ 是**缓存深度** ⇒ 去看 `cache-secs`（产品没设 ⇒ mpv 默认 10 s）。
#   ⚠️ **要归因到产品，必须切成三段**（否则会把造源侧的缓冲当成产品缺陷，`P-052`）：
#       服务端段 = push.out_time − pull.out_time   ← 宿主原生 ffmpeg 也拉一路（**绕开产品**）
#       产品段   = pull.out_time − play.t          ← 只属于我们的播放器
#       ⚠️ pull 与 play **必须同一时刻启动**（错开 6 秒量出来的差不可比，`P-068`）。
#   实测结论（`docs/16`）：服务端段 ≈4.4 s（**原生客户端同样落后 ⇒ 不在产品里**）；
#     产品段：默认 4463 ms → `cache-secs=1` 2579 → ＋`cache-pause-initial=no` **1559 ms**（−65%）。
#     代价：弱网下 buffering 翻转 0.148 → 0.30 次/s（约 2 倍），而 `G5` 三条判据仍成立。

# ⑥f **起播延迟取证**（`P6-T4`：分段归因，报告见 docs/17）
#   指标 A 的口径是**出画**（内核的 `vo-configured`），不是"内核说在播" ——
#   实测后者落在 ~2 ms、**比文件打开还早**，它不是在说"点开等多久看到画面"。
#   ⚠️ **每次冷启量一次**：内核句柄是懒建的（首次 load 才建），
#      同一实例里第二次 load 走的是"换文件"，与冷启**不可比**。
python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2 --host 0.0.0.0
xcrun devicectl device process launch --device <真机 UDID> --console \
  --terminate-existing com.playerstack.demo -- \
  -directURL http://$MACIP:8765/sintel_trailer-720p.mp4
#   ⇒ [startup] 出画=178ms · 内核说在播=64ms · 分段: load-entered=0.0 handle-created=0.8 … vo-configured=177.7
#   怎么读（三段，按"谁决定"分）：
#     handle-created → initialized   产品固定开销（实测 1.8–7.4 ms，**含 MoltenVK / 管线编译**）
#     loadfile-sent → file-loaded    打开 + **流信息探测窗口**（实时源上它**就是**用户等待）
#     file-loaded → vo-configured    **源的（下一个）关键帧间隔**（不归产品管，`P-052`）
#   实测（真机 iPhone 16 Pro · 2026-10-16 · **出画** · 目标 1500 ms）：
#     HTTP mp4              178 / 234 / 224 ms    ✔
#     HLS 三档               463 ms               ✔
#     RTSP（源 GOP 0.5 s）   1045 / 766 / 1059 ms  ✔
#     RTSP（源 GOP ≤10.4 s） 2939 / 3819 / 7386 ms ✘ ← 全在等下一个关键帧（源的属性）
#   ⚠️ 它**不打开 mpv verbose 日志**（那是 `-traceUpdates`，会把 console 在第 2 秒打爆，`P-058`）。
#   ⚠️ 实时源另有一项产品侧改动：探测窗口缩到 0.2 s（`StreamProbePlan`，只对 rtsp/rtmp/srt/udp 生效；
#      HTTP / 本地文件**不动**）—— 它把实时源的 `file-loaded` 从 1131–1206 ms 压到 **311–420 ms**。

# ⑥g **HTTPS 行为 / 校验取证**（`P0-T5c` 验证 · `P0-T5d` 修复；报告见 docs/18 · docs/20）
#   ✅ **现状：校验已生效**。真因是 **mpv 的 `--tls-verify` 代码默认 `false`**（手册没写默认值），
#      它无条件把 `tls_verify=0` 传给 lavf ⇒ FFmpeg 走"不校验"分支。修法 = 一行
#      `setOption(handle, "tls-verify", "yes")`；**FFmpeg 不需要改**。
#   ⚠️ 重构建产物时注意：配方在 spike/p0-t5b-lgpl-dynamic-build/，改完要 `stage-libmpv.sh`
#      装入 + `nm -u` 确认 FFmpeg 补丁落地（P-078/P-079）。
#   ① 造一次性证书（/tmp，不入仓库）。四项硬要求少一条会得到"另一种失败"：
#      SAN 必填 · extendedKeyUsage=serverAuth · RSA≥2048 · 有效期 ≤825 天
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/pl-tls/ca.key -out /tmp/pl-tls/ca.crt \
  -days 2 -subj "/CN=PlayerStack Test CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
#   ② 起三台服务器，**只换证书**（CA1/名字匹配 · CA1/名字不匹配 · CA2/名字匹配）
python3 Tools/serve-range.py --port 8443 --root /tmp/vidprobe2 \
  --tls-cert /tmp/pl-tls/server.crt --tls-key /tmp/pl-tls/server.key
#   ③ 装/不装信任各跑一次（⚠️ 清代理变量：代理会劫持回环请求，P-059）
xcrun simctl keychain <UDID> add-root-cert /tmp/pl-tls/ca.crt
env -u HTTP_PROXY -u HTTPS_PROXY xcrun simctl launch --terminate-running-process \
  --console-pty <UDID> com.playerstack.demo -- -directURL https://127.0.0.1:8443/x.mp4
#   ⇒ 判据矩阵（模拟器实测**全中**）：明文照播（无回归）· 未受信任必失败 · 名字不匹配必失败 ·
#      **装进信任库后同一个 URL 能播** · 受信任但名字不匹配仍失败（主机名校验也在）·
#      **另一个从未装过的根必失败**（这条最干净：④ vs ⑦ 只差"哪个根"）
#   ⇒ 服务端会打 `[tls] 握手失败：… certificate unknown` —— 那是"客户端真的校验并拒绝"的直接证据；
#      只看客户端"没收货"不够：那与"压根没连上"看起来一样（P-056）。
#   ⚠️ 两个环境坑：`simctl launch --stdout/--stderr` 落不下东西（P-074，要用 --console-pty）；
#      **`simctl keychain reset` 并不撤销已装的根**（P-080）⇒ 闭合因果请换一个从未装过的根。

# ⑥h **HLS 直播取证**（`P6-T5`：起播 + 直播下的轨道清单，报告见 docs/19）
#   造三档 HLS 直播（滑动窗口 6×2s = 12s）；-re 实时 · -g 48 ⇒ 每 2s 一个关键帧
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
#   ⚠️ 生成完**先 `cat master.m3u8`**：目录形状多一层它就不落地，而且**不报错**（P-077）。
#   ⚠️ 地址**问路由表**别写死 en0（接口名会变，症状像"HLS 播放坏了"，P-076）：
MACIP=$(ipconfig getifaddr "$(route -n get default | awk '/interface:/{print $2}')")
python3 Tools/serve-range.py --port 8770 --root /tmp/hls-live-ladder --host 0.0.0.0
xcrun devicectl device process launch --device <真机 UDID> --console --terminate-existing \
  com.playerstack.demo -- -directURL "http://$MACIP:8770/master.m3u8" -exerciseTracks
#   ⇒ [startup] 出画=492ms · 三档清单 id=1/2/3 · 切档后回读 854×480 · 42s 0 次 failed
#   判"它真是直播"要看**服务端**：① playlist 被反复重载 ② playlist 里**没有** #EXT-X-ENDLIST
#   （客户端两种都是 state=playing，光看状态行分不出来）
#   想看"跟不上会怎样"：给服务器加 --throttle 200000（720p 档需要 ~362 KB/s ⇒ 必然跟不上）
#   ⇒ 实测 **0 次 404**：播放器只向前要数据，抓到的分片是 105→106→107→109→110→113→…（**跳过**）
#      即"丢内容追直播边缘"，不回头取已删分片 ⇒ 不会因此崩（docs/19 §五）

# ⑦ 真机（⚠️ 两套 Xcode 环境、两个 team ⇒ 构建时**命令行覆盖**，不改仓库）
#   环境 A · 家里：team UKXWZ3FS84 · 真机 Tango / iPhone 16 Pro
#   环境 B · 本机：team 3GMJYX32U9 · 真机 Tang的iPhone      ← `project.yml` 里写的是 A 的值
cd Demo && xcodegen generate
xcodebuild -project PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
  -destination 'id=<真机 UDID，用 xcrun devicectl list devices 现查>' \
  DEVELOPMENT_TEAM=3GMJYX32U9 \
  -derivedDataPath DD-Device-32U9 build
xcrun devicectl device install app --device <UDID> \
  DD-Device-32U9/Build/Products/Debug-iphoneos/PlayerStackDemo.app
#   ⚠️ 覆盖值必须同时对上两件事：**本机钥匙串里带私钥的 `Apple Development` 证书**
#      （本机 = `3GMJYX32U9` · `Tang Tango (WU37464V73)`）与**覆盖该设备的通配描述文件**。
#      对不上会报 `No profiles for 'com.playerstack.demo'` 或
#      `No "iOS Development" signing certificate matching team ID …` ——
#      两条报错**都会把你带去查账号**，而真因是**环境不对**（见 `P-055`）。
#   ⚠️ 本机 Xcode **未登录 Apple ID** ⇒ `-allowProvisioningUpdates` 必报 `No Accounts`，别用；
#      只吃本机已有的描述文件 + 证书。
#   ⚠️ 真机上的 `--console` 需要 `--` 把参数与 devicectl 自己的选项隔开（否则 `-traceUpdates`
#      会被解析成 devicectl 的 `-t`）。
```

> **构建/测试环境（沙箱逃逸、挑模拟器、toybox shim）用现成的技能，别在项目里再包一层：**
> `bash ~/.workbuddy/skills/macos-build-test/scripts/macos-run.sh probe` （SwiftPM / macOS）
> `bash ~/.workbuddy/skills/ios-build-test/scripts/ios-run.sh probe` （iOS 模拟器 / 真机）
> 两个脚本会自动补逃逸参数、自动挑可用模拟器、把日志落文件只回打关键行。
> 换设备先跑 `bash ~/.workbuddy/skills/install.sh`（实体随 Marquee 仓库走）。

> ⚠️ **测试一律用 Swift Testing**（`@Test` / `#expect` / `try #require`），**不使用 XCTest**。触及 `CAMetalLayer` 的套件须显式 `@Suite(.serialized)`（并行是默认）。
> ⚠️ **唯一例外：`Demo/UITests` 用 XCTest** —— UI 自动化需要 `XCUIApplication`，
> **Swift Testing 没有等价能力**。这是工具边界，不是"忘了迁移"，已写在文件头注释里，
> 避免日后被当违规清理（先例：`docs/03` L457–458 · [`docs/11`](docs/11-P3验证报告.md) L41–45）。
> ⚠️ **`Demo/project.yml` 必须显式声明 `schemes:`** —— xcodegen **默认不生成** scheme，没有它 `xcodebuild -scheme` 与 CI 全不可用（见 `P-030`）。

> ⚠️ **`PlayerCore` 里出现 `import SwiftUI` / `UIKit` / `AppKit` 即视为违规** —— 破了就永久失去可测性（KSPlayer 的教训），这是一条**架构约束**，与有没有自动门禁无关。
> ⚠️ **根包不得引用 libmpv** —— 适配器只在 `MPV/` 独立包内。原因：自建产物**只有 iOS 切片**，而 SPM 会校验 `binaryTarget` 路径存在性（与平台条件无关）⇒ 一旦放进根包，**新克隆的 `swift test` 必失败**。
> ⚠️ **以 `AsyncStream` 为边界的测试必须能"收尾 + 排空 + 断言 nil"**，否则只会"过"或"挂死"（见 `docs/PITFALLS.md` `P-014`）。
> ⚠️ **每个"边界 + 消费者"的组合必须有集成测试** —— 单元测试全绿不等于部件能组合（见 `P-018`）。

## 操作：键盘 · 全屏（`P7-T2`）

| 键 | 作用 | 什么时候有效 |
| --- | --- | --- |
| `空格` / `K` | 播放 / 暂停 | 加载过文件之后 |
| `←` / `J` | 后退 10 s | 同上，且**时长已知** |
| `→` / `L` | 前进 10 s | 同上 |
| `S` | 停止 | 同上，且不在 `idle` |
| `F` | 全屏开关 | **任何时候**（与有没有视频无关） |
| `Esc` | 退出全屏 | **仅在全屏时**；非全屏**不吞这个键**，原样交给宿主 |

- 字母键**大小写都认** —— 按住 Shift 不会失灵。
- **快捷键与按钮共用同一套可用性判据**（`canPlay` / `canStop` / `canSkip`）：
  按钮灰着时对应快捷键也没反应，不会出现"键盘能按、按钮不能按"这种更让人困惑的状态。
- **全屏**：macOS 落成**窗口真全屏**（`NSWindow.toggleFullScreen`，**先比对再调**，
  否则会在动画中途把窗口卡在半屏）；iOS 落成**状态栏 + home 指示条让位**。
  平台差异只收在 `PlayerHostFullscreen.swift` 一个文件里。
- ⚠️ **键盘**这一格已由 `Demo/UITests` 自动覆盖（`app.typeKey` 在 iOS 模拟器上可用，
  且"按 F 进全屏"的截图与"点全屏按钮"**逐字节相同**）—— 2026-10-16 补上。
  判定与副作用另有单测：`PlayerShortcutTests`（9 条）+ `PlayerViewModelShortcutTests`（7 条）。
- ⚠️ **仍未覆盖**：真机上的同一批用例（模拟器通过 ≠ 真机通过）。

## 目录结构

```
playerlearning/
├── docs/                  ← 我们的分析与决策（本仓库自己的产出）
│   ├── 01…07-*.md
│   └── assets/            ← 验证证据截图（p0t5a/ · p0t5b/）
├── spike/                 ← 一次性验证工程（不参与产品构建）
│   ├── p0-t5a-libmpv-smoke/        ← wid + MoltenVK 冒烟
│   └── p0-t5b-lgpl-dynamic-build/  ← 自建动态 LGPL 产物的构建方式
└── vendor/
    └── ksplayer/          ← KSPlayer 的只读学习副本（GPLv3，非我们的代码）
        ├── NOTICE.md      ← 来源 / 版本 / 许可 / 剔除说明 / 不可构建声明（先读）
        ├── Sources/       ← KSPlayerUI + MPVPlayer（13,920 行）
        ├── Documents/     ← 原理详解 + AVPlayer踩坑记
        └── ...
```

> **`spike/` 与产品代码的边界**：`spike/` **不参与产品构建**、不是产品代码；产品骨架在 Phase 1 新建 `PlayerCore` / `PlayerUI` 双 target。产物二进制（104 MB）**不入 git**，由脚本产出。

## 参考源

| 项 | 值 |
| --- | --- |
| 上游仓库 | `git@github.com:kingslay/KSPlayer.git` |
| 评估快照 | branch `main` · HEAD `01dba13`（2026-10-10） · `git describe = 2.3.4-71-g01dba13` |
| 授权 | **GPLv3**（默认，免费）/ LGPL（付费）/ 商业另行授权 |

> 评估结论绑定上述 commit。上游 `main` 是滚动分支，若后续拉取新版本，`docs/01` 中标注为「快照事实」的数字需要重新核对。

## ⚠️ 许可提示

### `vendor/ksplayer/`（参考副本）

`vendor/ksplayer/` 是 **GPLv3** 代码。把它放进本仓库意味着**本仓库的 `vendor/` 部分受 GPL 约束**。

- **只发 `docs/` 不发 `vendor/` ⇒ 无影响。**
- 本项目**要上架 App Store**（`docs/02` A1 已于 2026-10-13 反转），因此：
  - ❌ **不得把它的代码文本抄进产品代码**（原「自用不分发 ⇒ 可放心借鉴」的理由已失效）；
  - ✅ 只可借**设计思想与抽象**；
  - 若对外分发本仓库：需移除 `vendor/`，或整体遵守 GPL。
- 本副本**不是**我们的代码，任何对外产物都不应链接或引用它。

### 我们自己的产物（libmpv）

产物为自建 **LGPL-2.1** 动态 framework。三个必须记住的点：

1. **定义可上架性的不是「用了 libmpv」，而是「LGPL 构建 + 动态链接」**这两个条件。
2. **要交的是「对应源码 + 构建方式」** —— 构建方式已归档在 `spike/p0-t5b-lgpl-dynamic-build/`。
3. ⚠️ **iOS 上「用户可替换库」实质不成立**（App 由 Apple 联合签名 + FairPlay 加密）⇒ 只能**尽力合规**，对外不得宣称「已确保合规」。**唯一真实风险来源是上游 contributor 投诉**（VLC 2011 先例），不是 Apple 审核。

> 完整判定树与红线见 [`docs/02` §三「分发口径」](docs/02-自建播放器决策记录.md)。

## 各阶段完成情况（Phase 0 ~ 7 · **八个阶段全部关闭**）

> 票面与判定门的单一出处是 [`docs/03-路线图.md`](docs/03-路线图.md)；下表只是索引。

| Phase | 判定门 | 结果 |
| --- | --- | --- |
| 0 风险排除 | `G0` / `M0` | ✅ 自建动态 LGPL-2.1 `Libmpv.xcframework`，模拟器 + 真机双通出画面 |
| 1 骨架与抽象 | `G1` / `M1` | ✅ `PlayerKernelProtocol` / 注册表 / `FakeKernel` / 状态机 / 时间模型；`PlayerCore` 零 UI 依赖 |
| 2 内核接入 | `G2` / `M2` | ✅ 出画 + 出声 + `seek` 精确 + 播完报 `.finished`（[`docs/10`](docs/10-P2验证报告.md)） |
| 3 UI 最小闭环 | `G3` | ✅ 播放/暂停 · 时间 · 进度条+拖拽 · 全屏 · 字幕开关 · 文件选择（[`docs/11`](docs/11-P3验证报告.md)） |
| 4 字幕 | `G4` | ✅ SRT 中文不乱码 · ASS 能加载渲染 · 字幕延迟可调（[`docs/03`](docs/03-路线图.md) 的 📌） |
| 5 网络点播 | `G5` / `M4` | ✅ 四项全有证据：弱网不崩 · 有缓冲提示 · 恢复后继续 · **可切清晰度（真机三档）**（[`docs/12`](docs/12-P5验证报告.md) · [`docs/14`](docs/14-P5-T5-HLS多码率调研.md)） |
| 6 直播 | `G6`（未单列） | ✅ `P6-T0`–`T4` 五票交付：真机 RTSP 打通 · **落后量 −65%** · **起播产品段 −65%**（[`docs/15`](docs/15-P6-T2-延迟指标.md) / [`docs/16`](docs/16-P6-T3-低延迟参数.md) / [`docs/17`](docs/17-P6-T4-起播延迟.md)） |
| 7 macOS | `G7` / `M5` | ✅ 同一 SPM 包在 macOS **零源码改动**编译通过（⚠️ 达成口径是**编译面**：macOS 用 stub 内核，没有真实播放） |

## 仍未覆盖（**不在"已完成"里**）

| 项 | 说明 |
| --- | --- |
| ~~HTTPS 流的实际行为~~ → **已验证并已修复** | `P0-T5c` 验出**只加密、不校验证书**（不受信任/名字不匹配都照播）；`P0-T5d` **修好**：真因是 **mpv 的 `--tls-verify` 代码默认 `false`** ⇒ 一行 `tls-verify=yes` 即让校验生效（六条探针全中），**FFmpeg 无需改动**。见 [`docs/18`](docs/18-P0-T5c-HTTPS行为验证.md) / [`docs/20`](docs/20-P0-T5d-HTTPS校验修复.md) |
| 切清晰度是否带动音轨 | ✅ **已答**：不带动（三档音频做成不同采样率实测，[`docs/14`](docs/14-P5-T5-HLS多码率调研.md) §8） |
| ~~直播下的轨道清单~~ → **已验** | `P6-T5`（2026-10-16）：HLS **直播**下三档照常枚举、切档回读正确（[`docs/19`](docs/19-P6-T5-HLS直播源.md)） |
| ~~HLS **直播**源的起播~~ → **已验** | `P6-T5`：出画 **492 ms**（拉取式 ⇒ 短探测窗口规则不作用于它，本来就不慢） |
| LL-HLS（`#EXT-X-PART`）的起播与延迟 | **未测**：本轮是常规 HLS（2 s 分片 ⇒ 天然 ~6–8 s 落后），需要一个支持 partial segment 的源 |
| 直播下的**进度呈现** | **未定（产品决策）**：`duration` = 滑窗末端 ⇒ 进度百分比无意义（`progress` 恒在 0.9+）。见 [`docs/03`](docs/03-路线图.md) §五 |
| macOS 上真实播放 | **未验**（自建 libmpv 只有 iOS 切片）⇒ `M5` 的口径只能是编译面 |


## 下一步

**票面已清空：`docs/03` 里 36 张票全部 ✓，八个 Phase 全部关闭，`M0`–`M5` 全部达成。**
（`M5` 的达成口径是**编译面** —— 见上面阶段表里那句 ⚠️。）

要继续往下推，只剩"**已知缺口**"与"**只能人做**"两类（都在上面「仍未覆盖」表里）：

1. ~~**HTTPS 证书校验**~~ —— ✅ **已验并已修**（`P0-T5c` 验出缺口 · `P0-T5d` 修复）：
   真因是 mpv 的 `--tls-verify` **代码默认 `false`** ⇒ 一行 `tls-verify=yes` 让校验生效；
   FFmpeg 不需要改。边界：真机上"装 CA 后能播"**刻意不验**（要动用户手机的信任设置）。
   见 [`docs/20`](docs/20-P0-T5d-HTTPS校验修复.md)。
2. ~~**直播下的轨道清单 / HLS 直播源的起播**~~ —— ✅ **已验**（`P6-T5`，[`docs/19`](docs/19-P6-T5-HLS直播源.md)）。
   顺带验掉了一个担心的失败形态：落后于滑动窗口**不会崩**，是"丢内容追直播边缘"（0 次 404）。
   剩下的直播项：**LL-HLS**（需要 partial segment 的源）· **直播下的进度呈现**（产品决策）。
3. **只能肉眼做的**：弱网缓冲提示的文案是否够清楚；键位的**手感**（判定与副作用已被单测与真机 UI 用例覆盖）。

> **范围锚点是 `M4`（在线点播可用）**：任何不推进 `M4` 的需求都往后排。
>
> **环境（一次性，不入仓库）**：`brew install mediamtx ffmpeg` —— 造多码率源 / 直播源都用它。
> 复现步骤见 [`docs/14`](docs/14-P5-T5-HLS多码率调研.md) §五 · 起播取证见本文件 ⑥f。⚠️ 本机跑本地服务时
> **要清 `HTTP_PROXY`**（会话代理会劫持回环请求，见 `PITFALLS` 的 `P-059`）。

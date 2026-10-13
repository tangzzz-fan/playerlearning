#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; exit 1; }

# 挑一个可用的 iPhone 模拟器 —— **不写死机型**（`P-030` 家族：写死设备名会在换机/升级后静默失效）。
# 优先已启动的（省一次冷启动），否则取最新 runtime 的第一个可用 iPhone。
pick_simulator() {
  python3 - <<'PY' || return 1
import json
import subprocess
import sys

listing = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    capture_output=True, text=True, check=True,
).stdout
devices = json.loads(listing)["devices"]
ordered = [d for _, group in sorted(devices.items(), reverse=True) for d in group]
iphones = [d for d in ordered if d.get("isAvailable") and "iPhone" in d.get("name", "")]
for device in iphones:
    if device.get("state") == "Booted":
        print(device["udid"])
        sys.exit(0)
for device in iphones:
    print(device["udid"])
    sys.exit(0)
sys.exit(1)
PY
}

# 受限 shell 里 macOS 不允许再 apply 一层 deny-default 沙箱 ⇒ SwiftPM 的清单/插件沙箱会被拒，
# 报 sandbox_apply: Operation not permitted。按需补逃逸参数（只加在命令行，绝不写进工程文件）。
if sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1; then
  SWIFT_ESCAPE=()
  XCB_ESCAPE=()
else
  SWIFT_ESCAPE=(--disable-sandbox)
  XCB_ESCAPE=(OTHER_SWIFT_FLAGS=-disable-sandbox)
  printf '（受限 shell：SwiftPM / xcodebuild 将附加逃逸参数）\n'
fi

# ── 运行模式 ───────────────────────────────────────────────────────────
# 全量 8 步里，[4]~[7] 三步要拉起 libmpv 产物与 iOS 模拟器，合计 ≈4 分钟。
# 节点内改的往往是 PlayerCore 的纯逻辑，跟那三步**无关** —— 每次全跑是纯浪费。
#   ./Tools/gate.sh                      全量（阶段末 / 推送前）
#   ./Tools/gate.sh core                 逻辑门：[1]~[3] + [8]，不碰模拟器
#   ./Tools/gate.sh core --only <前缀>    再只变异这些文件（节点内最快，≈40 秒）
MODE=full
ONLY_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    core) MODE=core ;;
    --only)
      # 允许一次给多个前缀（节点内常要覆盖新加的若干文件）。
      shift
      [ $# -gt 0 ] || { printf '--only 缺少参数\n' >&2; exit 2; }
      ONLY_ARGS=(--only)
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
        ONLY_ARGS+=("$1")
        shift
      done
      continue
      ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

printf '═══ 判定门（G1 + Phase 2 增量）═══\n'
printf '依据 docs/03 §三 · docs/09 §四 D-a\n'
printf '模式：%s%s\n\n' "$MODE" "${ONLY_ARGS[*]:+（--only ${ONLY_ARGS[*]:1}）}"

printf '[1/8] PlayerCore 零 UI 框架 import\n'
if grep -rE 'import (SwiftUI|UIKit|AppKit)' Sources/PlayerCore/; then
  fail 'PlayerCore 出现 UI 框架 import（违反 docs/02 施工约束 1）'
fi
pass 'PlayerCore 内无 SwiftUI / UIKit / AppKit'

printf '\n[2/8] 根包 swift build\n'
if ! swift build "${SWIFT_ESCAPE[@]+"${SWIFT_ESCAPE[@]}"}" > /tmp/gate-build.log 2>&1; then
  # 失败分支**必须给出东西**：匹配不到已知签名时回退打日志末尾（见 P-027）。
  excerpt="$(grep -E 'error:|BUILD FAILED|sandbox_apply' /tmp/gate-build.log | head -30 || true)"
  [ -n "$excerpt" ] || excerpt="$(tail -20 /tmp/gate-build.log)"
  printf '%s\n' "$excerpt"
  fail '构建失败（日志 /tmp/gate-build.log）'
fi
pass '构建通过'

printf '\n[3/8] 根包 swift test\n'
if ! swift test "${SWIFT_ESCAPE[@]+"${SWIFT_ESCAPE[@]}"}" > /tmp/gate-test.log 2>&1; then
  # ⚠️ 两个坑一起防：
  #   1. `grep … | head` 无匹配时退出码非 0，在 `set -e` 下会让**脚本先死掉**，fail 那句根本轮不到；
  #   2. Swift Testing 的失败签名是 `✘` / `Expectation failed`，不在 `error:` 里，漏了就一条都列不出。
  excerpt="$(grep -E 'error:|✘|Expectation failed|recorded an issue|BUILD FAILED' /tmp/gate-test.log | head -30 || true)"
  [ -n "$excerpt" ] || excerpt="$(tail -20 /tmp/gate-test.log)"
  printf '%s\n' "$excerpt"
  fail '测试未全绿（日志 /tmp/gate-test.log）'
fi
# 测试全用 Swift Testing（@Test / #expect）。⚠️ 三个坑都要防：
#   1. 汇总行格式是 `Test run with N tests in M suites passed after …` —— 正则漏了 " in M suites" 就一条都匹配不到；
#   2. `set -euo pipefail` 下，`$(grep … | tail -1)` **无匹配会让整脚本无声退出**，所以必须 `|| true`；
#   3. ⚠️ **每个 test bundle 各打一行** `Test run with …`，所以 `tail -1` 会**少算** ——
#      这是 `P-023` 的同一个坑换了个签名（XCTest 时代的 "Executed N tests" 也是按 bundle 各打一次）。
#      ⇒ 必须**跨所有 run 求和**，并且核对 run 数。
runs="$(grep -cE 'Test run with [0-9]+ tests?' /tmp/gate-test.log || true)"
if [ "${runs:-0}" -eq 0 ]; then
  tail -20 /tmp/gate-test.log
  fail '未找到任何测试汇总行 —— 测试可能根本没执行（P-023 / P-026）'
fi
total="$(grep -Eo 'Test run with [0-9]+ tests?' /tmp/gate-test.log | grep -Eo '[0-9]+' | awk '{s+=$1} END {print s+0}')"
failedRuns="$(grep -E 'Test run with [0-9]+ tests?' /tmp/gate-test.log | grep -c 'failed' || true)"
printf '  %s tests · 跨 %s 个 test bundle · %s 个失败 run\n' "$total" "$runs" "${failedRuns:-0}"
if [ "${failedRuns:-0}" -ne 0 ]; then
  grep -E '✘|Expectation failed|recorded an issue' /tmp/gate-test.log | head -20 || true
  fail '存在失败的测试'
fi
pass '测试全绿'

if [ "$MODE" = core ]; then
  printf '\n[4/8]~[7/8] SKIP —— core 模式（节点内）\n'
  printf '  这一步省下的是：MPV 包编译 · MPV 内核行为测试 · G2 接线 · G3 手指层面（≈4 分钟，需模拟器）\n'
  printf '  ⚠️ 本次**未验证**上述四项。阶段末请跑不带 core 的全量门禁。\n'
  # ⚠️ 只在"跳过的东西恰好被本次改动覆盖"时才警告 —— 否则警告会变成噪音，最终被无视。
  touched="$(git diff --name-only HEAD -- MPV Demo Sources/PlayerUI 2>/dev/null || true)"
  if [ -n "$touched" ]; then
    printf '  ⚠️⚠️ 但本次改动**正好碰到**被跳过的那一层：\n'
    while IFS= read -r path; do printf '       %s\n' "$path"; done <<< "$touched"
    printf '  ⇒ 这次 core 模式**不足够**，请跑全量门禁再提交。\n'
  else
    printf '  （本次改动都在 Sources/PlayerCore，与那三项无关 ⇒ 跳过是安全的）\n'
  fi
else
printf '\n[4/8] MPV 包构建（libmpv 适配器）\n'
# ⚠️ 为什么必须有这一步：`MPV/` 是**独立包**，根包的 build/test 完全看不到它。
# `P2-T4` 给 PlayerKernelEvent 加了 `.videoSizeChanged`，把 `MPVKernel` 的 switch 打破成非穷尽 ——
# 根包门禁全绿，**这个编译破坏却一直没被任何信号发现**，直到本机终于有了产物（见 P-034）。
# ⚠️ 产物 104 MB 且不入 git ⇒ **"存在才跑"，不硬失败**（docs/09 §四 D-a）；
#    但跳过时必须**显式说明后果**，不能让人以为"绿了就是绿了"。
if [ ! -d "$ROOT/MPV/Library/Libmpv.xcframework" ]; then
  printf '  SKIP —— 产物未 stage（先跑 ./Tools/stage-libmpv.sh）\n'
  printf '  ⚠️ 本次**未验证** MPVKernel 的编译，其破坏不会被这个门禁发现（P-034）\n'
else
  if ! (cd "$ROOT/MPV" && xcodebuild -scheme PlayerMPV \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath DD-iOS \
        "${XCB_ESCAPE[@]+"${XCB_ESCAPE[@]}"}" build) > /tmp/gate-mpv.log 2>&1; then
    excerpt="$(grep -E 'error:|BUILD FAILED' /tmp/gate-mpv.log | head -30 || true)"
    [ -n "$excerpt" ] || excerpt="$(tail -20 /tmp/gate-mpv.log)"
    printf '%s\n' "$excerpt"
    fail 'MPV 包构建失败（日志 /tmp/gate-mpv.log）'
  fi
  pass 'MPV 包构建通过'
fi

printf '\n[5/8] MPV 包测试（真实 libmpv，iOS 模拟器）\n'
# ⚠️ 这一步是 `P2-T9` 的剩余一半，也是 `P-034` 的真正解法：
#    只有"跑"起来才能验证 `/MPVKernel` 的**行为**，而不只是"能编译"。
#    测试会在模拟器里拉起真实 mpv 实例，素材由 `TestClip` 用 AVAssetWriter **现场生成**
#    （确定性、零网络、不往仓库塞二进制 —— `P-033`）。
# ⚠️ 与 [4/8] 同样"存在才跑"：产物不在就没有可测的东西，跳过但**必须说清后果**。
if [ ! -d "$ROOT/MPV/Library/Libmpv.xcframework" ]; then
  printf '  SKIP —— 产物未 stage（与 [4/8] 同因）\n'
  printf '  ⚠️ 本次**未运行** MPVKernel 的行为测试\n'
elif ! SIM_UDID="$(pick_simulator)"; then
  printf '  SKIP —— 找不到可用的 iPhone 模拟器\n'
  printf '  ⚠️ 本次**未运行** MPVKernel 的行为测试（只有 [4/8] 的编译检查）\n'
else
  if ! (cd "$ROOT/MPV" && xcodebuild -scheme PlayerMPV \
        -destination "platform=iOS Simulator,id=$SIM_UDID" \
        -derivedDataPath DD-Test \
        "${XCB_ESCAPE[@]+"${XCB_ESCAPE[@]}"}" test) > /tmp/gate-mpvtest.log 2>&1; then
    excerpt="$(grep -E 'error:|✘|Expectation failed|recorded an issue|TEST FAILED' /tmp/gate-mpvtest.log | head -30 || true)"
    [ -n "$excerpt" ] || excerpt="$(tail -20 /tmp/gate-mpvtest.log)"
    printf '%s\n' "$excerpt"
    fail 'MPV 包测试失败（日志 /tmp/gate-mpvtest.log）'
  fi
  # 同 [3/8] 的纪律：**取不到汇总行就是失败**，不能打印空计数还判绿（`P-023`）。
  # ⚠️ 这里**整行取回**而不是 `-o` 截片段：`[^.]*` 会在 "passed after 7.123 seconds" 的
  #    小数点处断掉，打出 "after 7" 这种残句（把签名卡太死的典型后果，见 `P-027`）。
  mpvSummary="$(grep -E 'Test run with [0-9]+ tests?' /tmp/gate-mpvtest.log | tail -1 || true)"
  if [ -z "$mpvSummary" ]; then
    tail -20 /tmp/gate-mpvtest.log
    fail 'MPV 包未产出测试汇总行 —— 测试可能根本没执行（P-023）'
  fi
  printf '  %s\n' "$mpvSummary"
  pass 'MPV 包测试全绿'
fi

printf '\n[6/8] G2 端到端（Demo 在模拟器里真跑一遍）\n'
# ⚠️ 为什么单列一步：`[5/7]` 的 MPV 包测试是 **headless**（`vo=null`），
#    它证明不了"真画面能出来" —— `wid` + MoltenVK + `CAMetalLayer` 这条接线
#    **只有把 App 真跑起来才覆盖**（docs/10 §三）。
# ⚠️ 与 [4/8]/[5/7] 同规矩：产物不在或没有可用模拟器就 SKIP，但**必须说清后果**。
if [ ! -d "$ROOT/MPV/Library/Libmpv.xcframework" ]; then
  printf '  SKIP —— 产物未 stage（与 [4/8] 同因）\n'
  printf '  ⚠️ 本次**未验证**端到端出画与性能基线\n'
elif ! SIM_UDID="$(pick_simulator)"; then
  printf '  SKIP —— 找不到可用的 iPhone 模拟器\n'
  printf '  ⚠️ 本次**未验证**端到端出画与性能基线\n'
else
  G2_LOG=/tmp/gate-g2.log
  if ! (cd "$ROOT/Demo" && xcodegen generate \
        && xcodebuild -project PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
             -destination "platform=iOS Simulator,id=$SIM_UDID" \
             -derivedDataPath DD \
             "${XCB_ESCAPE[@]+"${XCB_ESCAPE[@]}"}" build) > "$G2_LOG" 2>&1; then
    excerpt="$(grep -E 'error:|BUILD FAILED' "$G2_LOG" | head -20 || true)"
    [ -n "$excerpt" ] || excerpt="$(tail -20 "$G2_LOG")"
    printf '%s\n' "$excerpt"
    fail 'Demo 构建失败（日志 '"$G2_LOG"'）'
  fi

  APP="$ROOT/Demo/DD/Build/Products/Debug-iphonesimulator/PlayerStackDemo.app"
  xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
  xcrun simctl install "$SIM_UDID" "$APP" >> "$G2_LOG" 2>&1
  xcrun simctl terminate "$SIM_UDID" com.playerstack.demo >/dev/null 2>&1 || true

  # 后台起 App 并把它的 stderr（含 [trace] 行，**无缓冲**）落到日志。
  ( xcrun simctl launch --console "$SIM_UDID" com.playerstack.demo \
      -autoLoadSample -traceUpdates > /tmp/gate-g2-app.log 2>&1 ) &
  # 等"播完"（样例 5 s）—— 有上限，失败表现为失败而不是挂死（P-014）。
  g2Ready=0
  for _ in $(seq 1 30); do
    sleep 2
    if grep -q 'stateChanged(PlayerCore.PlayerState.finished)' /tmp/gate-g2-app.log 2>/dev/null; then
      g2Ready=1
      break
    fi
  done
  xcrun simctl io "$SIM_UDID" screenshot "$ROOT/docs/assets/p2t11/gate-screenshot.png" >> "$G2_LOG" 2>&1 || true
  xcrun simctl terminate "$SIM_UDID" com.playerstack.demo >/dev/null 2>&1 || true

  if [ "$g2Ready" -ne 1 ]; then
    # 失败分支必须给东西（P-027）：把已经收到的 trace 打出来。
    printf '%s\n' "$(grep -F '[trace]' /tmp/gate-g2-app.log | tail -15 || true)"
    fail '端到端未走到 .finished（日志 /tmp/gate-g2-app.log）'
  fi
  # 四条都要有：播放过、画面尺寸到过、**音频输出建立过**、播完报过。
  # ⚠️ "出声"这条用 `audio-out-params/samplerate` 非零来判 —— 它是 API 层面能拿到的
  #    最强证据（音频输出已建立）。**它不等于"扬声器响了"**（那要录音或人耳），
  #    docs/10 §一 已把口径写清楚，不夸大。
  for marker in 'stateChanged(PlayerCore.PlayerState.playing)' \
                'videoSizeChanged((640.0, 360.0))' \
                'audioChanged(PlayerCore.PlayerAudioState(decoderSampleRate: 44100, outputSampleRate: 44100))' \
                'stateChanged(PlayerCore.PlayerState.finished)'; do
    if ! grep -qF "$marker" /tmp/gate-g2-app.log; then
      printf '%s\n' "$(grep -F '[trace]' /tmp/gate-g2-app.log | tail -15 || true)"
      fail "端到端缺关键事件：$marker"
    fi
  done
  firstFrame="$(grep -F '[trace]' /tmp/gate-g2-app.log \
    | grep -F 'videoSizeChanged' | head -1 | awk '{print $2}' || true)"
  printf '  出画 + 出声（音频输出已建立）+ 播完 均已上报（画面尺寸首次上报于 t=%s s）\n' "${firstFrame:-?}"
  pass 'G2 端到端通过'
fi

printf '\n[7/8] G3 UI 交互（模拟器上真点一遍）\n'
# ⚠️ 为什么单列：G2 证的是"链路能通"，**证不了"手指点得动"** ——
#    按钮接线、可点区域、全屏要不要收起宿主外壳，这些只有真点才知道（docs/11 §三）。
# ⚠️ 与 [4/8]~[6/8] 同规矩：产物不在或没有模拟器就 SKIP，但**必须说清后果**。
if [ ! -d "$ROOT/MPV/Library/Libmpv.xcframework" ]; then
  printf '  SKIP —— 产物未 stage（与 [4/8] 同因）\n'
  printf '  ⚠️ 本次**未验证** UI 可点可拖可全屏\n'
elif ! SIM_UDID="$(pick_simulator)"; then
  printf '  SKIP —— 找不到可用的 iPhone 模拟器\n'
  printf '  ⚠️ 本次**未验证** UI 可点可拖可全屏\n'
else
  if ! (cd "$ROOT/Demo" && xcodegen generate \
        && xcodebuild -project PlayerStackDemo.xcodeproj -scheme PlayerStackDemo \
             -destination "platform=iOS Simulator,id=$SIM_UDID" \
             -derivedDataPath DD \
             "${XCB_ESCAPE[@]+"${XCB_ESCAPE[@]}"}" test) > /tmp/gate-g3.log 2>&1; then
    excerpt="$(grep -E 'error:|XCTAssert|Test Case .* failed|TEST FAILED' /tmp/gate-g3.log | head -30 || true)"
    [ -n "$excerpt" ] || excerpt="$(tail -20 /tmp/gate-g3.log)"
    printf '%s\n' "$excerpt"
    fail 'G3 UI 测试失败（日志 /tmp/gate-g3.log）'
  fi
  # 同 [3/8] 的纪律：**取不到汇总行就是失败**，不能打印空计数还判绿（P-023）。
  # ⚠️ UI 测试的签名是 XCTest 那套（Swift Testing 驱动不了 XCUIApplication），所以正则也换一套。
  g3Summary="$(grep -Eo 'Executed [0-9]+ tests?, with [0-9]+ failures?' /tmp/gate-g3.log | tail -1 || true)"
  if [ -z "$g3Summary" ]; then
    tail -20 /tmp/gate-g3.log
    fail 'G3 未产出测试汇总行 —— UI 测试可能根本没执行（P-023）'
  fi
  printf '  %s\n' "$g3Summary"
  if ! grep -q 'TEST SUCCEEDED' /tmp/gate-g3.log; then
    grep -E 'XCTAssert|Test Case .* failed' /tmp/gate-g3.log | head -20 || true
    fail 'G3 未报 TEST SUCCEEDED'
  fi
  pass 'G3 UI 交互通过（能播 · 能暂停 · 能拖进度 · 能全屏 · 选择器可拉起）'
fi
fi

printf '\n[8/8] 变异测试\n'
if ! python3 Tools/mutation_check.py "${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"}"; then
  fail '存在存活或超时的变异体'
fi
pass '变异体全部被杀死'

printf '\n═══ 判定门通过 ═══\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; exit 1; }

# 受限 shell 里 macOS 不允许再 apply 一层 deny-default 沙箱 ⇒ SwiftPM 的清单/插件沙箱会被拒，
# 报 sandbox_apply: Operation not permitted。按需补逃逸参数（只加在命令行，绝不写进工程文件）。
if sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1; then
  SWIFT_ESCAPE=()
else
  SWIFT_ESCAPE=(--disable-sandbox)
  printf '（受限 shell：SwiftPM 构建将附加 --disable-sandbox）\n'
fi

printf '═══ G1 判定门 ═══\n'
printf '依据 docs/03 §三 · 三条须同时满足\n\n'

printf '[1/4] PlayerCore 零 UI 框架 import\n'
if grep -rE 'import (SwiftUI|UIKit|AppKit)' Sources/PlayerCore/; then
  fail 'PlayerCore 出现 UI 框架 import（违反 docs/02 施工约束 1）'
fi
pass 'PlayerCore 内无 SwiftUI / UIKit / AppKit'

printf '\n[2/4] swift build\n'
if ! swift build "${SWIFT_ESCAPE[@]+"${SWIFT_ESCAPE[@]}"}" > /tmp/gate-build.log 2>&1; then
  # 失败分支**必须给出东西**：匹配不到已知签名时回退打日志末尾（见 P-027）。
  excerpt="$(grep -E 'error:|BUILD FAILED|sandbox_apply' /tmp/gate-build.log | head -30 || true)"
  [ -n "$excerpt" ] || excerpt="$(tail -20 /tmp/gate-build.log)"
  printf '%s\n' "$excerpt"
  fail '构建失败（日志 /tmp/gate-build.log）'
fi
pass '构建通过'

printf '\n[3/4] swift test\n'
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

printf '\n[4/4] 变异测试\n'
if ! python3 Tools/mutation_check.py; then
  fail '存在存活或超时的变异体'
fi
pass '变异体全部被杀死'

printf '\n═══ G1 达成 ═══\n'

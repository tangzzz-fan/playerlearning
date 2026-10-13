#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; exit 1; }

printf '═══ G1 判定门 ═══\n'
printf '依据 docs/03 §三 · 三条须同时满足\n\n'

printf '[1/4] PlayerCore 零 UI 框架 import\n'
if grep -rE 'import (SwiftUI|UIKit|AppKit)' Sources/PlayerCore/; then
  fail 'PlayerCore 出现 UI 框架 import（违反 docs/02 施工约束 1）'
fi
pass 'PlayerCore 内无 SwiftUI / UIKit / AppKit'

printf '\n[2/4] swift build\n'
if ! swift build > /tmp/gate-build.log 2>&1; then
  tail -30 /tmp/gate-build.log
  fail '构建失败（日志 /tmp/gate-build.log）'
fi
pass '构建通过'

printf '\n[3/4] swift test\n'
if ! swift test > /tmp/gate-test.log 2>&1; then
  grep -E 'error:|XCTAssert' /tmp/gate-test.log | head -30
  fail '测试未全绿（日志 /tmp/gate-test.log）'
fi
# `swift test` 会为**每个 test bundle** 各打一次 "All tests" 小结，
# 所以取最后一行会少算；这里把各 bundle 的小结配对后求和。
summary="$(grep -A1 -E "Test Suite '[^']*\.xctest' (passed|failed)" /tmp/gate-test.log \
  | grep -oE 'Executed [0-9]+ tests, with [0-9]+ failures')"
total="$(printf '%s\n' "$summary" | grep -oE 'Executed [0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')"
failures="$(printf '%s\n' "$summary" | grep -oE 'with [0-9]+ failures' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')"
bundles="$(grep -cE "Test Suite '[^']*\.xctest' passed" /tmp/gate-test.log)"
printf '  %s tests · %s failures（跨 %s 个 test bundle 汇总）\n' "$total" "$failures" "$bundles"
pass '测试全绿'

printf '\n[4/4] 变异测试\n'
if ! python3 Tools/mutation_check.py; then
  fail '存在存活或超时的变异体'
fi
pass '变异体全部被杀死'

printf '\n═══ G1 达成 ═══\n'

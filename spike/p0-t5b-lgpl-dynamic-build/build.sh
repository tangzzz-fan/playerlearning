#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/tmp/p0t5b-build}"
SRC="$WORK/mpvkit"
REVISION="d9194243bdc68b87d8989376ab52aee7da6c8e0b"

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  echo "clone MPVKit @ $REVISION"
  git clone https://github.com/mpvkit/MPVKit.git "$SRC"
  git -C "$SRC" checkout "$REVISION"
fi

# 依次应用本目录下的补丁（01 = 动态化 + 压回 LGPL-2.1；02 = 环境变量转发）。
# 幂等：已应用的会被 --check 挡下并跳过。
for patch in "$HERE"/0*.patch; do
  if git -C "$SRC" apply --check "$patch" 2>/dev/null; then
    git -C "$SRC" apply "$patch"
    echo "applied $(basename "$patch")"
  else
    echo "skip $(basename "$patch")（已应用或上下文不符）"
  fi
done

if ! command -v wget >/dev/null 2>&1; then
  echo "wget is required by the build script"
  exit 1
fi

export HOMEBREW_NO_AUTO_UPDATE=1

# 某些受限网络（MITM 代理）下 `github.com` 的证书无法在本地验证 ⇒ wget 退出码 5：
#   ERROR: cannot verify github.com's certificate … Unable to locally verify the issuer's authority.
# 这里同样用**探针**决定，且**只作用于本次调用**（WGETRC 指向临时文件）：
# 绝不写进 ~/.wgetrc 或 /opt/homebrew/etc/wgetrc —— 那会让正常网络也失去校验。
# 注意这是**环境适配**，不是构建配方的一部分。
if wget -q --spider --timeout=15 https://github.com >/dev/null 2>&1; then
  echo "（wget 证书校验正常，不做改动）"
else
  printf 'check_certificate = off\n' > "${TMPDIR:-/tmp}/p0t5b-wgetrc"
  export WGETRC="${TMPDIR:-/tmp}/p0t5b-wgetrc"
  echo "⚠️ wget 无法验证证书（MITM 代理）⇒ 本次构建经 WGETRC 关闭校验（仅本次调用）"
fi

# 受限 shell（agent 会话 / 某些 CI 容器）里 macOS 不允许再 apply 一层 deny-default 沙箱，
# 而 mpvkit 的 `swift run` 会自己套一层 ⇒ 报 `sandbox_apply: Operation not permitted`
# （报错正文却是 `Invalid manifest`，见 docs/PITFALLS.md `P-024` / `P-027`）。
# mpvkit 的 Makefile 里没有插口，所以这里不调 `make`，而是**展开成等价的 swift 命令**并加上逃逸参数。
# 在正常终端里 probe 通过 ⇒ 数组为空 ⇒ 与 `make build platform=ios` 完全等价。
if sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1; then
  SWIFT_ESCAPE=()
else
  SWIFT_ESCAPE=(--disable-sandbox)
  echo "（受限 shell：swift run 将附加 --disable-sandbox）"
fi

cd "$SRC"
swift run "${SWIFT_ESCAPE[@]+"${SWIFT_ESCAPE[@]}"}" \
  --build-path ./.build \
  --package-path Sources/BuildScripts \
  build platform=ios

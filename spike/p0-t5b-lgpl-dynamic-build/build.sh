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

if git -C "$SRC" apply --check "$HERE/01-build-changes.patch" 2>/dev/null; then
  git -C "$SRC" apply "$HERE/01-build-changes.patch"
  echo "patch applied"
else
  echo "patch already applied, skip"
fi

if ! command -v wget >/dev/null 2>&1; then
  echo "wget is required by the build script"
  exit 1
fi

export HOMEBREW_NO_AUTO_UPDATE=1

cd "$SRC"
make build platform=ios

#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/tmp/p0t5b-build}"
SRC="$WORK/mpvkit/dist/release/xcframework/Libmpv.xcframework"
DEST="$HERE/MPV/Library/Libmpv.xcframework"

if [ ! -d "$SRC" ]; then
  printf '产物不存在：%s\n' "$SRC"
  printf '先跑构建：spike/p0-t5b-lgpl-dynamic-build/build.sh\n'
  exit 1
fi

mkdir -p "$HERE/MPV/Library"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

printf 'staged: %s\n' "$DEST"
du -sh "$DEST"
printf '切片：\n'
ls -d "$DEST"/*/ | sed 's|^|  |'

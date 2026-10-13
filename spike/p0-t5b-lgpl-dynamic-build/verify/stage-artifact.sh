#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/tmp/p0t5b-build}"
SRC="$WORK/mpvkit/dist/release/xcframework/Libmpv.xcframework"
DEST="$HERE/LocalLibmpv/Libmpv.xcframework"

if [ ! -d "$SRC" ]; then
  echo "not found: $SRC"
  echo "run ../build.sh first"
  exit 1
fi

rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "staged: $DEST"
du -sh "$DEST"
file "$DEST/ios-arm64/Libmpv.framework/Libmpv" | sed 's/.*: //'
otool -D "$DEST/ios-arm64/Libmpv.framework/Libmpv" | tail -1

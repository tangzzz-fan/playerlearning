#!/usr/bin/env bash
set -euo pipefail

WORK="${WORK:-/tmp/p0t5b-build}"
XCF="$WORK/mpvkit/dist/release/xcframework/Libmpv.xcframework"
NAME="Libmpv"

if [ ! -d "$XCF" ]; then
  echo "not found: $XCF"
  echo "run ./build.sh first"
  exit 1
fi

echo "=== slices ==="
ls -d "$XCF"/*/ 2>/dev/null

echo
echo "=== binary type per slice ==="
find "$XCF" -maxdepth 3 -type f -name "$NAME" | while read -r binary; do
  printf "%-70s " "$binary"
  file "$binary" | sed 's/.*: //'
done

echo
echo "=== install_name before ==="
find "$XCF" -maxdepth 3 -type f -name "$NAME" | while read -r binary; do
  printf "%-70s %s\n" "$binary" "$(otool -D "$binary" 2>/dev/null | tail -1)"
done

echo
echo "=== fixing install_name ==="
find "$XCF" -maxdepth 3 -type f -name "$NAME" | while read -r binary; do
  chmod u+w "$binary"
  install_name_tool -id "@rpath/$NAME.framework/$NAME" "$binary"
  echo "fixed: $binary"
done

echo
echo "=== install_name after ==="
find "$XCF" -maxdepth 3 -type f -name "$NAME" | while read -r binary; do
  printf "%-70s %s\n" "$binary" "$(otool -D "$binary" 2>/dev/null | tail -1)"
done

echo
echo "=== linked libraries (should be system-only) ==="
find "$XCF" -maxdepth 3 -type f -name "$NAME" | head -1 | while read -r binary; do
  otool -L "$binary"
done

echo
echo "=== license string ==="
find "$XCF" -maxdepth 3 -type f -name "$NAME" | head -1 | while read -r binary; do
  strings -a "$binary" | grep -iE "LGPL version|GPL version" | head -3
done

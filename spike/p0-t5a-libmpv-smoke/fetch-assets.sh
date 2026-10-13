#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$HERE/Resources"
BASE="https://cdn.jsdelivr.net/gh/mpvkit/video-test@master/resources"

mkdir -p "$DIR"

fetch() {
  local name="$1"
  local dest="$DIR/$name"
  if [ -f "$dest" ]; then
    echo "skip   $name (已存在)"
    return 0
  fi
  echo "fetch  $name"
  curl -fL --retry 3 --retry-delay 2 -o "$dest" "$BASE/$name"
}

fetch pgs_subtitle.mkv
fetch h265.mp4

echo
ls -lh "$DIR"

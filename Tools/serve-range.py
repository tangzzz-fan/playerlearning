#!/usr/bin/env python3
"""支持 HTTP Range 的极简静态服务器 —— 专供 `Phase 5` 网络点播验证。

## 为什么必须自己写一个

`python -m http.server` **不支持 Range 请求**（它连 `Accept-Ranges` 都不发）。
把这个局限当成"网络播放坏了"去改产品，是本末倒置 —— 实测日志给的原话：

    [mpv/demux] Stream is not seekable.
    [mpv/ffmpeg] Cannot seek backward in linear streams!
    [mpv/ffmpeg/demuxer] mov,mp4,...: stream 0, offset 0x30: partial file
    [mpv/lavf] EOF reached.
    [mpv/cplayer] got EOF with no data before it     ← 一个包都没读到就 "EOF"
    [mpv/cplayer] You can force it with '--force-seekable=yes'.

mp4 的索引（moov）需要**回退读取**；线性流不能后退 ⇒ 立即"EOF" ⇒ 界面显示"播完了"。
**真实的 CDN 都支持 Range**，所以这是**验证环境的能力缺口**，不是产品的缺陷。

## 用法

    python3 Tools/serve-range.py --port 8765 --root /path/to/videos

    # 另一个终端：
    xcrun simctl launch --console <udid> com.playerstack.demo \\
      -directURL http://127.0.0.1:8765/sintel_trailer-720p.mp4 -traceUpdates
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RANGE_PATTERN = re.compile(r"bytes=(\d*)-(\d*)")


class RangeHandler(BaseHTTPRequestHandler):
    root = "."

    def do_HEAD(self) -> None:  # noqa: N802  (BaseHTTPRequestHandler 的命名约定)
        self._respond(body=False)

    def do_GET(self) -> None:  # noqa: N802
        self._respond(body=True)

    def _respond(self, body: bool) -> None:
        path = os.path.join(self.root, self.path.lstrip("/").split("?")[0])
        if not os.path.isfile(path):
            self.send_error(404, "Not Found")
            return

        size = os.path.getsize(path)
        start, end = 0, size - 1
        partial = False

        raw_range = self.headers.get("Range")
        if raw_range:
            matched = RANGE_PATTERN.search(raw_range)
            if matched:
                first, last = matched.group(1), matched.group(2)
                if first:
                    start = int(first)
                    end = int(last) if last else size - 1
                elif last:  # `bytes=-500` = 最后 500 字节
                    start = max(0, size - int(last))
                # 越界就按整个文件回 —— 服务器有权忽略不合法的 Range。
                if start > end or start >= size:
                    start, end = 0, size - 1
                else:
                    end = min(end, size - 1)
                    partial = True

        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", self._content_type(path))
        # ⚠️ 就是这一行让 mp4 能播 —— 少了它，mpv 会把流当线性流，然后一个包都读不到。
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(length))
        self.end_headers()

        if body:
            with open(path, "rb") as handle:
                handle.seek(start)
                self.wfile.write(handle.read(length))

    @staticmethod
    def _content_type(path: str) -> str:
        if path.endswith(".mp4") or path.endswith(".m4v"):
            return "video/mp4"
        if path.endswith(".m3u8"):
            return "application/vnd.apple.mpegurl"
        if path.endswith(".ts"):
            return "video/mp2t"
        return "application/octet-stream"

    def log_message(self, fmt: str, *args: object) -> None:
        # 打上 Range 头，方便一眼看出"客户端到底有没有在 range 请求"。
        sys.stderr.write(f"[range] {self.address_string()} {fmt % args}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="支持 Range 的静态服务器（点播验证用）")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--root", default=".")
    options = parser.parse_args()

    RangeHandler.root = os.path.abspath(options.root)
    server = ThreadingHTTPServer(("127.0.0.1", options.port), RangeHandler)
    sys.stderr.write(f"[range] serving {RangeHandler.root} on http://127.0.0.1:{options.port}\n")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

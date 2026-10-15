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

## 三个"造环境"开关（验证用，产品代码不受影响）

| 开关 | 用途 |
| --- | --- |
| `--echo-headers` | 把每个请求收到的**请求头**打到 stderr —— 用来证明"自定义头真的到了服务器"（`P5-T4`），而不是只证明"我调过 setOption" |
| `--throttle BYTES/S` | 按字节限速 —— 造可控弱网（`G5`） |
| `--stall-at BYTES --stall-for SECONDS` | 发到第 N 字节后**挂住** SECONDS 秒再继续 —— 造"缓冲中 → 恢复后继续" |

⚠️ **为什么这些必须在这里做**：`G5` 判"弱网下不崩 + 有缓冲提示 + 恢复后自动继续"，
而**可控弱网本机没有**。照 `P-052`，在没有可控弱网时得出的任何"通过/不通过"都是
**把验证环境的能力缺口伪装成产品缺陷** —— 所以先把"能造弱网"补出来，再谈判定。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RANGE_PATTERN = re.compile(r"bytes=(\d*)-(\d*)")
CHUNK = 32 * 1024
NOISY_HEADERS = {"host", "connection", "accept", "accept-encoding", "accept-language"}


class RangeHandler(BaseHTTPRequestHandler):
    root = "."
    echo_headers = False
    throttle = 0
    stall_at = 0
    stall_for = 0.0
    stall_done = False

    def do_HEAD(self) -> None:  # noqa: N802  (BaseHTTPRequestHandler 的命名约定)
        self._respond(body=False)

    def do_GET(self) -> None:  # noqa: N802
        self._respond(body=True)

    def _respond(self, body: bool) -> None:
        path = os.path.join(self.root, self.path.lstrip("/").split("?")[0])
        if self.echo_headers:
            for name, value in self.headers.items():
                # 只滤掉每个请求都有的噪音，**其余全打** ——
                # 取证要的是"到底发了什么"，漏掉一个头就可能把结论搞反。
                if name.lower() not in NOISY_HEADERS:
                    sys.stderr.write(f"[header] {name}: {value}\n")
            sys.stderr.flush()
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
                self._write_paced(handle, start, length)

    def _write_paced(self, handle: object, start: int, length: int) -> None:
        """分块发送 —— 中途可以限速、可以挂住，用来造可控弱网。

        ⚠️ `stall_at` 是**绝对文件偏移**，不是"发出去多少字节"：
        Range 请求可能从中间开始（mp4 的 moov 回退读），用绝对偏移才和播放位置对得上。
        """
        sent = 0
        remaining = length
        while remaining > 0:
            take = min(CHUNK, remaining)
            absolute = start + sent
            if self.stall_at and not self.stall_done and absolute + take > self.stall_at:
                self.stall_done = True
                sys.stderr.write(
                    f"[net] 在偏移 {self.stall_at} 处挂住 {self.stall_for}s（造弱网）\n"
                )
                sys.stderr.flush()
                time.sleep(self.stall_for)
            self.wfile.write(handle.read(take))
            self.wfile.flush()
            sent += take
            remaining -= take
            if self.throttle:
                # 先发后睡：起播不至于"卡在第一个字节"，抖动更像真实弱网。
                time.sleep(take / self.throttle)

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
    parser = argparse.ArgumentParser(description="支持 Range 的静态服务器（点播 / 弱网验证用）")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--root", default=".")
    parser.add_argument("--echo-headers", action="store_true", help="把请求头打到 stderr（验请求头注入）")
    parser.add_argument("--throttle", type=int, default=0, help="限速，单位 字节/秒（0 = 不限）")
    parser.add_argument("--stall-at", type=int, default=0, help="在这个文件偏移处挂住（0 = 不挂）")
    parser.add_argument("--stall-for", type=float, default=0.0, help="挂住多少秒")
    options = parser.parse_args()

    RangeHandler.root = os.path.abspath(options.root)
    RangeHandler.echo_headers = options.echo_headers
    RangeHandler.throttle = options.throttle
    RangeHandler.stall_at = options.stall_at
    RangeHandler.stall_for = options.stall_for
    server = ThreadingHTTPServer(("127.0.0.1", options.port), RangeHandler)
    sys.stderr.write(
        f"[range] serving {RangeHandler.root} on http://127.0.0.1:{options.port}"
        f" · throttle={options.throttle} B/s · stall@{options.stall_at} for {options.stall_for}s"
        f" · echo_headers={options.echo_headers}\n"
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

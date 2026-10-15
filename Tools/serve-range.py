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

    # **真机**（手机在另一台设备上，回环到不了它 ⇒ 必须绑 0.0.0.0 + 用宿主机的局域网地址）：
    python3 Tools/serve-range.py --port 8765 --root /tmp/vidprobe2 --host 0.0.0.0 --throttle 400000
    xcrun devicectl device process launch --device <真机 UDID> --console \\
      --terminate-existing com.playerstack.demo -- -directURL http://192.168.x.x:8765/… -traceUpdates

## 四个"造环境"开关（验证用，产品代码不受影响）

| 开关 | 用途 |
| --- | --- |
| `--echo-headers` | 把每个请求收到的**请求头**打到 stderr —— 用来证明"自定义头真的到了服务器"（`P5-T4`），而不是只证明"我调过 setOption" |
| `--throttle BYTES/S` | 按字节限速 —— 造可控弱网（`G5`） |
| `--stall-at BYTES --stall-for SECONDS` | 发到第 N 字节后**挂住** SECONDS 秒再继续 —— 造"缓冲中 → 恢复后继续" |
| `--tls-cert PEM --tls-key PEM` | 用 TLS 起服务（HTTPS）—— 验产品的 **TLS 信任路径**（`P0-T5c`） |

⚠️ **为什么这些必须在这里做**：`G5` 判"弱网下不崩 + 有缓冲提示 + 恢复后自动继续"，
而**可控弱网本机没有**。照 `P-052`，在没有可控弱网时得出的任何"通过/不通过"都是
**把验证环境的能力缺口伪装成产品缺陷** —— 所以先把"能造弱网"补出来，再谈判定。

### 为什么需要 TLS 开关（`P0-T5c`）

`docs/07` 把「TLS 后端从 gnutls 换成 **SecureTransport**」标成**本次唯一带风险的替换**，
而那一轮**只验了"协议已启用"**，没跑过真实 HTTPS 流（`docs/07` L161）。本开关就是为它补的环境。

**为什么要自签而不是随便找个公网 HTTPS 站点**：SecureTransport = **Apple 系统 TLS** ⇒
信任判断走 **iOS 系统信任库**。要验的恰恰是"**校验到底有没有在生效**"，
而公网站点的证书**本来就受信任**，只能证"能播"，证不了"不受信任时会拒"。
自签能一次把两件事都钉死（不信任必须失败 / 装了 CA 必须成功），
再配合"把 CA 去掉又失败"就能**闭合因果**。

⚠️ 自签证书是**一次性环境**（放 `/tmp`，不入仓库）。证书本身要满足 Apple 的门槛：
SAN 必填、`extendedKeyUsage=serverAuth`、RSA ≥2048、有效期 ≤825 天 ——
少一条会得到"看起来像校验失败、其实是证书不合规"的**另一种失败**。
"""

from __future__ import annotations

import argparse
import os
import re
import ssl
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

    # ⚠️ **把"客户端主动断开"从"服务端故障"里分出来。**
    #
    # HLS 场景下这几乎是**常态**：mpv/lavf 会**预读若干个分片**、解析出自己需要的部分后就
    # 丢掉不再用的连接（`seek` / 换清晰度更会整批重来）。此时服务端还在 paced 写 ⇒ `EPIPE`。
    # 它**不是故障**，但 `socketserver` 默认会为它打**一整段 traceback**
    # （`Exception occurred during processing of request from …` + 堆栈）。
    #
    # ⇒ 噪音一多，**真**错误就被埋了 —— 同 `P-058` 的形态：取证通道自己先吵起来。
    # 判据：**"客户端提前断开"是流媒体的常态**；要判"是不是故障"，看**客户端有没有拿到它要的东西**，
    # 而不是看服务端有没有报错。
    _logged_client_gone = False

    def handle_one_request(self) -> None:  # noqa: N802  (父类的命名约定)
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self._note_client_gone()

    def finish(self) -> None:
        # 收尾时 `flush` 也会撞上已经断掉的连接，同样降级（不覆写就会漏出去变成 traceback）。
        try:
            super().finish()
        except (BrokenPipeError, ConnectionResetError):
            self._note_client_gone()

    def _note_client_gone(self) -> None:
        self.close_connection = True
        if self._logged_client_gone:
            return
        self._logged_client_gone = True
        command = getattr(self, "command", None) or "-"
        path = getattr(self, "path", None) or "-"
        sys.stderr.write(
            f"[net] 客户端提前断开：{command} {path} —— 正常（播放器预读后丢弃连接），非故障\n"
        )
        sys.stderr.flush()

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


class TLSServer(ThreadingHTTPServer):
    """`ThreadingHTTPServer` + **把 TLS 握手失败记成一行服务端证据**。

    为什么非记不可：客户端**拒绝我们的证书**时，异常在**服务端这一侧**就以
    `tlsv1 alert unknown ca` 的形式出现 —— 这是"客户端**确实做了校验并拒绝**"的直接证据。
    只看客户端那边"没收货"是不够的：那与"压根没连上 / 路径写错"**看起来一模一样**
    （同 `P-056` 的判据：不同病因会给出同一个症状，就先去找能把它们分开的那条证据）。
    """

    def get_request(self):  # type: ignore[no-untyped-def]
        try:
            return super().get_request()
        except (ssl.SSLError, OSError) as exc:
            sys.stderr.write(f"[tls] 握手失败：{exc}\n")
            sys.stderr.flush()
            raise

    def handle_error(self, request, client_address):  # type: ignore[no-untyped-def]
        # TLS 失败上面已经记过了 ⇒ 不再叠一整段 traceback：
        # 噪音会把结论埋掉（`P-058` 的形态：取证通道自己先吵起来）。
        if isinstance(sys.exc_info()[1], ssl.SSLError):
            return
        super().handle_error(request, client_address)


def main() -> int:
    parser = argparse.ArgumentParser(description="支持 Range 的静态服务器（点播 / 弱网 / TLS 验证用）")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--root", default=".")
    # ⚠️ 默认只听回环（模拟器用 `127.0.0.1` 就够）。**真机必须 `--host 0.0.0.0`**：
    #    手机在另一台设备上，回环地址到不了它 —— 而"真机弱网"正是 `G5` 唯一能落到实处的形态。
    parser.add_argument("--host", default="127.0.0.1", help="绑定地址（真机验证用 0.0.0.0）")
    parser.add_argument("--echo-headers", action="store_true", help="把请求头打到 stderr（验请求头注入）")
    parser.add_argument("--throttle", type=int, default=0, help="限速，单位 字节/秒（0 = 不限）")
    parser.add_argument("--stall-at", type=int, default=0, help="在这个文件偏移处挂住（0 = 不挂）")
    parser.add_argument("--stall-for", type=float, default=0.0, help="挂住多少秒")
    parser.add_argument("--tls-cert", help="PEM 证书链；给了它就起 HTTPS（`P0-T5c`）")
    parser.add_argument("--tls-key", help="PEM 私钥；必须与 --tls-cert 成对出现")
    options = parser.parse_args()

    if bool(options.tls_cert) != bool(options.tls_key):
        parser.error("--tls-cert 与 --tls-key 必须成对给出（只给一半会静默退回明文，那比报错更坏）")

    RangeHandler.root = os.path.abspath(options.root)
    RangeHandler.echo_headers = options.echo_headers
    RangeHandler.throttle = options.throttle
    RangeHandler.stall_at = options.stall_at
    RangeHandler.stall_for = options.stall_for
    server = TLSServer((options.host, options.port), RangeHandler)

    scheme = "http"
    if options.tls_cert and options.tls_key:
        # 包的是**监听 socket**：此后 accept 出来的连接都完成过握手。
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=options.tls_cert, keyfile=options.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"

    sys.stderr.write(
        f"[range] serving {RangeHandler.root} on {scheme}://{options.host}:{options.port}"
        f" · throttle={options.throttle} B/s · stall@{options.stall_at} for {options.stall_for}s"
        f" · echo_headers={options.echo_headers}\n"
    )
    if scheme == "https":
        # 这条提示是刻意的：客户端**必须先在信任库里认这份 CA**，否则连不上（那正是要验的反向）。
        sys.stderr.write(
            "[tls] 客户端要先用 `xcrun simctl keychain <udid> add-root-cert <ca.crt>` 信任签发者\n"
        )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

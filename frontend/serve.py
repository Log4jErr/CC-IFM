#!/usr/bin/env python3
# IFM :: frontend/serve.py —— 本地静态服务器（1.5.0 抢救后重写版）
#
# 用途：在 PC 上把 frontend/ 目录用 HTTP 提供出来，浏览器打开 index.html 即可用网页操作 IFM。
#   python serve.py                 # 默认端口 8000
#   python serve.py --port 8080
#   python serve.py --room myroom   # 只影响打印出来的示例 URL（页面里仍可自己填房间号）
#   python serve.py --relay ws://192.168.1.10:8765/c/
#
# 不做目录列表、不压缩，只按 MIME 类型返回文件，并强制 no-store（改前端后刷新即可见）。

import argparse
import functools
import http.server
import os
import socket
import socketserver
import sys

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = dict(http.server.SimpleHTTPRequestHandler.extensions_map)
    extensions_map.update({
        ".js": "application/javascript; charset=utf-8",
        ".mjs": "application/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".html": "text/html; charset=utf-8",
        ".svg": "image/svg+xml",
        ".png": "image/png",
        ".wasm": "application/wasm",
    })

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stdout.write("[serve] %s\n" % (fmt % args))
        sys.stdout.flush()


def local_ips():
    ips = []
    try:
        host = socket.gethostname()
        for info in socket.getaddrinfo(host, None):
            addr = info[4][0]
            if ":" not in addr and addr not in ips:
                ips.append(addr)
    except OSError:
        pass
    return ips


def main():
    parser = argparse.ArgumentParser(description="IFM web client local server")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--room", default="")
    parser.add_argument("--relay", default="")
    args = parser.parse_args()

    handler = functools.partial(Handler, directory=BASE_DIR)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((args.host, args.port), handler) as httpd:
        print("IFM web client: serving %s" % BASE_DIR)
        print("  local : http://localhost:%d/index.html" % args.port)
        for ip in local_ips():
            print("  lan   : http://%s:%d/index.html" % (ip, args.port))
        if args.room or args.relay:
            query = []
            if args.room:
                query.append("room=" + args.room)
            if args.relay:
                query.append("relay=" + args.relay)
            print("  example url: http://localhost:%d/index.html?%s" % (args.port, "&".join(query)))
        print("Ctrl+C stops the server.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")


if __name__ == "__main__":
    main()

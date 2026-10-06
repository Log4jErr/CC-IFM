#!/usr/bin/env python3

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

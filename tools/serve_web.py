#!/usr/bin/env python3
"""Serve the page the web build makes.

    make web
    tools/serve_web.py           # http://127.0.0.1:8000
    tools/serve_web.py 9000 --any-host

A browser will not run a WebAssembly module off a file:// path, so the
page needs a server even to be looked at on the machine that built it.
This is that server and nothing else: it serves web/build, it names
.wasm and .data the way a browser needs them named, and it does not
cache, so a rebuild is one reload away.

By default it listens on the loopback address only. --any-host listens
on every address, which is how a phone on the same network reaches it:
find the machine's address and open http://<address>:8000 on the phone.
"""

import argparse
import http.server
import mimetypes
import os
import socketserver

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web", "build")

# A browser refuses a module served as anything but application/wasm.
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/octet-stream", ".data")
mimetypes.add_type("application/manifest+json", ".webmanifest")


class Handler(http.server.SimpleHTTPRequestHandler):
	def __init__(self, *args, **kwargs):
		super().__init__(*args, directory=ROOT, **kwargs)

	def end_headers(self):
		self.send_header("Cache-Control", "no-store")
		super().end_headers()


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("port", nargs="?", type=int, default=8000)
	parser.add_argument("--any-host", action="store_true", help="listen on every address, for a phone on the same network")
	args = parser.parse_args()

	if not os.path.isdir(ROOT):
		raise SystemExit(f"{ROOT} is not there: run `make web` first")

	host = "0.0.0.0" if args.any_host else "127.0.0.1"
	socketserver.TCPServer.allow_reuse_address = True
	with socketserver.TCPServer((host, args.port), Handler) as server:
		print(f"serving {ROOT} on http://{host}:{args.port}")
		server.serve_forever()


if __name__ == "__main__":
	main()

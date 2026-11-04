#!/usr/bin/env python3
"""A tiny stand-in for an Antresol server, for UI screenshot runs in CI.

Serves the recorded API samples from AntresolKit/Tests/AntresolKitTests/Samples and
generates gradient PNGs for every /api/images/ path, so the app can be driven through
onboarding, the profile picker and Home without a real library.

    python3 scripts/mock-server.py --port 8421
"""
import argparse
import hashlib
import json
import re
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SAMPLES = Path(__file__).resolve().parent.parent / "AntresolKit/Tests/AntresolKitTests/Samples"

ROUTES = {
    ("GET", r"/api/health"): "health.json",
    ("GET", r"/api/setup"): "setup-get.json",
    ("GET", r"/api/profiles"): "profiles.json",
    ("POST", r"/api/auth/token"): "auth-token.json",
    ("POST", r"/api/auth/media-key"): "auth-media-key.json",
    ("GET", r"/api/me"): "me.json",
    ("GET", r"/api/home"): "home.json",
    ("GET", r"/api/items/2"): "item-series.json",
    ("GET", r"/api/items/\d+"): "item-movie.json",
    ("GET", r"/api/items"): "items-movies.json",
    ("GET", r"/api/search"): "search.json",
    ("GET", r"/api/music/home"): "music-home.json",
    ("GET", r"/api/books/home"): "books-home.json",
}


def png(width, height, top, bottom):
    """A vertical two-colour gradient as PNG bytes."""
    rows = bytearray()
    for y in range(height):
        t = y / max(height - 1, 1)
        pixel = bytes(round(a + (b - a) * t) for a, b in zip(top, bottom))
        rows += b"\x00" + pixel * width
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")


_images = {}


def image_for(path):
    if path not in _images:
        digest = hashlib.sha1(path.encode()).digest()
        top = (digest[0], digest[1] // 2, digest[2])
        bottom = (digest[3] // 4, digest[4] // 4, digest[5] // 3)
        size = (960, 540) if path.endswith("backdrop") else (400, 600)
        _images[path] = png(*size, top, bottom)
    return _images[path]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        path = self.path.split("?", 1)[0]
        if method == "GET" and path.startswith("/api/images/"):
            return self.send(200, image_for(path), "image/png")
        if method == "POST" and path == "/api/logout":
            return self.send(204, b"", "application/json")
        for (verb, pattern), sample in ROUTES.items():
            if verb == method and re.fullmatch(pattern, path):
                return self.send(200, (SAMPLES / sample).read_bytes(), "application/json")
        self.send(404, json.dumps({"error": "Not found"}).encode(), "application/json")

    def send(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8421)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

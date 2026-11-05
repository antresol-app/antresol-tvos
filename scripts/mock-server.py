#!/usr/bin/env python3
"""A tiny stand-in for an Antresol server, for UI screenshot runs in CI.

Serves the recorded API samples from AntresolKit/Tests/AntresolKitTests/Samples,
generates gradient PNGs for every /api/images/ path and comic page, and streams small
fixture clips for video, music and audiobooks, so the app can be driven through every
screen without a real library.

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
FIXTURES = Path(__file__).resolve().parent / "fixtures"
VIDEO = FIXTURES / "sample.mp4"
TRACK = FIXTURES / "track.m4a"
AUDIOBOOK = FIXTURES / "audiobook.m4a"

ROUTES = {
    ("GET", r"/api/health"): "health.json",
    ("GET", r"/api/setup"): "setup-get.json",
    ("GET", r"/api/profiles"): "profiles.json",
    ("POST", r"/api/auth/token"): "auth-token.json",
    ("POST", r"/api/auth/media-key"): "auth-media-key.json",
    ("GET", r"/api/me"): "me.json",
    ("GET", r"/api/home"): "home.json",
    ("GET", r"/api/items/2"): "item-series.json",
    ("GET", r"/api/items/(3|11)"): "item-season.json",
    ("GET", r"/api/items/(4|5|12)"): "item-episode.json",
    ("GET", r"/api/items/\d+"): "item-movie.json",
    ("GET", r"/api/items"): "items-movies.json",
    ("GET", r"/api/progress/\d+"): "progress-get.json",
    ("GET", r"/api/search"): "search.json",
    ("GET", r"/api/music/home"): "music-home.json",
    ("GET", r"/api/music/albums/\d+"): "music-album.json",
    ("GET", r"/api/music/albums"): "music-albums.json",
    ("GET", r"/api/music/artists/\d+"): "music-artist.json",
    ("GET", r"/api/music/artists"): "music-artists.json",
    ("GET", r"/api/music/songs"): "music-songs.json",
    ("GET", r"/api/music/genres"): "music-genres.json",
    ("GET", r"/api/music/shuffle"): "music-shuffle.json",
    ("GET", r"/api/music/tracks/\d+/lyrics"): "music-lyrics.json",
    ("GET", r"/api/music/tracks/\d+"): "music-track.json",
    ("GET", r"/api/music/playlists/\d+"): "playlist.json",
    ("GET", r"/api/music/playlists"): "playlists.json",
    ("GET", r"/api/books/home"): "books-home.json",
    ("GET", r"/api/books/20"): "book-comic.json",
    ("GET", r"/api/books/21"): "book-comic-volume.json",
    ("GET", r"/api/books/23"): "book-audiobook-multifile.json",
    ("GET", r"/api/books/\d+"): "book-audiobook.json",
    ("GET", r"/api/comics/\d+/pages"): "comic-pages.json",
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


def comic_page(index):
    """A portrait page with its own colours."""
    palette = [((220, 70, 60), (40, 10, 10)), ((60, 140, 220), (10, 20, 50)), ((90, 200, 120), (10, 40, 20))]
    top, bottom = palette[index % len(palette)]
    key = f"comic-{index}"
    if key not in _images:
        _images[key] = png(800, 1200, top, bottom)
    return _images[key]


def play_response(file_id):
    """Direct play of the fixture clip, with the tracks of the sample movie or episode."""
    sample = "item-episode.json" if file_id == 2 else "item-movie.json"
    file = json.loads((SAMPLES / sample).read_text())["files"][0]
    return {
        "mode": "direct",
        "url": f"/api/stream/{file_id}",
        "reason": "",
        "startSec": 0,
        "durationMs": file.get("durationMs") or 60000,
        "audioIndex": 1,
        "audio": file.get("audio", []),
        "subtitles": file.get("subs", []),
        "quality": {"selected": "auto", "applied": "original", "remote": False},
    }


def subtitles():
    lines = ["WEBVTT", ""]
    for n in range(15):
        start, end = n * 4, n * 4 + 3.5
        lines += [f"00:{start:02d}.000 --> 00:{int(end):02d}.500", f"Subtitle line {n + 1}", ""]
    return "\n".join(lines).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # The client's User-Agent tells the app's requests from the Top Shelf extension's.
        agent = self.headers.get("User-Agent", "-") if hasattr(self, "headers") else "-"
        super().log_message(format + " [%s]", *args, agent)

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
        path, _, query = self.path.partition("?")
        if method == "GET" and path.startswith("/api/images/"):
            return self.send(200, image_for(path), "image/png")
        if method == "POST" and path == "/api/logout":
            return self.send(204, b"", "application/json")
        if method in ("POST", "DELETE") and re.fullmatch(r"/api/(watchlist/\d+|items/\d+/watched)", path):
            return self.send(204, b"", "application/json")
        if method == "PUT" and re.fullmatch(r"/api/progress/\d+", path):
            return self.send(204, b"", "application/json")
        if method == "POST" and re.fullmatch(r"/api/play/\d+", path):
            return self.send(200, json.dumps(play_response(int(path.rsplit("/", 1)[1]))).encode(), "application/json")
        if method == "GET" and re.fullmatch(r"/api/stream/\d+", path):
            return self.send_file(VIDEO, "video/mp4")
        if method == "GET" and re.fullmatch(r"/api/tracks/\d+/stream", path):
            return self.send_file(TRACK, "audio/mp4")
        if method == "GET" and re.fullmatch(r"/api/audio/\d+", path):
            return self.send_file(AUDIOBOOK, "audio/mp4")
        if method == "GET" and re.fullmatch(r"/api/comics/\d+/page/\d+", path):
            return self.send(200, comic_page(int(path.rsplit("/", 1)[1])), "image/png")
        if method in ("POST", "DELETE") and re.fullmatch(r"/api/music/(plays|star/\d+)", path):
            return self.send(204, b"", "application/json")
        if method == "GET" and path == "/api/books":
            kind = re.search(r"kind=(\w+)", query)
            sample = {"audiobook": "books-audiobooks.json", "comic": "books-comics.json"}.get(kind.group(1) if kind else "")
            body = (SAMPLES / sample).read_bytes() if sample else json.dumps({"items": [], "total": 0}).encode()
            return self.send(200, body, "application/json")
        if method == "GET" and re.fullmatch(r"/api/subs/\d+/\d+\.vtt", path):
            return self.send(200, subtitles(), "text/vtt; charset=utf-8")
        if method in ("PUT", "DELETE") and path.startswith("/api/hls/"):
            return self.send(204, b"", "application/json")
        if method == "GET" and path == "/api/items" and "kind=series" in query:
            return self.send(200, (SAMPLES / "items-series.json").read_bytes(), "application/json")
        for (verb, pattern), sample in ROUTES.items():
            if verb == method and re.fullmatch(pattern, path):
                return self.send(200, (SAMPLES / sample).read_bytes(), "application/json")
        self.send(404, json.dumps({"error": "Not found"}).encode(), "application/json")

    def send_file(self, file, content_type):
        """A fixture file with Range support, as the server serves original files."""
        data = file.read_bytes()
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        if not match:
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        start = int(match.group(1) or 0)
        end = min(int(match.group(2) or len(data) - 1), len(data) - 1)
        chunk = data[start:end + 1]
        self.send_response(206)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.send_header("Content-Length", str(len(chunk)))
        self.end_headers()
        self.wfile.write(chunk)

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

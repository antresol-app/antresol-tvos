#!/usr/bin/env python3
"""A tiny stand-in for an Antresol server, for UI screenshot runs in CI.

Serves the recorded API samples from AntresolKit/Tests/AntresolKitTests/Samples,
generates gradient PNGs for every /api/images/ path and comic page, and streams small
fixture clips for video, music and audiobooks, so the app can be driven through every
screen without a real library. Every channel plays one short live stream (the first
seconds of the video fixture, looped, with three audio renditions).

    python3 scripts/mock-server.py --port 8421

The next port (8422) is the same server with QR sign-in (`/api/auth/pair/…`): the app
shows its sign-in code there, and the profile picker on the main port, as the screenshot
tests expect. There the channel list is long (24 channels, the last one watched is the
18th) and the third song of the sample album is one the server transcodes (no
ranges, `X-Vault-Transcode: 1`), and it is slow to answer the app's own question about it.
Its guide has twelve rows and then three external channels, two of them from one guide
source with programmes at the same instants (so with the same programme ids, as the
server builds them: `x<guide>-<start ms>`), and its Continue Watching ends with a series.
Its channels keep their stars (`PUT`/`DELETE /api/channels/<id>/favorite`) and «Избранные
каналы первыми» (`GET`/`PUT /api/channels/prefs`, on to start with): the list and the guide
come favourites first, as the server orders them; channel 2's logo does not load (its guide
icon `logoAlt` shows), channel 4 has only the guide icon.

The second port also keeps what it was asked, for the UI tests (never on the main port):

    GET  /mock/events              the requests so far (time, method, path, query, client;
                                   `positionMs` of a progress write, `answered` of the slow one)
    POST /mock/reset               forgets them, and the failures still armed
    POST /mock/external-audio      the channel list gets two external channels (200, 201) until
                                   the next reset: 200 says its audio is one an Apple device
                                   cannot decode and offers the server's relay of it, 201 offers
                                   a relay too but does not say. Both play the live clip, from
                                   `/provider/<id>/…` (the provider's own address) or
                                   `/api/channels/live/ext/<id>/0/relay/…` (the relay, which asks
                                   for the media key and carries it into every link of its
                                   playlists, as the server does)
    POST /mock/fail-progress/<id>  the next `GET /api/progress/<id>` answers 503, once

«Отдельная история на этом устройстве»: `GET`/`POST /api/me/managed` and
`PUT /api/me/devices/current/history` answer as the server does on both ports, kept per port for
the run (one history, «Living Room», to start with; the kid's writes answer 403), and `/api/me`
carries the device's `deviceHistory`. The second port's profile picker has a third, passwordless
adult profile («Family») to switch it with; while it is on, Home's Continue Watching is another
one (the device's own), and `/mock/reset` puts it back.

`--channels N` gives the main port's channel list N channels (the sample's four, cut short or
continued with copies), for screenshots of a short or a long list.

With `--addons` both ports also serve the addons' `x/app` protocol (two neutral addons, `alpha`
and `beta`; kids get 403) and the core's input player, for the screens that offer an addon's
ways. The second port records those requests with their bodies, as it does the others.

With `--requests` the kid profile may ask a parent for what the library lacks (`canRequest`): the
kid's `GET /api/requests/search` (movies and shows as `video`, one album as `music`), `POST /api/requests`
and `GET /api/requests/mine`, and the title pages of those titles carry the kid's request of them.
Three requests are answered to start with (waiting, approved, declined with a reason); on the second
port `POST /mock/decide/<id>/<status>?reason=` answers one, as a parent would, until the next reset.

With `--family` the other profiles of the family have places in some titles (`GET /api/items/{id}/family`, as the web
and the apps read it; a kid gets nobody): the film 19 (four profiles: a film's 34 minutes of 1 h 50 min, one finished, one
in a device's account), the short clip 22 (positions inside its 60 s, to play from), the series 2 and its episodes 4, 5, 12, and the film 23
(a long title, profile names of 40+ characters: nothing in the list may be cut).
`POST /api/progress/{id}/adopt` copies a profile's unfinished position into the caller's own (the second port keeps its
body, `{"userId": N}`), and `GET /api/progress/{id}` answers that copy until the next `/mock/reset`.
For the resume prompt: the film 30 (the viewer has no progress of their own; one profile is at 1:12:40), the film 31 (the
viewer is at 34:10; three profiles with a place, one of them 20 s from the viewer's, one finished) and the film 33 (as 31,
but adopt answers 404); the series 2's episodes carry `seriesId` 2 and the series fixture places a profile in its episode 5.

Its play answers carry skip segments: the film (file 12) an intro at 0:18–0:30 and credits
running to its end from 0:44, the episode (file 2, a 60 s file there) credits from 0:18;
`PUT /api/me/playback-prefs/auto-skip` is kept (the event has its `body`) and the playback
prefs answer with it, until `/mock/reset`.
"""
import argparse
import datetime
import hashlib
import json
import re
import struct
import sys
import threading
import time
import urllib.parse
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SAMPLES = Path(__file__).resolve().parent.parent / "AntresolKit/Tests/AntresolKitTests/Samples"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
VIDEO = FIXTURES / "sample.mp4"
TRACK = FIXTURES / "track.m4a"
AUDIOBOOK = FIXTURES / "audiobook.m4a"
# `ffmpeg -i track.m4a -c copy -f adts track.aac`: a stream that plays without ranges.
TRANSCODED_TRACK = 17
TRANSCODED = FIXTURES / "track.aac"
# `ffmpeg -i sample.mp4 -t 12 -map 0:v -c copy -f hls -hls_time 4 …` and the same with 0:a.
LIVE = FIXTURES / "live"
LIVE_SEGMENTS = 3
LIVE_SEGMENT_SECONDS = 4
# The voices of the sample programme on channel 1 (`now.audio[].name`).
LIVE_AUDIO = [("Русский", "ru"), ("English", "en"), ("Оригинал", "fr")]

KID_TOKEN = "mock-kid-token"
KID_USER = {"id": 2, "name": "Kiddo", "avatar": "grad-4", "photo": "/api/profiles/2/photo?v=1763500000", "hasPassword": False, "isAdmin": False,
            "isKid": True, "maxRating": "PG", "remote": False, "libraryOnly": True}


def kid_user(server):
    """The kid profile; with `--requests` it may ask a parent for titles."""
    return dict(KID_USER, canRequest=True) if getattr(server, "requests", False) else KID_USER

# The second port's passwordless adult profile, for «Отдельная история на этом устройстве».
FAMILY_TOKEN = "mock-family-token"
FAMILY_USER = {"id": 3, "name": "Family", "avatar": "grad-6", "hasPassword": False, "isAdmin": False,
               "isKid": False, "remote": False, "libraryOnly": True}


def new_history_state():
    return {"accounts": [{"id": 20, "name": "Living Room", "avatar": "grad-2"}], "next": 21, "current": None, "kept": None}


def history_ref(state):
    found = next((a for a in state["accounts"] if a["id"] == state["current"]), None)
    return {"id": found["id"], "name": found["name"]} if found else None


def managed_request(state, method, path, body, kid):
    """(status, json) of the separate-history endpoints, None for other paths."""
    if path == "/api/me/managed" and method == "GET":
        return 200, {"items": [dict(a, devices=[{"id": 1, "kind": "native", "name": "Apple TV", "model": "AppleTV14,1"}]
                                    if a["id"] == state["current"] else []) for a in state["accounts"]]}
    if path not in ("/api/me/managed", "/api/me/devices/current/history"):
        return None
    if kid:
        return 403, {"error": "Only an administrator can change this"}
    if path == "/api/me/managed" and method == "POST":
        name = str(body.get("name", "")).strip()
        if not name:
            return 400, {"error": "Enter a name"}
        account = {"id": state["next"], "name": name, "avatar": "grad-3"}
        state["next"] += 1
        state["accounts"].append(account)
        return 201, dict(account, devices=[])
    if path == "/api/me/devices/current/history" and method == "PUT":
        if body.get("separate"):
            wanted = body.get("accountId") or state["kept"]
            if wanted and not any(a["id"] == wanted for a in state["accounts"]):
                return 404, {"error": "No such history"}
            if not wanted:
                wanted = state["next"]
                state["next"] += 1
                state["accounts"].append({"id": wanted, "name": "Apple TV", "avatar": "grad-3"})
            state["current"] = wanted
        else:
            was, state["current"] = state["current"], None
            if body.get("merge") and was:
                state["accounts"] = [a for a in state["accounts"] if a["id"] != was]
                state["kept"] = None
            else:
                state["kept"] = was
        return 200, {"id": 1, "history": history_ref(state)}
    return None


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
    ("GET", r"/api/books/home"): "books-home.json",
}


class Library:
    """Playlists that the app can change, kept in memory."""

    def __init__(self):
        detail = json.loads((SAMPLES / "playlist.json").read_text())
        self.tracks = {}
        for sample, key in (("music-songs.json", "items"), ("music-album.json", "tracks"), ("playlist.json", "tracks")):
            for track in json.loads((SAMPLES / sample).read_text())[key]:
                track.pop("idx", None)
                self.tracks[track["id"]] = track
        self.playlists = {detail["playlist"]["id"]: {"playlist": detail["playlist"], "tracks": [t["id"] for t in detail["tracks"]]}}
        self.next_playlist = max(self.playlists) + 1

    def summary(self, playlist_id):
        entry = self.playlists[playlist_id]
        tracks = [self.tracks[i] for i in entry["tracks"] if i in self.tracks]
        covers = list(dict.fromkeys(t["cover"] for t in tracks if t.get("cover")))[:4]
        entry["playlist"].update(trackCount=len(tracks), durationMs=sum(t.get("durationMs", 0) for t in tracks),
                                 cover=covers[0] if covers else "", covers=covers)
        return entry["playlist"]

    def detail(self, playlist_id):
        tracks = [dict(self.tracks[i], idx=n) for n, i in enumerate(self.playlists[playlist_id]["tracks"]) if i in self.tracks]
        return {"playlist": self.summary(playlist_id), "tracks": tracks}

    def handle(self, method, path, body):
        """(status, json) for a playlist request, or None for other paths."""
        if path == "/api/music/playlists":
            if method == "GET":
                return 200, {"items": [self.summary(i) for i in sorted(self.playlists)]}
            if method == "POST":
                name = (body.get("name") or "").strip()
                if not name:
                    return 400, {"error": "Enter a playlist name"}
                playlist_id = self.next_playlist
                self.next_playlist += 1
                self.playlists[playlist_id] = {"playlist": {"id": playlist_id, "name": name, "updatedAt": "2026-11-05T12:00:00Z"},
                                               "tracks": list(body.get("trackIds") or [])}
                return 200, self.summary(playlist_id)
        match = re.fullmatch(r"/api/music/playlists/(\d+)", path)
        if match:
            playlist_id = int(match.group(1))
            if playlist_id not in self.playlists:
                return 404, {"error": "Playlist not found"}
            entry = self.playlists[playlist_id]
            if method == "GET":
                return 200, self.detail(playlist_id)
            if method == "DELETE":
                del self.playlists[playlist_id]
                return 204, None
            if method == "PATCH":
                if "name" in body:
                    name = (body.get("name") or "").strip()
                    if not name:
                        return 400, {"error": "Enter a playlist name"}
                    entry["playlist"]["name"] = name
                tracks = entry["tracks"]
                if body.get("remove"):
                    tracks = [t for n, t in enumerate(tracks) if n not in set(body["remove"])]
                if body.get("order") and sorted(body["order"]) == list(range(len(tracks))):
                    tracks = [tracks[n] for n in body["order"]]
                entry["tracks"] = tracks + list(body.get("append") or [])
                return 200, self.summary(playlist_id)
        return None


LIBRARY = Library()


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
        size = (960, 540) if path.endswith("backdrop") or "/frame/" in path else (400, 600)
        _images[path] = png(*size, top, bottom)
    return _images[path]


def profile_photo():
    """Kiddo's profile photo: a smiling face on a sky gradient, nothing a letter avatar
    could be taken for."""
    if "profile-photo" not in _images:
        n = 128
        rows = bytearray()
        for y in range(n):
            rows += b"\x00"
            for x in range(n):
                face = (x - 64) ** 2 + (y - 70) ** 2 <= 40 ** 2
                eye = (x - 50) ** 2 + (y - 58) ** 2 <= 30 or (x - 78) ** 2 + (y - 58) ** 2 <= 30
                mouth = 20 ** 2 <= (x - 64) ** 2 + (y - 70) ** 2 <= 24 ** 2 and y > 78
                rows += b"\x30\x20\x20" if face and (eye or mouth) else b"\xf4\xc8\x9a" if face else bytes((70 + y // 2, 130 + y // 3, 220))
        def chunk(kind, data):
            body = kind + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        header = struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0)
        _images["profile-photo"] = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")
    return _images["profile-photo"]


def comic_page(index):
    """A portrait page with its own colours."""
    palette = [((220, 70, 60), (40, 10, 10)), ((60, 140, 220), (10, 20, 50)), ((90, 200, 120), (10, 40, 20))]
    top, bottom = palette[index % len(palette)]
    key = f"comic-{index}"
    if key not in _images:
        _images[key] = png(800, 1200, top, bottom)
    return _images[key]


# The second port's skip segments (file seconds) of the film and the episode.
SEGMENTS = {
    12: [{"kind": "intro", "startSec": 18, "endSec": 30}, {"kind": "credits", "startSec": 44, "endSec": 59.5}],
    2: [{"kind": "credits", "startSec": 18, "endSec": 59.5}],
}


def play_response(file_id, segments=False):
    """Direct play of the fixture clip, with the tracks of the sample movie or episode
    (and, on the second port, its skip segments)."""
    sample = "item-episode.json" if file_id == 2 else "item-movie.json"
    file = json.loads((SAMPLES / sample).read_text())["files"][0]
    answer = {
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
    if segments:
        answer["segments"] = SEGMENTS.get(file_id, [])
        # The episode plays the whole 60 s fixture there, so its credits can count down.
        answer["durationMs"] = 60046
    return answer


def subtitles():
    lines = ["WEBVTT", ""]
    for n in range(15):
        start, end = n * 4, n * 4 + 3.5
        lines += [f"00:{start:02d}.000 --> 00:{int(end):02d}.500", f"Subtitle line {n + 1}", ""]
    return "\n".join(lines).encode()


# The recorded samples have no genres, ratings or descriptions and a single hero item. For
# the screenshot gallery the mock adds them to the featured items, so the Home hero shows
# its full layout (metadata line, description, page dots).
HERO_EXTRAS = {
    19: {"genres": ["Animation", "Comedy"], "rating": "PG", "tmdbId": 603,
         "overview": "A gentle giant rabbit takes on three bullies in a sunny meadow."},
    2: {"genres": ["Drama", "Mystery"], "rating": "12+", "tmdbId": 1399,
        "overview": "A small test crew follows a signal nobody else can hear."},
    22: {"genres": ["Documentary"], "rating": "0+",
         "overview": "Ten seconds of plain footage, shot for the player tests."},
}


def tracked_new():
    """«New Releases» as the server sends it: a followed title that is not in the library is its own TMDB
    card with id 0 (two of them share kind and id). The app leaves them out."""
    off = [{"id": 0, "kind": "series", "title": title, "subtitle": "S2 · E1", "poster": "", "tmdbKind": "series",
            "tmdbId": tmdb, "season": 2, "episode": 1} for title, tmdb in [("Far Away Show", 9001), ("Another Far Show", 9002)]]
    return {"id": "tracked-new", "title": "New Releases", "cards": off + [{"id": 0, "kind": "movie", "title": "Far Away Film", "tmdbKind": "movie", "tmdbId": 9003}]}


def home_with_hero():
    home = json.loads((SAMPLES / "home.json").read_text())
    cards = {c["id"]: c for shelf in home["shelves"] for c in shelf["cards"]}
    for card in json.loads((SAMPLES / "items-series.json").read_text()).get("items", []):
        cards.setdefault(card["id"], card)
    seen = {c["id"] for c in home["hero"]}
    home["hero"] += [cards[i] for i in (2, 22) if i in cards and i not in seen]
    home["shelves"].insert(1, tracked_new())
    return home


def item_with_extras(item_id, sample):
    item = json.loads((SAMPLES / sample).read_text())
    item.update(HERO_EXTRAS.get(item_id, {}))
    return item


# Fields of newer servers the recorded samples predate: watched marks on cards, each
# episode's own still (`thumb`, a frame of its video), cast portraits and trailers.
WATCHED = {1, 4, 25}
CAST = [
    {"name": "Ada Example", "character": "Captain", "photo": "/api/images/cast/Ada%20Example"},
    {"name": "Ben Sample", "character": "Engineer", "photo": "/api/images/cast/Ben%20Sample"},
    {"name": "Cy Placeholder", "character": "Navigator"},
    {"name": "Dee Fixture", "character": "Doctor", "photo": "/api/images/cast/Dee%20Fixture"},
    {"name": "Eli Stand-In", "character": "Pilot", "photo": "/api/images/cast/Eli%20Stand-In"},
]
TRAILERS = {
    19: [{"name": "Official Trailer", "site": "YouTube", "key": "aqz-KE-bpKQ", "type": "Trailer", "lang": "en",
          "official": True, "url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ", "play": "/api/trailers/aqz-KE-bpKQ/play"}],
    2: [{"name": "Official Trailer", "site": "YouTube", "key": "tst-trailer1", "type": "Trailer", "lang": "en",
         "official": True, "url": "https://www.youtube.com/watch?v=tst-trailer1", "play": "/api/trailers/tst-trailer1/play"},
        {"name": "Season 2 Teaser", "site": "YouTube", "key": "tst-teaser02", "type": "Teaser", "lang": "en",
         "official": True, "url": "https://www.youtube.com/watch?v=tst-teaser02", "play": "/api/trailers/tst-teaser02/play"},
        # As an older server lists it (no `play`): the app falls back to the QR code.
        {"name": "Behind the Scenes", "site": "YouTube", "key": "tst-behind03", "type": "Teaser", "lang": "en",
         "official": False, "url": "https://www.youtube.com/watch?v=tst-behind03"}],
}
# `POST play`: each first request of a pair is busy (503 + Retry-After, the app asks again),
# then the answer comes after a pause, as a first fetch does. The teaser's fetch fails (502).
TRAILER_FAILS = {"tst-teaser02"}
TRAILER_PLAYS = {}
TRAILER_LOCK = threading.Lock()


def trailer_play(key):
    """(status, headers, payload) for `POST /api/trailers/{key}/play`."""
    listed = {t["key"] for entries in TRAILERS.values() for t in entries if t.get("play")}
    if key not in listed:
        return 404, {}, {"error": "Trailer not found"}
    with TRAILER_LOCK:
        TRAILER_PLAYS[key] = TRAILER_PLAYS.get(key, 0) + 1
        attempt = TRAILER_PLAYS[key]
    if attempt % 2 == 1:
        return 503, {"Retry-After": "2"}, {"error": "Busy"}
    time.sleep(3)
    if key in TRAILER_FAILS:
        return 502, {}, {"error": "Couldn't get the trailer from the video site. Try again later."}
    return 200, {}, {"url": f"/api/trailers/{key}.mp4?mk=mock-media-key", "durationMs": 60000}


# The addons' `x/app` protocol, with `--addons`: `alpha` watches (any title, its episodes too) and
# searches; `beta` watches what the library lacks, keeps a copy of anything (a state ring while it
# runs) and searches. Wording is the mock's own: the app shows whatever the server says.
ADDON_APP = {
    "alpha": {"v": 1, "ways": [
        {"id": "go", "label": "Watch here", "icon": "globe", "role": "watch", "kinds": ["movie", "series"],
         "scope": "any", "episodes": True}], "search": {"label": "Find and watch"}},
    "beta": {"v": 1, "ways": [
        {"id": "view", "label": "Watch now", "icon": "play", "role": "watch", "kinds": ["movie", "series"],
         "scope": "outside", "episodes": True},
        {"id": "fetch", "label": "Add to server", "icon": "download", "role": "keep", "kinds": ["movie", "series"],
         "scope": "any", "episodes": False}], "search": {"label": "Find and add"}},
}
ADDON_TITLES = {
    "alpha": [{"kind": "movie", "tmdbId": 603, "title": "Sample Film", "year": 1999,
               "poster": "/api/images/local/100/poster", "overview": "A sample film.", "inLibrary": False},
              {"kind": "series", "tmdbId": 1399, "title": "Test Show", "year": 2011,
               "poster": "/api/images/local/2/poster", "inLibrary": True, "libraryItemId": 2}],
    "beta": [{"kind": "series", "tmdbId": 5555, "title": "Far Show", "year": 2020,
              "poster": "/api/images/local/101/poster", "overview": "A show the library lacks.", "inLibrary": False}],
}
ADDON_TITLE_INFO = {
    ("movie", 603): {"tmdbId": 603, "extId": "", "kind": "movie", "title": "Sample Film", "subtitle": "", "year": 1999,
                     "poster": "/api/images/local/100/poster", "overview": "A sample film.", "inLibrary": False,
                     "libraryItemId": None, "backdrop": "/api/images/local/2/backdrop", "genres": ["Drama"],
                     "runtime": 95, "rating": "12+", "cast": [], "seasons": []},
    ("series", 5555): {"tmdbId": 5555, "extId": "", "kind": "series", "title": "Far Show", "subtitle": "", "year": 2020,
                       "poster": "/api/images/local/101/poster", "overview": "A show the library lacks.",
                       "inLibrary": False, "libraryItemId": None, "backdrop": "/api/images/local/2/backdrop",
                       "genres": ["Mystery"], "rating": "16+", "cast": [],
                       "seasons": [{"number": 1, "episodes": 2}, {"number": 2, "episodes": 1}]},
}
ADDON_INPUT = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"


def new_addon_state():
    """What the addons remember for a run: alpha's last choice, beta's copy and how often the
    input player was asked."""
    return {"chosen": False, "fetch": None, "input_asks": 0, "sessions": 0}


def addon_step(addon, body):
    way, ref = body.get("way"), body.get("ref")
    if addon == "alpha" and way == "go":
        if ref is None:
            return {"title": "Source", "note": "Pick where to watch from", "rows": [
                {"ref": "mirror-1", "label": "Mirror one", "detail": "Fast, steady", "badges": ["HD"], "current": True, "final": False},
                {"ref": "mirror-2", "label": "Mirror two", "final": False},
                {"ref": "mirror-3", "label": "Mirror three", "detail": "Every voice and subtitle",
                 "badges": ["1080p", "Audio RU EN", "Subtitles"], "final": False},
                {"ref": "mirror-4", "label": "Mirror four", "badges": ["4K", "Аудио", "Субтитры"], "final": False}]}
        if ref.startswith("mirror-"):
            return {"title": "Quality", "note": "Picks the best release in this quality, or the best one in another if there is none.",
                    "rows": [
                {"ref": ref + ":720", "label": "720p", "final": True},
                {"ref": ref + ":1080", "label": "1080p", "badges": ["HDR"], "current": True, "final": True}]}
    if addon == "beta" and way == "fetch":
        if ref is None:
            return {"title": "Quality", "rows": [
                {"ref": "q:any", "label": "Any", "final": False},
                {"ref": "q:1080", "label": "1080p", "final": False}]}
        if ref.startswith("q:"):
            return {"title": "Releases", "note": "Best first", "rows": [
                {"ref": "rel-1", "label": "Release A · 8.1 GB", "detail": "12 sources", "badges": ["1080p"], "final": True},
                {"ref": "rel-2", "label": "Release B · 3.4 GB", "detail": "4 sources", "final": True}]}
    if addon == "beta" and way == "view":
        return {"title": "Releases", "rows": []} if ref == "none" else {"title": "Releases", "rows": [
            {"ref": "rel-1", "label": "Release A · 8.1 GB", "final": True}], "empty": "Nothing found"}
    return None


def addon_play(session):
    return {"mode": "alpha", "kind": "mp4", "url": f"/api/addons/alpha/x/media/{session}/clip.mp4", "startSec": 0,
            "durationMs": 0, "audio": [], "audioIndex": -1,
            "subtitles": [{"index": 0, "codec": "webvtt", "lang": "en", "title": "English", "label": "English",
                           "external": True, "url": f"/api/addons/alpha/x/media/{session}/subs/0.vtt"}],
            "quality": {"options": ["720", "1080"], "current": "1080"},
            "session": session, "progress": {"path": "x/app/progress", "every": 10}}


def addon_request(server, method, path, query, body):
    """(status, payload) for the addons' and the input player's routes; None for any other path. A
    payload that is a Path is a file to stream, bytes a subtitle."""
    state = server.addon_state
    if method == "GET" and path == "/api/addons/web":
        return 200, [{"id": name, "entry": f"/api/addons/{name}/x/web.js"} for name in ADDON_APP]
    match = re.fullmatch(r"/api/addons/(alpha|beta)/x/(.+)", path)
    if match:
        addon, rest = match.groups()
        data = json.loads(body) if body else {}
        if method == "GET" and rest == "app":
            return 200, ADDON_APP[addon]
        if method == "GET" and rest == "app/search":
            return 200, {"titles": ADDON_TITLES[addon]}
        if method == "POST" and rest == "app/step":
            step = addon_step(addon, data)
            return (200, step) if step else (404, {"error": "That way is gone"})
        if method == "POST" and rest == "app/run":
            if addon == "alpha":
                if data.get("ref") is None and data.get("quick") and not state["chosen"]:
                    return 200, {"pick": True}
                if data.get("ref"):
                    state["chosen"] = True
                state["sessions"] += 1
                return 200, {"play": addon_play(f"s{state['sessions']}")}
            if data.get("way") == "view":
                return 200, {"input": ADDON_INPUT}
            if data.get("way") == "fetch" and data.get("ref"):
                state["fetch"] = 0
                return 200, {"done": "Copy started"}
            return 400, {"error": "Choose a release first"}
        if method == "GET" and rest == "app/state":
            ways = {}
            if addon == "beta" and state["fetch"] is not None:
                state["fetch"] += 1
                # About a minute at the app's 5 s: long enough for a test to look at the ring and cancel.
                fraction = min(1.0, state["fetch"] * 0.08)
                if fraction >= 1.0:
                    state["fetch"] = None
                else:
                    ways["fetch"] = {"active": True, "fraction": fraction, "text": f"Fetched {int(fraction * 100)}%", "cancel": True}
            return 200, {"ways": ways}
        if method == "POST" and rest == "app/cancel":
            state["fetch"] = None
            return 200, {"done": "Copy cancelled"}
        if method == "PUT" and rest == "app/progress":
            return 204, None
        if method == "DELETE" and rest.startswith("app/play/"):
            return 204, None
        if method == "GET" and re.fullmatch(r"media/s\d+/clip\.mp4", rest):
            return 200, VIDEO
        if method == "GET" and re.fullmatch(r"media/s\d+/subs/\d+\.vtt", rest):
            return 200, subtitles()
        return 404, {"error": "Not found"}
    match = re.fullmatch(r"/api/title/(movie|series)/(\d+)", path)
    if match and method == "GET":
        info = ADDON_TITLE_INFO.get((match.group(1), int(match.group(2))))
        return (200, info) if info else (404, {"error": "Unknown movie or show"})
    if method == "GET" and path == "/api/tracking/series/5555/episodes":
        data = tracking_episodes()
        data["title"].update({"tmdbId": 5555, "name": "Far Show", "itemId": None})
        for episode in data["episodes"]:
            episode["sources"] = []
        return 200, data
    match = re.fullmatch(r"/api/play/input/([0-9a-f]+)(/.*)?", path)
    if match and match.group(1) == ADDON_INPUT:
        rest = match.group(2) or ""
        if method == "GET" and rest == "":
            return 200, {"id": ADDON_INPUT, "addonId": "beta", "name": "Sample Film", "itemId": 0, "slow": False, "startSec": 0}
        if method == "POST" and rest == "":
            state["input_asks"] += 1
            if state["input_asks"] % 3 != 0:
                return 202, {"pending": True}
            answer = play_response(19)
            answer.update({"url": f"/api/play/input/{ADDON_INPUT}/direct", "durationMs": 60000, "audioIndex": -1, "audio": [],
                           "subtitles": [{"index": 0, "codec": "webvtt", "lang": "en", "title": "English", "external": True,
                                          "url": f"/api/play/input/{ADDON_INPUT}/subs/0.vtt"}]})
            return 200, answer
        if method == "GET" and rest == "/direct":
            return 200, VIDEO
        if method == "GET" and rest == "/subs/0.vtt":
            return 200, subtitles()
        if method == "PUT" and rest == "/progress":
            return 204, None
    return None


# Kids' requests, with `--requests`: what the library lacks and a kid may ask a parent for. The
# mock ignores the profile's age limit; the wording is its own.
REQUEST_TITLES = [
    {"kind": "movie", "tmdbId": 116149, "title": "Paddington", "year": 1999, "poster": "/api/images/request/116149/poster",
     "overview": "A young bear travels to a new city in search of a home."},
    {"kind": "movie", "tmdbId": 1008042, "title": "Paddington in Peru", "year": 2024, "poster": "/api/images/request/1008042/poster",
     "overview": "The bear goes back to see his aunt."},
    {"kind": "series", "tmdbId": 2005, "title": "The Adventures of Paddington Bear", "year": 1997,
     "poster": "/api/images/request/2005/poster", "overview": "The bear and his friends, every week."},
    {"kind": "movie", "tmdbId": 2006, "title": "Paddington Goes Too Far", "year": 1999, "poster": "/api/images/request/2006/poster",
     "overview": "A longer story for older viewers."},
]
REQUEST_ALBUM = {"kind": "music", "tmdbId": 0, "extId": "mb-demo", "title": "Songs of Paddington", "subtitle": "Fixture Band", "year": 2019}


def new_request_state():
    """The kid's requests (newest first when listed): three answered to start with."""
    def made(id, title, status, reason="", at="2026-11-25T09:00:00Z"):
        return {"id": id, "key": f"tmdb:{title['tmdbId']}", "kind": title["kind"], "tmdbId": title["tmdbId"], "extId": "",
                "title": title["title"], "subtitle": "", "year": title["year"], "poster": title["poster"], "aliases": [],
                "rating": "PG", "status": status, "reason": reason, "libraryItemId": None, "createdAt": at}
    return {"next": 20, "mine": {
        11: made(11, REQUEST_TITLES[1], "pending", at="2026-11-25T08:30:00Z"),
        12: made(12, REQUEST_TITLES[2], "approved", at="2026-11-24T18:10:00Z"),
        13: made(13, REQUEST_TITLES[3], "declined", "Maybe when you are older", at="2026-11-23T16:00:00Z")}}


def request_key(candidate):
    return f"tmdb:{candidate['tmdbId']}" if candidate["kind"] in ("movie", "series") else f"ext:{candidate['extId']}"


def request_of(state, candidate):
    return next((r for r in state["mine"].values() if r["kind"] == candidate["kind"] and r["key"] == request_key(candidate)), None)


def requests_request(server, method, path, query, body, kid):
    """(status, payload) of the kid's request calls; None for any other path."""
    state = server.request_state
    if method == "GET" and path == "/api/requests/search":
        if not kid:
            return 403, {"error": "Only kid profiles may ask"}
        params = urllib.parse.parse_qs(query)
        text = (params.get("q") or [""])[0].lower().strip()
        kind = (params.get("kind") or [""])[0]
        found = REQUEST_TITLES if kind == "video" else [REQUEST_ALBUM] if kind == "music" else []
        return 200, [dict(c, extId=c.get("extId", ""), subtitle=c.get("subtitle", ""), aliases=[], explicit=False,
                          kidRequest={"key": request_key(c), "allowed": True, "request": request_of(state, c)})
                     for c in found if text and text in c["title"].lower()]
    if method == "GET" and path == "/api/requests/mine":
        return 200, sorted(state["mine"].values(), key=lambda r: (r["createdAt"], r["id"]), reverse=True)
    if method == "POST" and path == "/api/requests":
        if not kid:
            return 403, {"error": "Only kid profiles may ask"}
        asked = json.loads(body or b"{}")
        candidate = next((c for c in REQUEST_TITLES + [REQUEST_ALBUM]
                          if c["kind"] == asked.get("kind") and (c.get("tmdbId") == asked.get("tmdbId") or c.get("extId") == asked.get("extId"))), None)
        if candidate is None:
            return 404, {"error": "Unknown title"}
        known = request_of(state, candidate)
        if known:
            return 200, known
        state["next"] += 1
        made = {"id": state["next"], "key": request_key(candidate), "kind": candidate["kind"], "tmdbId": candidate["tmdbId"],
                "extId": candidate.get("extId", ""), "title": candidate["title"], "subtitle": candidate.get("subtitle", ""),
                "year": candidate["year"], "poster": candidate.get("poster", ""), "aliases": [], "rating": "PG", "status": "pending",
                "reason": "", "libraryItemId": None, "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        state["mine"][made["id"]] = made
        return 200, made
    match = re.fullmatch(r"/api/title/(movie|series)/(\d+)", path)
    if match and method == "GET":
        found = next((c for c in REQUEST_TITLES if c["kind"] == match.group(1) and c["tmdbId"] == int(match.group(2))), None)
        if found is None:
            return None
        info = {"tmdbId": found["tmdbId"], "extId": "", "kind": found["kind"], "title": found["title"], "subtitle": "", "year": found["year"],
                "poster": found["poster"], "overview": found["overview"], "inLibrary": False, "libraryItemId": None,
                "backdrop": "/api/images/request/%d/backdrop" % found["tmdbId"], "genres": ["Family", "Comedy"], "runtime": 95,
                "rating": "PG", "cast": [], "seasons": [{"number": 1, "episodes": 2}] if found["kind"] == "series" else []}
        if kid:
            info["kidRequest"] = {"key": request_key(found), "allowed": True, "request": request_of(state, found)}
        return 200, info
    return None


# «Family», with `--family`: the other profiles' places. Names are the mock's own, no real people.
FAMILY_PEOPLE = {
    11: {"name": "Alex", "avatar": "grad-3"},
    12: {"name": "Sam", "avatar": "grad-2"},
    13: {"name": "Kim", "avatar": "grad-5"},
    14: {"name": "Living Room", "ownerName": "Alex", "avatar": "grad-6"},
    # the longest names the server accepts are 64 characters: the list has to wrap them
    15: {"name": "Alexandria Konstantinopolskaya-Vishnevskaya", "avatar": "grad-4"},
    16: {"name": "Living Room Projector Upstairs", "ownerName": "Alexandria Konstantinopolskaya-Vishnevskaya", "avatar": "grad-1"},
}
LONG_TITLE_ITEM = 23
# The resume prompt's films: the viewer has no place of their own in the first (one profile has); the second has
# the viewer at 34:10 and four profiles around; in the third the server refuses to adopt (404).
FIRST_TIME_ITEM = 30
TWO_MEMBERS_ITEM = 31
ADOPT_REFUSED_ITEM = 33
MINUTE = 60_000


def family_members(item_id, now):
    """What `GET /api/items/{id}/family` answers for the adult profiles (newest first), as family.go builds it."""
    def ago(seconds):
        return (now - datetime.timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def member(user, item, ago_s, position=0, duration=0, finished=False, **extra):
        fraction = 1 if finished else (position / duration if duration else 0)
        return dict(FAMILY_PEOPLE[user], userId=user, isKid=False, itemId=item, positionMs=position, durationMs=duration,
                    fraction=round(fraction, 4), finished=finished, updatedAt=ago(ago_s), **extra)

    if item_id == 19:
        return [member(11, 19, 2 * 3600, 34 * MINUTE, 110 * MINUTE),
                member(14, 19, 5 * 3600, 71 * MINUTE + 5000, 110 * MINUTE),
                member(12, 19, 30 * 3600, 110 * MINUTE, 110 * MINUTE, finished=True),
                member(13, 19, 5 * 86400, 10 * MINUTE, 110 * MINUTE)]
    if item_id == 22:
        return [member(11, 22, 90, 25_000, 60_046), member(13, 22, 3 * 3600, 12_000, 60_046)]
    if item_id == LONG_TITLE_ITEM:
        return [member(15, 23, 2 * 3600, 34 * MINUTE, 110 * MINUTE),
                member(16, 23, 5 * 3600, 71 * MINUTE + 5000, 110 * MINUTE),
                member(12, 23, 30 * 3600, 110 * MINUTE, 110 * MINUTE, finished=True)]
    if item_id == 2:
        return [member(11, 5, 2 * 3600, 17 * MINUTE, 45 * MINUTE, season=1, episode=2, title="Episode 2", done=1, total=3),
                member(12, 12, 28 * 3600, season=2, episode=1, title="Episode 1", next=True, done=2, total=3),
                member(13, 12, 4 * 86400, 45 * MINUTE, 45 * MINUTE, finished=True, season=2, episode=1, title="Episode 1", done=3, total=3)]
    if item_id == FIRST_TIME_ITEM:
        return [member(11, item_id, 3 * 3600, 72 * MINUTE + 40_000, 110 * MINUTE)]
    if item_id == TWO_MEMBERS_ITEM:
        return [member(11, item_id, 2 * 3600, 72 * MINUTE + 40_000, 110 * MINUTE),
                member(14, item_id, 3 * 3600, 34 * MINUTE + 30_000, 110 * MINUTE),  # 20 s from the viewer's own place: not offered
                member(13, item_id, 5 * 3600, 51 * MINUTE, 110 * MINUTE),
                member(12, item_id, 30 * 3600, 110 * MINUTE, 110 * MINUTE, finished=True)]
    if item_id == ADOPT_REFUSED_ITEM:
        return [member(11, item_id, 3600, 40 * MINUTE, 110 * MINUTE)]
    if item_id == 5:
        return [member(11, 5, 2 * 3600, 17 * MINUTE, 45 * MINUTE, season=1, episode=2, title="Episode 2")]
    if item_id == 4:
        return [member(13, 4, 26 * 3600, 20 * MINUTE, 20 * MINUTE, finished=True, season=1, episode=1, title="Episode 1")]
    return []


# The episodes of the series 2 (season, number): the sample's own item answers every id with its own, so a page
# opened by a link would be another item's.
FAMILY_EPISODES = {4: (1, 1), 5: (1, 2), 12: (2, 1)}


def family_item(item_id):
    """The page of an item of the family fixtures with its own id; None for the ones the samples have right."""
    if item_id in FAMILY_EPISODES:
        season, number = FAMILY_EPISODES[item_id]
        item = json.loads((SAMPLES / "item-episode.json").read_text())
        return dict(item, id=item_id, title=f"Episode {number}", subtitle=f"Test Show · Season {season}, Episode {number}")
    if item_id in (2, 3, 11, 19):
        return None
    item = item_with_extras(item_id, "item-movie.json")
    if item_id in (FIRST_TIME_ITEM, TWO_MEMBERS_ITEM, ADOPT_REFUSED_ITEM):
        # a feature film's length for the prompt's bar (the clip that plays is still the 60 s one)
        item["files"] = [dict(f, durationMs=110 * MINUTE) if n == 0 else f for n, f in enumerate(item["files"])]
    if item_id == LONG_TITLE_ITEM:
        return dict(item, id=item_id, title="The Extraordinarily Long Title of a Quiet Film About Family Evenings, Part Two")
    return dict(item, id=item_id)


def family_request(server, method, path, body, kid):
    """(status, payload) of the family calls and of the progress an adopt copied; None for other paths."""
    now = datetime.datetime.now(datetime.timezone.utc)
    state = server.family_state
    match = re.fullmatch(r"/api/items/(\d+)", path)
    if method == "GET" and match and family_item(int(match.group(1))):
        return 200, family_item(int(match.group(1)))
    match = re.fullmatch(r"/api/items/(\d+)/family", path)
    if method == "GET" and match:
        return 200, {"members": [] if kid else family_members(int(match.group(1)), now)}
    match = re.fullmatch(r"/api/progress/(\d+)/adopt", path)
    if method == "POST" and match:
        item_id = int(match.group(1))
        if kid or item_id == ADOPT_REFUSED_ITEM:
            return 404, {"error": "Not found"}
        asked = json.loads(body or b"{}").get("userId")
        found = next((m for m in family_members(item_id, now) if m["userId"] == asked and m["itemId"] == item_id
                      and not m["finished"] and m["positionMs"] > 0), None)
        if found is None:
            return 404, {"error": "Not found"}
        state["adopted"][item_id] = {"positionMs": found["positionMs"], "durationMs": found["durationMs"], "finished": False,
                                     "locator": "", "fraction": found["fraction"], "updatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
        return 200, state["adopted"][item_id]
    match = re.fullmatch(r"/api/progress/(\d+)", path)
    if method == "GET" and match and int(match.group(1)) in state["adopted"]:
        return 200, state["adopted"][int(match.group(1))]
    if method == "GET" and match and int(match.group(1)) == FIRST_TIME_ITEM:
        # no progress yet: the server answers an empty one (no updatedAt)
        return 200, {"positionMs": 0, "durationMs": 0, "finished": False, "locator": "", "fraction": 0}
    if method == "GET" and match and int(match.group(1)) in (TWO_MEMBERS_ITEM, ADOPT_REFUSED_ITEM):
        position = 34 * MINUTE + 10_000
        return 200, {"positionMs": position, "durationMs": 110 * MINUTE, "finished": False, "locator": "",
                     "fraction": round(position / (110 * MINUTE), 4), "updatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    return None


def movie_grid(query):
    """The recorded movies plus generated ones, so the grid has rows to scroll."""
    page = json.loads((SAMPLES / "items-movies.json").read_text())
    if "offset=" in query and not re.search(r"offset=0(&|$)", query):
        return {"items": [], "total": page["total"] + 22}
    for n in range(1, 23):
        page["items"].append({"id": 100 + n, "kind": "movie", "title": f"Sample Movie {n}", "year": 2000 + n,
                              "poster": f"/api/images/local/{100 + n}/poster", "progress": 0.4 if n == 5 else 0,
                              "badges": ["1080p"], "onServer": True, "watched": n in (2, 9, 10)})
    page["total"] = len(page["items"])
    return page


def enrich(value):
    """Adds the newer card fields to every card in a response, in place."""
    if isinstance(value, list):
        for entry in value:
            enrich(entry)
    elif isinstance(value, dict):
        if isinstance(value.get("id"), int) and isinstance(value.get("kind"), str):
            if value["id"] in WATCHED and value["kind"] in ("movie", "episode"):
                value["watched"] = True
            if value["kind"] == "episode" and not value.get("thumb"):
                value["thumb"] = f"/api/images/frame/{value['id']}"
            if value["kind"] == "series" and value["id"] == 2 and not value.get("backdrop"):
                value["backdrop"] = "/api/images/local/2/backdrop"
            if "cast" in value and not value["cast"] and value["kind"] in ("movie", "series"):
                value["cast"] = CAST
        for entry in value.values():
            enrich(entry)
    return value


def tracking_episodes():
    """The full episode list of the test show, its upcoming episode a month from today."""
    data = json.loads((SAMPLES / "tracking-episodes.json").read_text())
    soon = (datetime.date.today() + datetime.timedelta(days=30)).isoformat()
    for episode in data["episodes"]:
        if episode["airDate"] > "2026-11-01":
            episode["airDate"] = soon
    return data


def on_air_now(sample):
    """A channels sample with its programmes moved so the first one started 30 s ago."""
    data = json.loads((SAMPLES / sample).read_text())
    channels = data["channels"] if "channels" in data else [data["channel"]]
    programs = [p for c in channels for p in (c.get("now"), c.get("next")) if p] + data.get("programs", [])
    programs += [p for c in channels for p in c.get("programs", [])]
    parse = lambda t: datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
    if programs:
        first = min(parse(p["start"]) for p in programs)
        shift = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=30) - first
        for p in programs:
            for key in ("start", "end"):
                p[key] = (parse(p[key]) + shift).isoformat().replace("+00:00", "Z")
        # The guide's window moves with them.
        for key in ("from", "to"):
            if key in data:
                data[key] = (parse(data[key]) + shift).isoformat().replace("+00:00", "Z")
    return data


MANY_CHANNELS = 24
FAR_LAST_CHANNEL = 18
ADULT_CHANNEL = 25


def many_channels(data):
    """The second port's list: 24 channels (the sample's four, then copies of them), the
    last one watched far down it, off the first screen, and channel 25 of the adult
    category."""
    sample = list(data["channels"])
    for number in range(len(sample) + 1, MANY_CHANNELS + 1):
        channel = json.loads(json.dumps(sample[(number - 1) % len(sample)]))
        channel.update(id=number, number=number, name=f"Канал {number}", favorite=False)
        data["channels"].append(channel)
    # The adult category's channel: listed first by this server, shown by the app only in
    # that category, which it puts last (not in All, Favourites or channel up / down).
    data["channels"].append({"id": ADULT_CHANNEL, "number": ADULT_CHANNEL, "name": "Ночной канал", "category": "",
                             "favorite": False, "categories": ["ai:adult"]})
    data["categories"] = [{"id": "ai:adult", "name": "Для взрослых", "kind": "ai", "count": 1, "exclusive": True}] + data.get("categories", [])
    data["lastChannel"] = FAR_LAST_CHANNEL


def sized_channels(data, count):
    """The main port's list with `--channels N` channels: the sample's four, cut short or continued
    with copies of them (the categories keep the sample's counts); the last one watched is the
    first (on air, with its progress)."""
    sample = list(data["channels"])
    data["channels"] = sample[:count]
    for number in range(len(sample) + 1, count + 1):
        channel = json.loads(json.dumps(sample[(number - 1) % len(sample)]))
        channel.update(id=number, number=number, name=f"Канал {number}", favorite=False)
        data["channels"].append(channel)
    data["lastChannel"] = data["channels"][0]["id"]


GUIDE_ROWS = 12
# (id and number, name, guide source, programme title, minutes off the half-hour grid)
EXTERNAL_ROWS = [(100, "Альфа ТВ", 7, "Альфа-новости", 0), (101, "Бета ТВ", 7, "Бета-кино", 0),
                 (102, "Гамма ТВ", 8, "Гамма-спорт", 10)]


def guide_with_externals(data):
    """The second port's guide: twelve rows (the sample's three, then copies), then three
    external channels with half-hour programmes on a fixed grid. Alpha and Beta take
    theirs from one guide source at the same instants: every programme id of the one is
    also an id of the other."""
    sample = list(data["channels"])
    for number in range(len(sample) + 1, GUIDE_ROWS + 1):
        row = json.loads(json.dumps(sample[(number - 1) % len(sample)]))
        row.update(id=number, number=number, name=f"Канал {number}", favorite=False)
        for n, program in enumerate(row["programs"]):
            program["id"] = f"{number}-{n + 1}"
        data["channels"].append(row)
    slot = 1800
    first = int(time.time()) // slot * slot - slot
    stamp = lambda seconds: datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for number, name, source, title, minutes in EXTERNAL_ROWS:
        starts = [first + n * slot + minutes * 60 for n in range(5)]
        programs = [{"id": f"x{source}-{start * 1000}", "kind": "external", "title": title,
                     "start": stamp(start), "end": stamp(start + slot)} for start in starts]
        data["channels"].append({"id": number, "number": number, "name": name, "category": "", "favorite": False,
                                 "programs": programs, "external": True})


def home_with_series(home):
    """The second port's Continue Watching ends with a series card (Select on it asks
    where to start, and plays the series' next episode)."""
    cards = {c["id"]: c for shelf in home["shelves"] for c in shelf["cards"]}
    for shelf in home["shelves"]:
        if shelf["id"] == "continue" and 2 in cards:
            shelf["cards"].append(dict(cards[2], progress=0.3))


def live_master():
    """A channel's master playlist: one picture, a rendition per voice."""
    lines = ["#EXTM3U", "#EXT-X-VERSION:4"]
    for n, (name, lang) in enumerate(LIVE_AUDIO):
        default = "YES" if n == 0 else "NO"
        lines.append(f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="{name}",LANGUAGE="{lang}",'
                     f'DEFAULT={default},AUTOSELECT=YES,URI="audio-{n}.m3u8"')
    lines += ['#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360,AUDIO="audio"',
              "video.m3u8", ""]
    return "\n".join(lines).encode()


def live_playlist(kind):
    """The last three segments by the clock; the clip starts again after its last one."""
    first = int(time.time() // LIVE_SEGMENT_SECONDS) - LIVE_SEGMENTS
    lines = ["#EXTM3U", "#EXT-X-VERSION:4", f"#EXT-X-TARGETDURATION:{LIVE_SEGMENT_SECONDS}",
             f"#EXT-X-MEDIA-SEQUENCE:{first}", f"#EXT-X-DISCONTINUITY-SEQUENCE:{(first - 1) // LIVE_SEGMENTS}"]
    for sequence in range(first, first + LIVE_SEGMENTS):
        if sequence % LIVE_SEGMENTS == 0:
            lines.append("#EXT-X-DISCONTINUITY")
        lines += [f"#EXTINF:{LIVE_SEGMENT_SECONDS:.3f},", f"{kind}-{sequence}.ts"]
    return "\n".join(lines + [""]).encode()


def relinked(playlist, prefix, key=None):
    """A playlist with every link under `prefix` (a path), each carrying the media key `key`
    when there is one: what the server's relay writes."""
    suffix = f"?mk={urllib.parse.quote(key, safe='')}" if key else ""
    lines = []
    for line in playlist.decode().split("\n"):
        if line.startswith("#"):
            line = re.sub(r'URI="([^"]+)"', lambda m: f'URI="{prefix}/{m.group(1)}{suffix}"', line)
        elif line:
            line = f"{prefix}/{line}{suffix}"
        lines.append(line)
    return "\n".join(lines).encode()


# After `POST /mock/external-audio`: (id and number, name, the audio is one the device cannot decode).
EXTERNAL_AUDIO_ROWS = [(200, "Звук через сервер", True), (201, "Звук напрямую", False)]


def with_external_audio(data, port):
    """Two external channels at the end of the list, the last one watched the first of them.
    Both offer the server's relay (every external channel has one, for the web); only the first
    says its audio needs it (`remuxAudio`, and so «web» is unsupported there, as the server writes it)."""
    for number, name, remux in EXTERNAL_AUDIO_ROWS:
        stream = {"url": f"http://127.0.0.1:{port}/provider/{number}/index.m3u8", "userAgent": "Agent/1.0", "format": "hls",
                  "relay": f"/api/channels/live/ext/{number}/0/relay", "fallbacks": [], "unsupported": []}
        if remux:
            stream.update(remuxAudio=True, unsupported=["web"])
        data["channels"].append({"id": number, "number": number, "name": name, "category": "", "favorite": False,
                                 "external": True, "stream": stream})
    data["lastChannel"] = EXTERNAL_AUDIO_ROWS[0][0]


def pairing_code(port):
    """`POST /api/auth/pair/start`: a code nobody approves (the poll stays pending)."""
    expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5)
    return {"code": "ABC234", "secret": "mock-pairing-secret", "expiresAt": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "interval": 2, "url": f"http://127.0.0.1:{port}/pair?code=ABC234"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # The client's User-Agent tells the app's requests from the Top Shelf extension's.
        # (Written here: newer Pythons rebuild a request's line and drop what was added.)
        agent = self.headers.get("User-Agent", "-") if hasattr(self, "headers") else "-"
        sys.stderr.write(f"{self.address_string()} - - [{self.log_date_time_string()}] {format % args} [{agent}]\n")

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")

    def do_PATCH(self):
        self.route("PATCH")

    def route(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self.request_body = body
        path, _, query = self.path.partition("?")
        if method == "PUT" and re.fullmatch(r"/api/progress/\d+", path):
            try:
                self.progress_write = json.loads(body or b"{}").get("positionMs")
            except ValueError:
                self.progress_write = None
            sys.stderr.write(f"progress write: item {path.rsplit('/', 1)[1]} positionMs {self.progress_write}\n")
        if getattr(self.server, "pairing", False) and self.test_hooks(method, path, query):
            return
        # Profile 2 is a kid profile, as on the sample server.
        if method == "POST" and path == "/api/auth/token" and json.loads(body or b"{}").get("userId") == 2:
            return self.send(200, json.dumps({"token": KID_TOKEN, "user": kid_user(self.server)}).encode(), "application/json")
        authorization = self.headers.get("Authorization") or ""
        pairing_port = getattr(self.server, "pairing", False)
        if pairing_port and path == "/api/profiles" and method == "GET":
            profiles = json.loads((SAMPLES / "profiles.json").read_text())
            return self.send(200, json.dumps(profiles + [{k: FAMILY_USER[k] for k in ("id", "name", "avatar", "hasPassword")}]).encode(), "application/json")
        if pairing_port and method == "POST" and path == "/api/auth/token" and json.loads(body or b"{}").get("userId") == 3:
            user = dict(FAMILY_USER, deviceHistory=history_ref(self.server.history))
            return self.send(200, json.dumps({"token": FAMILY_TOKEN, "user": user}).encode(), "application/json")
        if method == "GET" and path == "/api/me":
            me = kid_user(self.server) if KID_TOKEN in authorization else FAMILY_USER if FAMILY_TOKEN in authorization else json.loads((SAMPLES / "me.json").read_text())
            return self.send(200, json.dumps(dict(me, deviceHistory=history_ref(self.server.history))).encode(), "application/json")
        handled = managed_request(self.server.history, method, path, json.loads(body or b"{}") if method in ("POST", "PUT") else {},
                                  kid=KID_TOKEN in authorization)
        if handled:
            return self.send(handled[0], json.dumps(handled[1]).encode(), "application/json")
        # QR sign-in, on the second port only.
        if method == "POST" and getattr(self.server, "pairing", False):
            if path == "/api/auth/pair/start":
                return self.send(200, json.dumps(pairing_code(self.server.server_port)).encode(), "application/json")
            if path == "/api/auth/pair/poll":
                return self.send(200, json.dumps({"status": "pending"}).encode(), "application/json")
        if getattr(self.server, "requests", False) and (path.startswith("/api/requests") or path.startswith("/api/title/")):
            answer = requests_request(self.server, method, path, query, body, kid=KID_TOKEN in authorization)
            if answer is not None:
                return self.send(answer[0], json.dumps(answer[1]).encode(), "application/json")
        if getattr(self.server, "family", False) and (path.startswith("/api/items/") or path.startswith("/api/progress/")):
            answer = family_request(self.server, method, path, body, kid=KID_TOKEN in authorization)
            if answer is not None:
                return self.send(answer[0], json.dumps(answer[1]).encode(), "application/json")
        if getattr(self.server, "addons", False) and (path.startswith("/api/addons/") or path.startswith("/api/title/")
                                                       or path.startswith("/api/play/input/") or path == "/api/tracking/series/5555/episodes"):
            if KID_TOKEN in authorization and path.startswith("/api/addons/"):
                return self.send(403, json.dumps({"error": "Not available in a kid's profile"}).encode(), "application/json")
            answer = addon_request(self.server, method, path, query, body)
            if answer is not None:
                status, payload = answer
                if isinstance(payload, Path):
                    return self.send_file(payload, "video/mp4")
                if isinstance(payload, bytes):
                    return self.send(status, payload, "text/vtt; charset=utf-8")
                return self.send(status, json.dumps(payload).encode() if payload is not None else b"", "application/json")
        handled = LIBRARY.handle(method, path, json.loads(body or b"{}") if method in ("POST", "PATCH") else {})
        if handled:
            status, payload = handled
            return self.send(status, json.dumps(payload).encode() if payload is not None else b"", "application/json")
        if method == "GET" and re.fullmatch(r"/api/items/\d+/trailers", path):
            item_id = int(path.split("/")[3])
            return self.send(200, json.dumps({"trailers": TRAILERS.get(item_id, [])}).encode(), "application/json")
        match = re.fullmatch(r"/api/trailers/([A-Za-z0-9_-]{1,32})/play", path)
        if method == "POST" and match:
            status, headers, payload = trailer_play(match.group(1))
            data = json.dumps(payload).encode()
            self.send_response(status)
            for name, value in headers.items():
                self.send_header(name, value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if method == "GET" and re.fullmatch(r"/api/trailers/[A-Za-z0-9_-]{1,32}\.mp4", path):
            return self.send_file(VIDEO, "video/mp4")
        # A busy server answers some frames 503 (the app shows the series' picture instead).
        if method == "GET" and path == "/api/images/frame/5":
            self.send_response(503)
            self.send_header("Retry-After", "5")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # Kiddo's photo (`photo` of the profile samples); Admin has none and keeps the letter.
        if method == "GET" and path == "/api/profiles/2/photo":
            return self.send(200, profile_photo(), "image/png")
        if method == "GET" and path.startswith("/api/images/"):
            return self.send(200, image_for(path), "image/png")
        if method == "POST" and path == "/api/logout":
            return self.send(204, b"", "application/json")
        if method in ("POST", "DELETE") and re.fullmatch(r"/api/(watchlist/\d+|items/\d+/watched)", path):
            return self.send(204, b"", "application/json")
        if method == "PUT" and re.fullmatch(r"/api/progress/\d+", path):
            return self.send(204, b"", "application/json")
        if method == "POST" and re.fullmatch(r"/api/play/\d+", path):
            answer = play_response(int(path.rsplit("/", 1)[1]), segments=getattr(self.server, "pairing", False))
            return self.send(200, json.dumps(answer).encode(), "application/json")
        if method == "GET" and re.fullmatch(r"/api/stream/\d+", path):
            return self.send_file(VIDEO, "video/mp4")
        if method == "GET" and path == f"/api/tracks/{TRANSCODED_TRACK}/stream" and getattr(self.server, "pairing", False):
            return self.send_transcoded()
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
        if method == "GET" and path == "/api/home":
            home = home_with_hero()
            if getattr(self.server, "pairing", False):
                home_with_series(home)
            if self.server.history["current"]:
                # Another history has another Continue Watching: what this device watched.
                for shelf in home["shelves"]:
                    if shelf["id"] == "continue":
                        shelf["cards"] = [c for c in shelf["cards"] if c.get("title") == "Plain Clip"]
            return self.send(200, json.dumps(home).encode(), "application/json")
        # Live channels: the list and guides, on air now; every channel plays the same stream.
        if method == "GET" and path == "/api/channels":
            channels = on_air_now("channels.json")
            if getattr(self.server, "pairing", False):
                many_channels(channels)
                if self.server.channels["externalAudio"]:
                    with_external_audio(channels, self.server.server_port)
                with_channel_state(channels, self.server.channels)
                channels["favoritesFirst"] = self.server.channels["favoritesFirst"]
            elif getattr(self.server, "channel_count", None):
                sized_channels(channels, self.server.channel_count)
            return self.send(200, json.dumps(channels).encode(), "application/json")
        # «Избранные каналы первыми»: the second port only (the main one is an older server).
        if getattr(self.server, "pairing", False) and path == "/api/channels/prefs":
            if method == "PUT":
                self.server.channels["favoritesFirst"] = bool(json.loads(body or b"{}").get("favoritesFirst"))
            if method in ("GET", "PUT"):
                answer = {"favoritesFirst": self.server.channels["favoritesFirst"]}
                return self.send(200, json.dumps(answer).encode(), "application/json")
        if method == "GET" and re.fullmatch(r"/api/channels/\d+/guide", path):
            return self.send(200, json.dumps(on_air_now("channel-guide.json")).encode(), "application/json")
        if method == "GET" and path == "/api/channels/epg":
            guide = on_air_now("channel-epg.json")
            if getattr(self.server, "pairing", False):
                guide_with_externals(guide)
                with_channel_state(guide, self.server.channels)
            return self.send(200, json.dumps(guide).encode(), "application/json")
        star = re.fullmatch(r"/api/channels/(\d+)/favorite", path)
        if method in ("PUT", "DELETE") and star and getattr(self.server, "pairing", False):
            favorites = self.server.channels["favorites"]
            (favorites.add if method == "PUT" else favorites.discard)(int(star.group(1)))
        if method in ("PUT", "DELETE") and re.fullmatch(r"/api/channels/(\d+/favorite|last)", path):
            return self.send(204, b"", "application/json")
        if method == "POST" and path == "/api/channels/opened":
            return self.send(204, b"", "application/json")
        match = re.fullmatch(r"/api/channels/live/\d+/([a-z]+)(?:-(\d+))?\.(m3u8|ts)", path)
        if method == "GET" and match:
            kind, number, extension = match.groups()
            if extension == "ts" and kind in ("video", "audio") and number:
                return self.send_file(LIVE / f"{kind}-{int(number) % LIVE_SEGMENTS}.ts", "video/mp2t")
            if extension == "m3u8" and kind in ("index", "video", "audio"):
                playlist = live_master() if kind == "index" else live_playlist(kind)
                return self.send(200, playlist, "application/vnd.apple.mpegurl")
        # The external channels of `POST /mock/external-audio`: the provider's own stream, and the
        # server's relay of it (it wants the media key, on the playlist and on everything in it).
        external = re.fullmatch(r"/provider/(\d+)/(.+)", path) or re.fullmatch(r"/api/channels/live/ext/(\d+)/0/relay(?:/(.+))?", path)
        if method == "GET" and external and getattr(self.server, "pairing", False):
            number, name = external.group(1), external.group(2) or "index.m3u8"
            relay = path.startswith("/api/")
            key = urllib.parse.parse_qs(query).get("mk", [""])[0]
            if relay and not key:
                return self.send(401, json.dumps({"error": "Нужно войти"}).encode(), "application/json")
            live = re.fullmatch(r"([a-z]+)(?:-(\d+))?\.(m3u8|ts)", name)
            if live and live.group(3) == "ts" and live.group(1) in ("video", "audio") and live.group(2):
                return self.send_file(LIVE / f"{live.group(1)}-{int(live.group(2)) % LIVE_SEGMENTS}.ts", "video/mp2t")
            if live and live.group(3) == "m3u8" and live.group(1) in ("index", "video", "audio"):
                playlist = live_master() if live.group(1) == "index" else live_playlist(live.group(1))
                prefix = f"/api/channels/live/ext/{number}/0/relay" if relay else f"/provider/{number}"
                return self.send(200, relinked(playlist, prefix, key if relay else None), "application/vnd.apple.mpegurl")
        if method == "PUT" and path == "/api/me/playback-prefs/auto-skip":
            change = json.loads(body or b"{}")
            self.server.auto_skip.update({k: bool(v) for k, v in change.items() if k in ("recap", "intro", "credits")})
        if path in ("/api/me/playback-prefs", "/api/me/playback-prefs/auto-skip") and method in ("GET", "PUT"):
            prefs = json.loads((SAMPLES / "playback-prefs.json").read_text())
            if self.server.auto_skip:
                prefs["autoSkip"] = dict({"recap": False, "intro": False, "credits": False}, **self.server.auto_skip)
            return self.send(200, json.dumps(prefs).encode(), "application/json")
        if method == "GET" and re.fullmatch(r"/api/items/(19|22)", path):
            item_id = int(path.rsplit("/", 1)[1])
            return self.send(200, json.dumps(item_with_extras(item_id, "item-movie.json")).encode(), "application/json")
        if method == "GET" and path == "/api/items/2":
            return self.send(200, json.dumps(item_with_extras(2, "item-series.json")).encode(), "application/json")
        if method == "GET" and path == "/api/tracking/series/1399/episodes":
            return self.send(200, json.dumps(tracking_episodes()).encode(), "application/json")
        if method == "GET" and path == "/api/items" and "kind=movie" in query:
            return self.send(200, json.dumps(movie_grid(query)).encode(), "application/json")
        if method == "GET" and path == "/api/items" and "kind=series" in query:
            return self.send(200, (SAMPLES / "items-series.json").read_bytes(), "application/json")
        for (verb, pattern), sample in ROUTES.items():
            if verb == method and re.fullmatch(pattern, path):
                return self.send(200, (SAMPLES / sample).read_bytes(), "application/json")
        self.send(404, json.dumps({"error": "Not found"}).encode(), "application/json")

    def test_hooks(self, method, path, query):
        """The second port's record of its requests and its one-off failures; True when
        the request was answered here."""
        server = self.server
        if path.startswith("/mock/"):
            match = re.fullmatch(r"/mock/fail-progress/(\d+)", path)
            decide = re.fullmatch(r"/mock/decide/(\d+)/(pending|approved|declined|in_library)", path)
            with server.hooks_lock:
                if method == "GET" and path == "/mock/events":
                    payload = json.dumps(server.events).encode()
                elif method == "POST" and path == "/mock/reset":
                    server.events.clear()
                    server.fail_progress.clear()
                    server.auto_skip.clear()
                    server.history = new_history_state()
                    server.channels = new_channel_state()
                    server.addon_state = new_addon_state()
                    server.request_state = new_request_state()
                    server.family_state = new_family_state()
                    payload = b"{}"
                elif method == "POST" and path == "/mock/external-audio":
                    server.channels["externalAudio"] = True
                    payload = b"{}"
                elif method == "POST" and match:
                    server.fail_progress.add(int(match.group(1)))
                    payload = b"{}"
                elif method == "POST" and decide and int(decide.group(1)) in server.request_state["mine"]:
                    # a parent answers a request (a reason with `?reason=`; `in_library` as the library gets the title)
                    asked = server.request_state["mine"][int(decide.group(1))]
                    asked["status"] = decide.group(2)
                    asked["reason"] = (urllib.parse.parse_qs(query).get("reason") or [""])[0]
                    asked["libraryItemId"] = 1 if decide.group(2) == "in_library" else None
                    payload = b"{}"
                else:
                    payload = None
            if payload is None:
                self.send(404, json.dumps({"error": "Not found"}).encode(), "application/json")
            else:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            return True
        self.event = {"t": time.time(), "method": method, "path": path, "query": query,
                      "agent": self.headers.get("User-Agent", "")}
        if method == "PUT" and path.startswith("/api/progress/"):
            self.event["positionMs"] = self.progress_write
        if method == "PUT" and path in ("/api/me/playback-prefs/auto-skip", "/api/me/devices/current/history"):
            self.event["body"] = self.request_body.decode("utf-8", "replace")
        if method in ("POST", "PUT") and ("/x/app/" in path or path.startswith("/api/play/input/") or path == "/api/requests"
                                          or path.endswith("/adopt")):
            self.event["body"] = self.request_body.decode("utf-8", "replace")
        match = re.fullmatch(r"/api/progress/(\d+)", path)
        with server.hooks_lock:
            server.events.append(self.event)
            del server.events[:-4000]
            fail = method == "GET" and match and int(match.group(1)) in server.fail_progress
            if fail:
                server.fail_progress.discard(int(match.group(1)))
                self.event["failed"] = True
        if fail:
            self.send(503, json.dumps({"error": "Server is busy"}).encode(), "application/json")
            return True
        return False

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

    def send_transcoded(self):
        """A transcoded song: the whole stream whatever the range, of unknown length. The
        player gets it at once; the app's own request for the headers waits six seconds."""
        if "AppleCoreMedia" not in (self.headers.get("User-Agent") or ""):
            time.sleep(6)
        with self.server.hooks_lock:
            self.event["answered"] = time.time()
        self.send_response(200)
        self.send_header("Content-Type", "audio/aac")
        self.send_header("Accept-Ranges", "none")
        self.send_header("X-Vault-Transcode", "1")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(TRANSCODED.read_bytes())
        except OSError:
            pass

    def send(self, status, body, content_type):
        if content_type == "application/json" and body:
            body = json.dumps(enrich(json.loads(body))).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def new_family_state():
    """The progress an adopt copied into the caller's own, by item."""
    return {"adopted": {}}


def new_channel_state():
    """The second port's channel choices: the sample's favourite (3) and «favourites first»
    on, as a profile has them by default."""
    return {"favorites": {3}, "favoritesFirst": True, "externalAudio": False}


# The second port's logos: channel 2's uploaded logo does not load (404), so its guide icon
# (`logoAlt`) shows; channel 4 has only the guide icon; the others none (their initials).
CHANNEL_LOGOS = {2: {"logoUrl": "/api/channels/2/logo.png?v=1", "logoAlt": "/api/images/logo/alt-2"},
                 4: {"logoAlt": "/api/images/logo/alt-4"}}


def with_channel_state(data, state):
    """The list or the guide as the server orders it: by number, the favourites first when
    the profile wants them so; the stars and logos of the second port."""
    for channel in data["channels"]:
        channel["favorite"] = channel["id"] in state["favorites"]
        channel.update(CHANNEL_LOGOS.get(channel["id"], {}))
    data["channels"].sort(key=lambda c: (not (state["favoritesFirst"] and c["favorite"]), c["number"], c["id"]))
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8421)
    parser.add_argument("--addons", action="store_true", help="serve the addons' x/app protocol and the input player")
    parser.add_argument("--requests", action="store_true", help="the kid profile may ask a parent for titles the library lacks")
    parser.add_argument("--family", action="store_true", help="the other profiles of the family have places in some titles (and adopting one works)")
    parser.add_argument("--channels", type=int, default=0, help="the main port's channel list has this many channels (for screenshots)")
    args = parser.parse_args()
    pairing = ThreadingHTTPServer(("127.0.0.1", args.port + 1), Handler)
    pairing.pairing = True
    pairing.events, pairing.fail_progress, pairing.hooks_lock = [], set(), threading.Lock()
    pairing.auto_skip = {}
    pairing.history = new_history_state()
    pairing.channels = new_channel_state()
    pairing.addons, pairing.addon_state = args.addons, new_addon_state()
    pairing.requests, pairing.request_state = args.requests, new_request_state()
    pairing.family, pairing.family_state = args.family, new_family_state()
    threading.Thread(target=pairing.serve_forever, daemon=True).start()
    main_server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    main_server.auto_skip = {}
    main_server.channel_count = args.channels
    main_server.addons, main_server.addon_state = args.addons, new_addon_state()
    main_server.requests, main_server.request_state = args.requests, new_request_state()
    main_server.family, main_server.family_state = args.family, new_family_state()
    main_server.history = new_history_state()
    main_server.serve_forever()


if __name__ == "__main__":
    main()

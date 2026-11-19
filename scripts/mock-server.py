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
    POST /mock/fail-progress/<id>  the next `GET /api/progress/<id>` answers 503, once

«Отдельная история на этом устройстве»: `GET`/`POST /api/me/managed` and
`PUT /api/me/devices/current/history` answer as the server does on both ports, kept per port for
the run (one history, «Living Room», to start with; the kid's writes answer 403), and `/api/me`
carries the device's `deviceHistory`. The second port's profile picker has a third, passwordless
adult profile («Family») to switch it with; while it is on, Home's Continue Watching is another
one (the device's own), and `/mock/reset` puts it back.

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
    ("GET", r"/api/books/20"): "book-comic.json",
    ("GET", r"/api/books/21"): "book-comic-volume.json",
    ("GET", r"/api/books/23"): "book-audiobook-multifile.json",
    ("GET", r"/api/books/\d+"): "book-audiobook.json",
    ("GET", r"/api/comics/\d+/pages"): "comic-pages.json",
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
    19: {"genres": ["Animation", "Comedy"], "rating": "PG",
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
            return self.send(200, json.dumps({"token": KID_TOKEN, "user": KID_USER}).encode(), "application/json")
        authorization = self.headers.get("Authorization") or ""
        pairing_port = getattr(self.server, "pairing", False)
        if pairing_port and path == "/api/profiles" and method == "GET":
            profiles = json.loads((SAMPLES / "profiles.json").read_text())
            return self.send(200, json.dumps(profiles + [{k: FAMILY_USER[k] for k in ("id", "name", "avatar", "hasPassword")}]).encode(), "application/json")
        if pairing_port and method == "POST" and path == "/api/auth/token" and json.loads(body or b"{}").get("userId") == 3:
            user = dict(FAMILY_USER, deviceHistory=history_ref(self.server.history))
            return self.send(200, json.dumps({"token": FAMILY_TOKEN, "user": user}).encode(), "application/json")
        if method == "GET" and path == "/api/me":
            me = KID_USER if KID_TOKEN in authorization else FAMILY_USER if FAMILY_TOKEN in authorization else json.loads((SAMPLES / "me.json").read_text())
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
                with_channel_state(channels, self.server.channels)
                channels["favoritesFirst"] = self.server.channels["favoritesFirst"]
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
            with server.hooks_lock:
                if method == "GET" and path == "/mock/events":
                    payload = json.dumps(server.events).encode()
                elif method == "POST" and path == "/mock/reset":
                    server.events.clear()
                    server.fail_progress.clear()
                    server.auto_skip.clear()
                    server.history = new_history_state()
                    server.channels = new_channel_state()
                    payload = b"{}"
                elif method == "POST" and match:
                    server.fail_progress.add(int(match.group(1)))
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


def new_channel_state():
    """The second port's channel choices: the sample's favourite (3) and «favourites first»
    on, as a profile has them by default."""
    return {"favorites": {3}, "favoritesFirst": True}


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
    args = parser.parse_args()
    pairing = ThreadingHTTPServer(("127.0.0.1", args.port + 1), Handler)
    pairing.pairing = True
    pairing.events, pairing.fail_progress, pairing.hooks_lock = [], set(), threading.Lock()
    pairing.auto_skip = {}
    pairing.history = new_history_state()
    pairing.channels = new_channel_state()
    threading.Thread(target=pairing.serve_forever, daemon=True).start()
    main_server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    main_server.auto_skip = {}
    main_server.history = new_history_state()
    main_server.serve_forever()


if __name__ == "__main__":
    main()

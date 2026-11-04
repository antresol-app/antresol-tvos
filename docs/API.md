# Antresol Server API — client specification (server v0.3.0)

This document describes the HTTP API of the Antresol home media server as it behaves in
version 0.3.0. It is meant for native clients: tvOS (SwiftUI), Android TV and Android (Kotlin).

Every statement here was checked against a running 0.3.0 server, unless it is marked
*(inferred)*. Real responses are stored next to this file in `api-samples/<name>.json`, and
each section names its sample file.

Conventions:

- Types: `int` is a JSON integer (64-bit on the server), `float` is a JSON number, `string`, `bool`,
  `T[]` is an array of T, and `T | null` is a field that is present but can be `null`.
- A field marked *(opt)* is left out of the JSON when it has no value (Go `omitempty`).
  Every other field is always present, often as `""`, `0`, `[]` or `false`.
- Timestamps are RFC 3339 strings in UTC, for example `"2026-11-04T20:04:15.573Z"`.
- IDs:
  - An **item id** names a library entity: movie, series, season, episode, artist, album, track,
    audiobook, book, comic or comic_volume. All of these share one id space.
  - A **file id** names a physical file. Video playback, `/api/stream`, `/api/download`,
    `/api/audio` and comics take **file ids**, not item ids.

---

## Contents

1. [General: base URL, errors, language, CSRF](#1-general)
2. [Authentication](#2-authentication)
3. [The Card object and images](#3-cards-and-images)
4. [Library browsing (movies and series)](#4-library-browsing)
5. [Video playback](#5-video-playback)
6. [Progress, watched state, watchlist](#6-progress-watched-watchlist)
7. [Music](#7-music)
8. [Books, audiobooks, comics](#8-books-audiobooks-comics)
9. [Server-sent events](#9-events-sse)
10. [Admin and other endpoints (brief)](#10-other-endpoints)
11. [Client implementation notes](#11-client-implementation-notes)

---

## 1. General

| Item | Value |
|---|---|
| Base URL | `http://<host>:8420` (set by `VAULT_LISTEN`). All endpoints are under `/api/`. |
| Body format | JSON. Request bodies **must** carry `Content-Type: application/json` (`; charset=utf-8` is accepted). Without it the CSRF guard rejects the request with `403`. |
| Response format | JSON, except for media, images, subtitles (`text/vtt`) and SSE. |
| Language | Send `Accept-Language: en` or `ru`. **The default is Russian**: error messages, shelf titles and some content strings are localized. Examples of localized content: episode titles of unmatched files ("Episode 1" / "Серия 1"), season titles, badges ("Audio EN RU"), and `reason` strings in play responses. |
| Unknown route | `404`, plain text `404 page not found`. |
| Other ports | The server also serves a **Jellyfin-compatible API** on `:8096`, plus Subsonic (`/rest/*`) and OPDS (`/opds`), which need an app password. This document covers only the native `/api` interface. |

### Error format

```json
{ "error": "Human readable, localized message", "code": "optional-machine-code" }
```

- `error` (string) is always present.
- `code` (string) is optional and rarely set. One known value is `remote-passwordless`: a profile
  without a password tried to sign in from outside the home network.
- Status codes seen in testing:

| Status | Meaning |
|---|---|
| 200 / 201 / 202 / 204 | Success. `201` from `POST /api/users`, `202` from `POST /api/library/scan`, `204` for most mutations, which return no body. |
| 400 | Bad input: `Couldn't parse the request`, `Invalid id`, `Unknown section`, `Unknown sort order`, `Unknown format`, `No device given`, `Invalid timestamp`, and similar. |
| 401 | `Sign in required` (no valid auth) or `Wrong password`. |
| 403 | `Not allowed` (admin-only, or kid profile), `A request from another site was rejected` (CSRF), `The server is already set up`. |
| 404 | `Not found`, `File not found`, `Session not found`, `Playlist not found`, `No lyrics`, and similar. |
| 429 | Too many concurrent video sessions for this profile: `This profile is already watching on another device…`. Too many failed logins is likely also a `429` *(inferred)*. |
| 503 | A feature is not configured, for example subtitle search without an OpenSubtitles key. |

Sample: `api-samples/error-401.json`.

### CSRF guard

The guard applies to every authentication method, Bearer included:

- A mutating request (POST/PUT/PATCH/DELETE) that carries an `Origin` header from another site is
  rejected with `403`. Native clients should **not** send an `Origin` header.
- A mutating request with a body that is not `application/json` is rejected with `403`.
- Requests with no body, such as `POST /api/watchlist/1` or `DELETE ...`, need no Content-Type.

---

## 2. Authentication

The server accepts three ways to authenticate:

| Method | How to send it | Accepted on |
|---|---|---|
| **Device token** (native apps) | Header `Authorization: Bearer <token>` | Every `/api/*` endpoint, including images, HLS, streams, subtitles and SSE. |
| Web session cookie | `Cookie: vault_session=<token>` | Every endpoint (used by the web app). A device token also works as the cookie value. |
| **Media key** (short-lived, signed) | Query parameter `?mk=<key>` | **Only** these path prefixes: `/api/stream/`, `/api/hls/`, `/api/audio/`, `/api/tracks/`, plus `/api/torrent-stream/` and `/api/online/s/`, which are unused in library-only builds. **Not** accepted on images, subtitles (`/api/subs/...`), comics, `/api/download/` or JSON endpoints. |

Token details:

- Device tokens are opaque 43-character base64url strings, for example
  `gb88S043ePfI6trN-7SE892XdFd3UqW1A7rzrKqMSAA`.
- Tokens do not expire on their own. They are invalidated by logout, by device revocation, by
  re-registering the same `device.id`, or by deleting the user.
- A request with a missing, invalid or revoked token gets `401 {"error":"Sign in required"}`.
- `Authorization: <token>` without `Bearer `, an `X-*` token header and `?token=` are all
  **rejected**.

### 2.1 `GET /api/health` (no auth)

```json
{ "ok": true, "serverId": "e9a0691ebdc5d2d60f39cb1f551daff1", "version": "0.3.0" }
```

| Field | Type | Notes |
|---|---|---|
| ok | bool | |
| serverId | string | Stable 32-hex id for this server. Use it to tell servers apart and to key stored tokens. |
| version | string | Server version. |

Sample: `health.json`.

### 2.2 `GET /api/setup` (no auth)

```json
{ "needsSetup": false, "remote": false }
```

| Field | Type | Notes |
|---|---|---|
| needsSetup | bool | `true` when no admin exists yet. |
| remote | bool | `true` when the server sees this client as outside the home network. |

`POST /api/setup` takes `{"name": string, "password": string}` and creates the first admin. It works
only while `needsSetup` is true; otherwise it returns `403 {"error":"The server is already set up"}`.
The web client calls this only on a fresh install.

### 2.3 `GET /api/profiles` (no auth): profile picker

Returns a **bare array**:

```json
[
  { "id": 1, "name": "Admin", "avatar": "grad-1", "hasPassword": true },
  { "id": 2, "name": "Kiddo", "avatar": "grad-4", "hasPassword": false }
]
```

| Field | Type | Notes |
|---|---|---|
| id | int | User id, used as `userId` at login. |
| name | string | Display name. |
| avatar | string | One of `grad-1` … `grad-8`. Treat any other value as `grad-8`. |
| hasPassword | bool | If `true`, ask for a password before calling `/api/auth/token`. |

`isKid` and `isAdmin` are **not** in this list. They come back in the `user` object after sign-in.

Avatar values are gradient presets. The web app draws the first letter of the name on a 145° linear gradient:

| avatar | gradient (from → to) |
|---|---|
| grad-1 | `#5e5ce6` → `#bf5af2` |
| grad-2 | `#0a84ff` → `#64d2ff` |
| grad-3 | `#ff375f` → `#ff9f0a` |
| grad-4 | `#30d158` → `#00c7be` |
| grad-5 | `#ff9f0a` → `#ffd60a` |
| grad-6 | `#bf5af2` → `#ff375f` |
| grad-7 | `#00c7be` → `#0a84ff` |
| grad-8 | `#8e8e93` → `#48484a` |

Sample: `profiles.json`.

### 2.4 `POST /api/auth/token` (no auth): get a device token (native sign-in)

Request:

```json
{
  "userId": 1,
  "password": "admin123",
  "device": {
    "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
    "name": "Living Room Apple TV",
    "model": "AppleTV14,1",
    "version": "1.0.0"
  }
}
```

| Field | Type | Req | Notes |
|---|---|---|---|
| userId | int | yes | From `/api/profiles`. |
| password | string | if profile hasPassword | Omit it or send `""` for passwordless profiles. |
| device | object | yes | Must be an **object**. Sending a string gives `400 Couldn't parse the request`. |
| device.id | string | yes | Must match `^[A-Za-z0-9-]{8,64}$`, for example a UUID. Anything else gives `400 {"error":"No device given"}`. Keep it stable per installation. |
| device.name | string | no | Clipped to 100 characters. Shown in the devices list. |
| device.model | string | no | Clipped to 64 characters. |
| device.version | string | no | App version. Clipped to 64 characters. |

Response `200`:

```json
{
  "token": "gb88S043ePfI6trN-7SE892XdFd3UqW1A7rzrKqMSAA",
  "user": { "id": 1, "name": "Admin", "avatar": "grad-1", "hasPassword": true, "isAdmin": true,
            "isKid": false, "maxRating": null, "remote": false, "libraryOnly": true }
}
```

- `user` is the [Me object](#26-get-apime).
- **Re-registering the same `device.id` for the same user revokes the previous token for that
  device.** Only one session exists per device id.
- Errors:
  - `400 No device given`
  - `400 Couldn't parse the request`
  - `401 Wrong password`, also returned for a missing password or an unknown userId
  - Failed attempts are throttled: about 5 failures lock password sign-in for a while, for all
    clients behind the same IP.
- A passwordless profile cannot sign in from outside the home network (`remote`). The response is an
  error with `code: "remote-passwordless"`.

Sample: `auth-token.json`.

### 2.5 `POST /api/auth/media-key` (auth): signed media key

No body. Returns:

```json
{ "expiresAt": "2026-11-05T07:58:37Z", "key": "v1.2.1.1793865517.s7nHqQNy7rzmMnPou772dH" }
```

| Field | Type | Notes |
|---|---|---|
| key | string | Format `v1.<sessionRowId>.<userId>.<expiryUnix>.<mac>`. It is bound to the session that requested it, so revoking the session kills the key. |
| expiresAt | string | Expiry timestamp. **The TTL is 12 hours.** |

Append the key as `?mk=<key>` (or `&mk=`) to stream, HLS, audio and track URLs. Do this for players
that cannot attach headers to every request, such as AVPlayer and some ExoPlayer setups.

Inside an HLS playlist fetched with `?mk=`, the server **rewrites every segment URI, and the
`EXT-X-MAP` URI, to carry `?mk=`**, so the player needs no headers at all. See
[§5.4](#54-hls-playlists-and-segments). Refresh the key before it expires, for example whenever you
start playback and it has less than 1 hour left.

`GET` on this path returns `404`; the method must be `POST`.

Sample: `auth-media-key.json`.

### 2.6 `GET /api/me`

Returns the Me object for the authenticated user:

```json
{ "id": 1, "name": "Admin", "avatar": "grad-1", "hasPassword": true, "isAdmin": true,
  "isKid": false, "maxRating": null, "remote": false, "libraryOnly": true }
```

| Field | Type | Notes |
|---|---|---|
| id | int | |
| name | string | |
| avatar | string | `grad-1` … `grad-8` |
| hasPassword | bool | |
| isAdmin | bool | Admin-only endpoints return `403` for non-admins. |
| isKid | bool | Kid profiles see only items rated ≤ `maxRating`. **Unrated items are hidden from kids.** |
| maxRating | string \| null | For example `"6+"` or `"12+"`. Values used by the web UI: `0+`, `6+`, `12+`, `16+`, `18+`. |
| remote | bool | The request comes from outside the home network, so remote quality caps apply. |
| libraryOnly | bool | `true` in this build: there is no torrent or online discovery. |

Use this call to validate a stored token at app start: `401` means sign in again.

Sample: `me.json`.

### 2.7 `POST /api/login` (cookie sign-in, web)

- Body: `{"userId": int, "password"?: string}`.
- Response: the Me object, plus
  `Set-Cookie: vault_session=<token>; Path=/; Max-Age=34560000; HttpOnly; SameSite=Lax`.
- Native apps should use `/api/auth/token` instead. A cookie session does **not** appear in `/api/me/devices`.

### 2.8 `POST /api/logout`

No body. Returns `204`. It revokes the session the request authenticated with, whether that is the
Bearer token or the cookie. Afterwards the token gets `401`.

### 2.9 `GET /api/me/devices`

Lists the native device sessions of the current user. Web cookie sessions are not listed.

```json
{ "items": [ { "id": 2, "name": "Living Room Apple TV", "model": "AppleTV14,1", "version": "1.0.0",
               "createdAt": "2026-11-04T19:58:20Z", "lastSeen": "2026-11-04T20:08:28Z", "current": true } ] }
```

| Field | Type | Notes |
|---|---|---|
| id | int | Session row id. This is **not** `device.id`. |
| name, model, version | string | As registered. |
| createdAt, lastSeen | string | Timestamps. |
| current | bool | `true` for the session making this request. |

`DELETE /api/me/devices/{id}` revokes that device session and returns `204`. It only works on the
user's own devices; another user's device id gives `404 Device not found`. Revoking the current
device signs it out.

Sample: `me-devices.json`.

---

## 3. Cards and images

### 3.1 The Card object

Almost every list in the API returns **Cards**.

| Field | Type | Notes |
|---|---|---|
| id | int | Item id. |
| kind | string | `movie`, `series`, `season`, `episode`, `artist`, `album`, `playlist` (playlist id, not an item id), `audiobook`, `book`, `comic` (a comic series), `comic_volume`. |
| title | string | |
| subtitle | string | Context line. Examples: artist name for an album, author for an audiobook, `"Test Show · Season 1, Episode 1"` for an episode, `"1 volume"` for a comic series, `"3 songs"` for a playlist. |
| year | int *(opt)* | Left out when unknown. |
| poster | string | Image path or `""`. See [§3.2](#32-images). |
| backdrop | string | Image path or `""`. |
| logo | string | Image path or `""`, for a title logo. |
| progress | float | 0..1, the watched or read fraction for the current user. `0` when there is none. Series cards report `0`. |
| badges | string[] *(opt)* | Localized short labels such as `"1080p"`, `"Audio EN RU"`, `"Subtitles EN"`, `"MP3 64"`, `"1 MB"`. Display only. |
| onServer | bool | Always `true` in library-only builds. |
| seriesId | int *(opt)* | Set on episode, season and comic_volume cards: the parent series id. |
| season | int *(opt)* | Exists in the schema; not seen populated. |
| episode | int *(opt)* | Exists in the schema; not seen populated. |
| resumeSec | float *(opt)* | Exists in the schema; not seen populated. For resume, use [`GET /api/progress/{id}`](#61-get-apiprogressitemid). |
| online, tmdbKind, tmdbId | *(opt)* | Online-discovery fields. They are not used in library-only builds. |

### 3.2 Images

- Card image fields (`poster`, `backdrop`, `logo`) and `cover` fields hold **server-relative paths**:
  - `/api/images/local/{itemId}/poster` (also `/backdrop` and `/logo`): local artwork from the media folder.
  - `/api/images/{sha1}.jpg|png|webp|gif|svg`: cached remote or extracted artwork.
  - `""` means there is no image. Show a placeholder, such as the title on a gradient.
- **Build the URL** as `baseURL + path`. The web app helper does the following: a value that starts
  with `/`, `http:`, `https:` or `data:` is used as is; otherwise it becomes
  `/api/images/{encodeURIComponent(value)}`. In practice the server always returns paths that start with `/`.
- **Images require auth.** Send `Authorization: Bearer <token>`; `?mk=` does **not** work for
  images. Without auth they return `401`. Configure your image loader (Kingfisher, Coil, Glide,
  Nuke) to add the header.
- Responses carry `Cache-Control: private, max-age=604800` (7 days) and `Last-Modified`. There is no
  resize parameter: images come back at their original size.
- A missing image returns `404` with JSON. For example `/api/images/local/{id}/logo` returns `404`
  when the item has no logo, so trust the card fields and do not probe.

---

## 4. Library browsing

### 4.1 `GET /api/home`

```json
{ "hero": [Card], "shelves": [ { "id": string, "title": string, "cards": [Card] } ] }
```

- `hero` holds featured cards (movies or series with backdrops). It can be empty.
- `shelves` is always present and in fixed order. Empty shelves are still returned with `cards: []`.

| shelf id | Title (en) | Contents |
|---|---|---|
| `continue` | Continue Watching | In-progress movies and episodes, plus next-up episodes (`progress` = fraction). |
| `recently-played` | Recently Played | Albums. |
| `reading` | Currently Reading | In-progress audiobooks, books and comic volumes. |
| `recent-movies` | Recently Added Movies | |
| `recent-series` | New Episodes | Series cards. |
| `watchlist` | Want to Watch | |

Sample: `home.json`.

### 4.2 `GET /api/items`: list movies and series

Query parameters:

| Param | Type | Notes |
|---|---|---|
| kind | string | `movie` or `series`. If left out, movies and series are mixed. Any other value gives `400 Unknown section`. |
| sort | string | `recent` (date added, newest first; the default), `title` (A→Z), `year` (newest first). Unknown values fall back to the default. |
| limit | int | The web app uses `120`. |
| offset | int | |

Response:

```json
{ "items": [Card], "total": int }
```

Page while `offset + items.length < total`.

Samples: `items-movies.json`, `items-series.json`.

### 4.3 `GET /api/items/{id}`: item detail

Works for `movie`, `series`, `season` and `episode` ids. The response is the **Card fields
flattened at the top level**, plus these fields:

| Field | Type | Notes |
|---|---|---|
| originalTitle | string *(opt)* | |
| overview | string | |
| genres | string[] | |
| runtime | int *(opt)* | Minutes. |
| rating | string *(opt)* | Age rating, for example `"16+"`. |
| cast | `{name: string, character?: string}[]` | |
| seasons | SeasonInfo[] | Filled for a series: all seasons. For a season id: that season only. Otherwise `[]`. |
| files | FileInfo[] | Filled for a movie or episode. `[]` for a series or season. |
| next | EpisodeCard *(opt)* | Series only: the episode to play next (resume or next unwatched). |
| inWatchlist | bool | |
| actions | `{play: bool, toServer: bool, toDevice: bool, watchNow: bool}` | `play`: something is playable. `toDevice`: an offline copy is possible. The others are online features. |
| tmdbId | int *(opt)* | |

SeasonInfo:

```json
{ "id": int, "number": int, "title": string, "episodes": [EpisodeCard] }
```

EpisodeCard is the Card fields flattened, plus:

| Field | Type | Notes |
|---|---|---|
| seasonNo | int | |
| episodeNo | int | |
| overview | string *(opt)* | |
| durationMs | int *(opt)* | |
| watched | bool | |

EpisodeCards do **not** contain file ids. To play an episode, fetch `GET /api/items/{episodeId}` and
use `files[0].id`.

FileInfo:

| Field | Type | Notes |
|---|---|---|
| id | int | **File id**, used with `/api/play/{fileId}`. |
| name | string | File name. |
| size | int | Bytes. |
| durationMs | int *(opt)* | |
| resolution | string *(opt)* | `"720p"`, `"1080p"`, `"4K"`… |
| audio | AudioTrack[] | |
| subs | SubTrack[] | |

AudioTrack:

```json
{ "index": int, "codec": string, "lang": string, "title": string, "channels": int, "default": bool }
```

- `index` is the ffprobe stream index. Pass it as `audioIndex` to `/api/play`.
- `lang` is an ISO 639-2 code (`"eng"`), or `""`/`"und"` when unknown.

SubTrack:

```json
{ "index": int, "codec": string, "lang": string, "title": string, "forced": bool,
  "default": bool, "external": bool, "burnIn": bool, "url"?: string }
```

| Field | Notes |
|---|---|
| index | Stream index for embedded tracks. External sidecar files use `1000+`. |
| codec | For example `subrip`, `ass`, `mov_text`, `hdmv_pgs_subtitle`. |
| url | *(opt)* A WebVTT URL, for example `/api/subs/12/3.vtt` or `/api/subs/12/1000.vtt?src=b70596c2`. Text subtitles have one; image subtitles do not. |
| burnIn | `true` means the track can only be shown by burning it in (image subtitles); see `burnSubtitle` in [§5.1](#51-post-apiplayfileid). |

Samples: `item-movie.json`, `item-series.json`, `item-season.json`, `item-episode.json`.

### 4.4 `GET /api/search?q=<text>`

```json
{ "library": [Card], "albums": [Card], "artists": [Card], "songs": [Track],
  "audiobooks": [Card], "books": [Card], "comics": [Card] }
```

- `library` holds movies and series.
- `songs` holds [Track objects](#71-track-object).
- An empty `q` returns every array empty.

Samples: `search.json`, `search-music.json`.

### 4.5 Library scan (admin)

- `POST /api/library/scan` returns `202` with a JobStatus. Non-admins get `403`.
- `GET /api/library/status` returns a JobStatus:

```json
{ "running": false, "queued": false, "startedAt": "…", "finishedAt": "…", "error"?: "…",
  "movies": 2, "episodes": 3, "albums": 2, "tracks": 5, "books": 0, "audiobooks": 2,
  "comics": 1, "files": 12, "skipped": 0, "removed": 0 }
```

- `startedAt` and `finishedAt` are left out until set.
- The counts are library totals.

Sample: `library-status.json`.

---

## 5. Video playback

The flow has two steps:

1. Ask the server how to play a **file**: `POST /api/play/{fileId}`.
2. Play the returned `url`:
   - **Direct** (`mode: "direct"`): progressive HTTP with Range support, at `/api/stream/{fileId}`.
   - **HLS** (`mode: "remux"` or `"transcode"`): `/api/hls/{session}/index.m3u8`. Keep it alive with
     `PUT` and stop it with `DELETE`.

### 5.1 `POST /api/play/{fileId}`

Request body (all fields optional, but **send `caps`**):

```json
{
  "caps": {
    "videoCodecs": ["h264", "hevc"],
    "audioCodecs": ["aac", "ac3", "eac3"],
    "containers": ["mp4", "mov"],
    "maxHeight": 2160,
    "maxBitrate": 0,
    "hevcNeedsHvc1": true
  },
  "startSec": 0,
  "quality": "auto",
  "audioIndex": 1,
  "replaceSession": "d4efc029ebb8590d",
  "burnSubtitle": 5
}
```

| Field | Type | Notes |
|---|---|---|
| caps.videoCodecs | string[] | Values used: `h264`, `hevc`, `av1`, `vp9`. |
| caps.audioCodecs | string[] | Values used: `aac`, `mp3`, `ac3`, `eac3`, `opus`, `flac`. |
| caps.containers | string[] | Values used: `mp4`, `mov`, `webm`. **`mkv` is also accepted** and allows direct play of `.mkv` files (good for ExoPlayer). `matroska` is not recognized. |
| caps.maxHeight | int | Optional cap. Larger sources are transcoded. |
| caps.maxBitrate | int | Optional cap in bits/s. `0` means no cap. |
| caps.hevcNeedsHvc1 | bool | Set `true` for Apple players. HEVC tagged `hev1` is then repackaged (remuxed to fMP4 with `hvc1`) instead of played directly. |
| startSec | float | Resume position in seconds. For HLS the server **snaps it to the previous keyframe** and returns the real value in `startSec`. |
| quality | string | `auto` (default), `original`, `1080`, `720`, `480`. Unknown values are treated as `auto`. `original` means no quality cap (it does not force direct play). |
| audioIndex | int | An AudioTrack `index`. Picking a non-default track forces HLS (remux) so the server can select it. |
| replaceSession | string | The HLS session id to replace. Use it when seeking outside the current HLS window, changing audio track or changing quality. The old session is stopped. |
| burnSubtitle | int | A subtitle `index` to burn in. It only applies to image-based subtitles; for text subtitles it was ignored in testing. |

**If `caps` is empty or left out, everything is transcoded**: the server assumes the client can
decode nothing. The web app falls back to `{videoCodecs:["h264"], audioCodecs:["aac"]}` at minimum.

Response (an object with these keys):

| Field | Type | Notes |
|---|---|---|
| mode | string | `direct`, `remux` (video copied; container or audio converted), or `transcode` (video re-encoded). `online` exists only in online builds. |
| url | string | `/api/stream/{fileId}` for direct play, or `/api/hls/{session}/index.m3u8`. |
| reason | string | Localized explanation of why it is not direct. `""` for direct play. |
| startSec | float | Effective start. For HLS, **playlist time 0 equals `startSec` in the file**. For direct play this is the requested value; seek to it yourself. |
| durationMs | int | Full file duration. |
| audioIndex | int | The selected audio stream index. |
| audio | AudioTrack[] | Same shape as in FileInfo. |
| subtitles | SubTrack[] | Same shape as in FileInfo, with `url`s. |
| quality | `{selected: string, applied: string, remote: bool}` | `selected`: what you asked for. `applied`: what is used (`original`, `1080`, …). `remote`: the remote quality cap is in effect. |
| hlsComplete | bool *(opt)* | Present and `true` for HLS when the server can serve a **complete VOD playlist** (all segments listed up front, produced on demand). |
| burnedSubtitle | int *(opt)* | Set when a subtitle is burned in. |

Behavior seen in testing:

| Source | caps | Result |
|---|---|---|
| H.264 8-bit 4:2:0 + AAC in MP4 | h264/aac/mp4 | `direct`, url `/api/stream/{id}` |
| H.264 4:4:4 (or 10-bit) in MP4 | any | `transcode` ("browsers don't play 10-bit or non-4:2:0 H.264") |
| H.264 + AAC/AC3 in MKV | containers without `mkv` | `remux` → MPEG-TS HLS, 2 s segments |
| H.264 + AAC/AC3 in MKV | containers include `mkv` | `direct` |
| Non-default audio picked (`audioIndex`) | | `remux` (the audio is transcoded when its codec is not in caps) |
| HEVC (`hev1`) + E-AC3 in MKV | hevc/eac3/mp4 + `hevcNeedsHvc1` | `remux` → **fMP4 HLS** (`#EXT-X-MAP:URI="init.mp4"`, `.m4s` segments) |
| HEVC | h264 only | `transcode` → MPEG-TS HLS, 6 s segments |
| `quality: "480"` on 720p | | `transcode` |

**Concurrency limit.** A profile can hold at most **2** active HLS sessions; this is the limit
observed in testing. A third request returns `429` ("This profile is already watching on another
device…"). Always `DELETE` sessions you stop, and use `replaceSession` for seeks and track changes.
Direct play does not count toward the limit.

Other errors:

- `404 File not found`: the file id is unknown or the file is gone from disk.
- `400 Couldn't parse the request`.

Samples: `play-direct.json`, `play-mkv-hls.json`, `play-transcode-quality.json`,
`play-transcode-pixfmt.json`, `play-hevc-fmp4.json`.

### 5.2 `GET /api/stream/{fileId}`

- Serves the original file (`video/mp4`, `video/x-matroska`, `audio/mp4`, …).
- Supports `Range` (`206 Partial Content`).
- Auth: Bearer, cookie or `?mk=`.
- Used for direct play. It also works for any file id, including audiobook files and ebooks.

### 5.3 `GET /api/download/{fileId}`

- Same bytes as `/api/stream/{fileId}`, with `Content-Disposition: attachment; filename="…"`.
- Supports Range.
- **Bearer or cookie only.** `?mk=` returns `401`.

### 5.4 HLS playlists and segments

Paths:

- `GET /api/hls/{session}/index.m3u8` returns the playlist (`application/vnd.apple.mpegurl`).
- `GET /api/hls/{session}/{name}` returns segments: `segNNNNN.ts`, `vsegNNNNN.ts`, `init.mp4`,
  `segNNNNN.m4s`, `vsegNNNNN.m4s`.
- Segment URIs in the playlist are **relative** to the playlist.

The playlist depends on how you authenticate:

| How the playlist is requested | What you get |
|---|---|
| Bearer header or cookie | A **growing EVENT playlist** (`#EXT-X-PLAYLIST-TYPE:EVENT`, `seg*.ts`, 2 s segments for remux), extended as ffmpeg produces segments. Segment URIs have no auth, so the player must send the Bearer header on every segment request. |
| `?mk=<key>` only (no header) | When `hlsComplete` is true, a **complete VOD playlist** (`#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-START:TIME-OFFSET=0,PRECISE=YES`, `vseg*.ts` or `vseg*.m4s`, ~6 s segments, `#EXT-X-ENDLIST`). **Every URI has `?mk=<key>` appended**, including `EXT-X-MAP`. This is the best fit for AVPlayer and ExoPlayer: the full timeline is seekable and no headers are needed. |

If both a Bearer header and `mk` are sent, the header wins and you get the EVENT form.

The playlist starts at the response `startSec`. A player position `t` maps to file position
`startSec + t`. To seek to a point before `startSec`, or past the end of what an EVENT playlist
covers, call `/api/play` again with the new `startSec` and `replaceSession`.

Do not request segment numbers outside the playlist: doing so restarts the transcoder at that point.

While a segment is still being produced, the server may answer with a `Retry-After` header and an
error ("Video is still being prepared"). Retry after the indicated delay. Players normally handle
this by retrying.

Example VOD playlist (fetched with mk), from `hls-playlist-mediakey-vod.m3u8`:

```
#EXTM3U
#EXT-X-START:TIME-OFFSET=0,PRECISE=YES
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-INDEPENDENT-SEGMENTS
#EXTINF:6.000000,
vseg00000.ts?mk=v1.2.1.1793865787.N3BwISKViSjBe11c5IFdc8
...
#EXT-X-ENDLIST
```

Other samples: `hls-playlist-bearer-event.m3u8`, `hls-playlist-fmp4-mediakey.m3u8`.

### 5.5 `PUT /api/hls/{session}`: keepalive

No body. Returns:

```json
{ "segments": 10, "running": false, "paused": false }
```

| Field | Type | Notes |
|---|---|---|
| segments | int | Segments produced so far. |
| running | bool | ffmpeg is active. |
| paused | bool | Throttled, because it is far ahead of the player. |

- `404 Session not found` means the session expired, was replaced or was stopped. Start a new one
  with `/api/play`, using the same `startSec` and no `replaceSession`.
- The web player sends this **every 20 s** while an HLS session is open. Sessions that are not kept
  alive are reaped; the exact timeout was not measured.

Sample: `hls-keepalive.json`.

### 5.6 `DELETE /api/hls/{session}`: stop

Returns `204`. Call it when playback ends, the player closes, or the app goes to background.
Unknown sessions give `404`.

### 5.7 Subtitles

- `GET /api/subs/{fileId}/{index}.vtt[?src=…]` returns WebVTT (`text/vtt; charset=utf-8`). Use the
  `url` from SubTrack exactly as given; external tracks carry a `src` hash.
  - Embedded text subtitles are extracted and converted. ASS/SRT are converted to VTT, and
    CP1251-encoded files are handled.
  - Image subtitles return an error ("these subtitles are images, they can only be burned into the
    video"). Use `burnSubtitle` in `/api/play` for those.
  - While a track is being extracted, the server may answer with `Retry-After`; retry.
  - **Auth: Bearer or cookie only. `?mk=` does not work here.** Native clients should download the
    VTT with the header and attach it as a side-loaded text track:
    - ExoPlayer: `MediaItem.SubtitleConfiguration` with a local file, or a DataSource that sends headers.
    - AVPlayer: parse it and render it yourself, or use an `AVAssetResourceLoader`.
  - Cue times are relative to the **file**, not to the HLS `startSec`. Offset them by `startSec`
    when playing HLS that starts later.
- OpenSubtitles search is **not configured** on this server; both calls return `503`:
  - `GET /api/subtitles/{fileId}/search?lang=en` returns
    `{results: [{subtitleId: int, lang: string, release: string, downloads: int, hashMatch: bool}]}`.
  - `POST /api/subtitles/{fileId}` with `{"subtitleId": int, "lang": string}` downloads one into the
    library. Low priority for TV apps.

---

## 6. Progress, watched, watchlist

Progress is stored **per item id**: movie, episode, audiobook, book or comic_volume. Tracks and
albums have no progress; `PUT` on them returns `400 Progress isn't saved for this item`.

### 6.1 `GET /api/progress/{itemId}`

```json
{ "positionMs": 15000, "durationMs": 60046, "finished": false, "locator": "",
  "fraction": 0.2498, "updatedAt": "2026-11-04T20:04:15.573Z" }
```

| Field | Type | Notes |
|---|---|---|
| positionMs | int | For an audiobook this is the position on the **whole-book timeline** (see §8). |
| durationMs | int | |
| finished | bool | |
| locator | string | Reader position for books and comics, for example `"page:2"`. |
| fraction | float | 0..1 |
| updatedAt | string \| null | `null` when there is no progress yet; all other fields are then 0, `""` or false. |

Sample: `progress-get.json`.

### 6.2 `PUT /api/progress/{itemId}`

For video and audio:

```json
{ "positionMs": 15000, "durationMs": 60046 }
```

For readers (books and comics):

```json
{ "locator": "page:2", "fraction": 0.6667 }
```

| Field | Type | Notes |
|---|---|---|
| positionMs | int | |
| durationMs | int | |
| locator | string | Reader position. |
| fraction | float | Reader fraction. |
| updatedAt | string | Optional RFC 3339 timestamp of when the position was recorded on the client, for offline sync. **If it is older than the stored `updatedAt`, the write is ignored** (still `204`). Future times are clamped to now. An invalid value gives `400 Invalid timestamp`. |

- Returns `204`.
- `finished` is computed by the server. Values observed:
  - Video: finished at about **≥ 92–93 %** (60 min left of 2 h → no; 56/60 s → yes).
  - Audiobook: finished at about **≤ 30 s remaining**.
- Saving a lower position later clears `finished`.

### 6.3 `POST /api/items/{id}/watched`

- Body: `{"watched": true|false}`. Returns `204`.
- Works on a movie, an episode, a season or a series. For a season or series it applies to every episode.
- `watched: true` sets `finished: true` with position 0.
- `watched: false` **deletes** the progress, so the resume position is lost.

### 6.4 Watchlist

- `POST /api/watchlist/{itemId}` adds the item and returns `204`. `DELETE /api/watchlist/{itemId}`
  removes it and returns `204`.
- Verified as allowed: movies, series, audiobooks and comic series. Books are allowed *(inferred)*.
  For books and audiobooks the flag appears as `want: true`, and the item shows up in the `want` shelf
  of `/api/books/home`. Tracks and other kinds return `400 This can't be added to the list`.
- The watchlist is shown in `/api/home` (shelf `watchlist`) and `inWatchlist` in item detail.

---

## 7. Music

### 7.1 Track object

Used in album and artist detail, songs, shuffle, playlists and search.

```json
{ "id": 15, "title": "Track Number 1", "artist": "Sample Band", "artistId": 13, "albumId": 14,
  "album": "Sample Record", "discNo": 1, "trackNo": 1, "durationMs": 20000, "fileId": 8,
  "lossless": true, "hasLyrics": true, "cover": "/api/images/local/14/poster",
  "starred": false, "cue": false }
```

| Field | Type | Notes |
|---|---|---|
| id | int | **Track item id**: use it for streaming, lyrics, plays and star. |
| fileId | int | Underlying file id. |
| cover | string | Image path or `""`. |
| cue | bool | The track is a region of a larger file (CUE sheet). Streaming by track id handles the offsets. |
| idx | int | Position within a playlist. Present only in playlist responses. |

Sample: `music-track.json` (from `GET /api/music/tracks/{id}`).

### 7.2 Endpoints

| Method and path | Query or body | Response |
|---|---|---|
| `GET /api/music/home` | | `{shelves: [{id, title, cards: [Card]}]}`. Shelf ids: `recent-albums`, `recently-played` (album cards), `artists`, `playlists` (Card `kind: "playlist"`, `subtitle: "3 songs"`). Shelves appear only when non-empty. |
| `GET /api/music/albums` | `sort` = `added` (default), `title`, `artist`, `year`, `random`, `frequent`, `recent` (recently played); `genre=<name>`; `artist=<artistId>`; `starred=1`; `limit`, `offset` (web uses limit 120) | `{items: [Card(kind=album)], total}`. An unknown sort gives `400`. |
| `GET /api/music/albums/{id}` | | AlbumDetail (below). |
| `GET /api/music/albums/{id}/zip` | | ZIP download of the album. |
| `GET /api/music/artists` | `starred=1`, `limit`, `offset` (`sort` is ignored) | `{items: [Card(kind=artist)], total}`. The artist card poster is borrowed from an album. |
| `GET /api/music/artists/{id}` | | `{card: Card, albums: [Card], topTracks: [Track], appearsOn: [Card]}` |
| `GET /api/music/songs` | `starred=1`, `limit`, `offset` (`sort` is ignored) | `{items: [Track], total}` |
| `GET /api/music/tracks/{id}` | | Track |
| `GET /api/music/genres` | | `{genres: [{name: string, albums: int, songs: int}]}` |
| `GET /api/music/shuffle` | `source=all`, or `source=genre&genre=<name>`, or `source=artist&artist=<artistId>` | `{tracks: [Track]}`, a random queue. An unknown source gives `400 Unknown source`. |
| `GET /api/music/tracks/{id}/lyrics` | | `{lyrics: string, synced: bool, source: string, lines: [{t: float(sec), text: string}]}`. `source`: `"file"` (an .lrc sidecar or tag) or an LRCLIB lookup. `lines` is filled when `synced`. No lyrics gives `404 No lyrics`. |
| `POST /api/music/plays` | `{"trackId": int, "at"?: RFC3339}` | `204`. Records a play (scrobble) for "recently played" and `frequent` sorting. A non-track id gives `400 This isn't a song`. |
| `POST /api/music/star/{itemId}` | | `204`. Favorites a track, album or artist. Any other kind gives `400`. |
| `DELETE /api/music/star/{itemId}` | | `204` |
| `GET /api/music/playlists` | | `{items: [Playlist]}` |
| `POST /api/music/playlists` | `{"name": string, "trackIds"?: int[]}` | Playlist. An empty name gives `400 Enter a playlist name`. |
| `GET /api/music/playlists/{id}` | | `{playlist: Playlist, tracks: [Track + idx]}` |
| `PATCH /api/music/playlists/{id}` | `{"name"?: string, "append"?: int[] (track ids), "remove"?: int[] (positions), "order"?: int[] (positions)}` | Playlist. `order` is a permutation: `order[i]` is the **old position** placed at new position `i`. |
| `DELETE /api/music/playlists/{id}` | | `204`. A missing playlist gives `404 Playlist not found`. |

AlbumDetail:

```json
{ "card": Card, "artist": {"id": int, "name": string}, "year": int, "genres": [string],
  "durationMs": int, "trackCount": int, "quality": "Lossless · FLAC", "tracks": [Track], "starred": bool }
```

Playlist:

```json
{ "id": int, "name": string, "trackCount": int, "durationMs": int, "cover": string,
  "covers": [string], "updatedAt": string }
```

`covers` holds up to 4 album covers, for a mosaic.

Samples: `music-home.json`, `music-albums.json`, `music-album.json`, `music-artists.json`,
`music-artist.json`, `music-songs.json`, `music-genres.json`, `music-shuffle.json`,
`music-lyrics.json`, `playlists.json`, `playlist.json`, `playlist-create.json`, `playlist-update.json`.

### 7.3 Track streaming: `GET /api/tracks/{trackId}/stream`

| Param | Notes |
|---|---|
| accept | Comma-separated codecs the client can decode. Values: `flac`, `mp3`, `aac`, `alac`, `opus`, `vorbis`; `wav`, `aiff`, `ape` and `wv` are also known. If the source codec is listed, or `accept` is left out, the **original file** is served. |
| format | Transcode target when the source is not accepted: `aac` (default, ADTS `audio/aac`), `mp3` (`audio/mpeg`, 320 kbps), `opus` (`audio/ogg; codecs=opus`). Other values give `400 Unknown format`. |
| t | Start offset in seconds (float), for **seeking inside a transcoded stream**. An invalid value gives `400`. |
| mk | Media key, as an alternative to the header. |

The web app sends `?accept=<browser-supported list>&maxBitRate=0`; it never sends `format`, and
`maxBitRate` is ignored. Browsers typically get `accept=flac,mp3,aac,alac,opus,vorbis`.

Response headers:

| Response | Headers |
|---|---|
| Original file | `Accept-Ranges: bytes`, `Content-Length`, real `Content-Type` (`audio/flac`, `audio/mpeg`, `audio/mp4`…). Seek with Range. |
| Transcoded | `Accept-Ranges: none`, `Cache-Control: no-store`, `X-Vault-Transcode: 1`, `X-Content-Duration: <seconds remaining from t>`, no Content-Length. **The stream is not seekable.** To seek, reload with `&t=<sec>` and add `t` to the player's position. |

Remote clients may get music capped by the server setting `remoteMusic` (`"high"` by default) *(inferred)*.

---

## 8. Books, audiobooks, comics

### 8.1 Lists

- `GET /api/books/home` returns `{shelves: [{id, title, cards}]}`. Shelf ids: `reading`
  (in-progress), `want` (watchlist), `audiobooks`, `books`, `comics` (title "Manga & Comics"),
  `done` (finished). Only non-empty shelves are returned.
- `GET /api/books?kind=<kind>` returns `{items: [Card], total}`.

| Param | Notes |
|---|---|
| kind | **Required**: `book`, `audiobook` or `comic` (comic series). Missing or other values give `400 Unknown section`. |
| sort | `added` (default), `title`, `author`. Other values give `400 Unknown sort order`. |
| limit, offset | Paging. |

Samples: `books-home.json`, `books-audiobooks.json`, `books-comics.json`.

### 8.2 `GET /api/books/{id}`: BookDetail

Works for `book`, `audiobook`, `comic` (series) and `comic_volume` ids.

| Field | Type | Notes |
|---|---|---|
| card | Card | |
| kind | string | `book`, `audiobook`, `comic` or `comic_volume`. |
| authors | string[] | |
| narrator | string | |
| series | `{name: string, index: float}` \| null | Book series, or comic series for a volume. |
| description | string | |
| year | int | |
| lang | string | |
| files | BookFile[] | `{id: int (file id), format: string ("M4B","MP3","EPUB","CBZ"…), size: int, durationMs: int}`. For an audiobook, **ordered** parts. `[]` for a comic series. |
| seriesId | int | Parent comic series id for a volume, else `0`. |
| nextId | int | Next volume or book in the series, `0` if none. |
| readFileId | int | File id to open in a reader (ebook or comic volume), `0` otherwise. |
| progress | `{fraction, locator, positionMs, durationMs, finished}` \| null | Current user's progress. |
| want | bool | In the watchlist. |
| durationMs | int | Audiobook total, the sum of the files. |
| chapters | `{idx: int, title: string, fileId: int, startMs: int, endMs: int}[]` | Audiobook chapters. **`startMs` and `endMs` are on the whole-book timeline** (file offsets already added): file 2 of a 2×30 s book starts at `30041`. For files without embedded chapters, each file is one chapter. |
| volumes | VolumeCard[] | Comic series only: Card fields flattened, plus `pages: int`, `direction: "rtl"\|"ltr"`, `fileId: int`. |
| direction | string | Comic reading direction, `"rtl"` or `"ltr"`; `""` for non-comics. |

Samples: `book-audiobook.json` (an m4b with embedded chapters), `book-audiobook-multifile.json`
(2 mp3 parts), `book-audiobook-mp3.json`, `book-comic.json`, `book-comic-volume.json`.

### 8.3 Audiobook streaming: `GET /api/audio/{fileId}`

- Takes the same `accept`, `format`, `t` and `mk` parameters as `/api/tracks/{id}/stream`, with the
  same original-vs-transcode behavior.
- Example: an m4b with `accept=aac,mp3` returns `audio/mp4`, Range-capable. `accept=mp3` returns
  transcoded `audio/aac`, not seekable; use `t`.
- `fileId` comes from `BookDetail.files[].id`.
- Play the files **in `files` order** as one continuous book.

### 8.4 Audiobook progress

- Save with `PUT /api/progress/{audiobookItemId}`, where
  `{positionMs: <whole-book position>, durationMs: <BookDetail.durationMs>}`.
  The whole-book position is the cumulative duration of the previous files plus the position in the
  current file.
- Resume: `GET /api/progress/{id}`, or use `BookDetail.progress`.
- The web app restarts from 0 when `finished`, or when position ≥ 98 % or ≤ 30 s remain.
- Playback speeds offered by the web app: 0.75–3.0 in steps of 0.25. Skip buttons: back 15 s, forward 30 s.

### 8.5 Comics

| Method and path | Response |
|---|---|
| `GET /api/comics/{fileId}/pages` | `{count: int, direction: "rtl"\|"ltr", sizes: [[width, height], …]}` |
| `GET /api/comics/{fileId}/page/{n}` | The page image. **`n` is 0-based**. `Cache-Control: private, max-age=86400`. Out of range gives `404`. |
| `GET /api/comics/{fileId}/pages.zip` | All pages as a ZIP, for offline use. |

- The `fileId` is `VolumeCard.fileId`, or `readFileId` of a comic_volume.
- These endpoints need Bearer or cookie; `mk` does not work.
- Progress: `PUT /api/progress/{volumeItemId}` with `{"locator": "page:<1-based page>", "fraction": <(lastVisiblePage+1)/count>}`.

Sample: `comic-pages.json`.

### 8.6 E-books (low priority)

- Get the raw file with `GET /api/stream/{readFileId}` (EPUB, FB2, PDF and so on).
- Save the reader position via `PUT /api/progress/{bookId}` with `{locator, fraction}`. The web app
  uses EPUB CFI strings as the locator.

---

## 9. Events (SSE)

`GET /api/events?lang=en` (auth required) returns a `text/event-stream` with `X-Accel-Buffering: no`.

```
retry: 5000
: connected

: ping
```

- Comment pings arrive about every 30 s.
- Named events have the form `event: <name>\ndata: <json>\n\n`. The web app subscribes only to
  **`library.updated`** and reloads the current screen when it arrives. The server binary also
  contains `progress.updated` and `scan.done`.
- In testing (scan with new files, progress writes) **no named events were emitted** on this
  library-only build; only pings arrived. Treat SSE as an optional refresh hint and do not depend on it.

Sample: `sse-stream.txt`.

---

## 10. Other endpoints

These are admin, settings and management endpoints, documented briefly. Most are not needed by TV apps.

| Endpoint | Notes |
|---|---|
| `GET /api/settings` (admin) | `{remoteQuality: "1080", remoteMusic: "high", autoSubtitles: bool, subtitleLangs: [..], languages: [..], metadataLanguage: "ru", subtitlesAvailable: bool}`. `PUT` updates it. A kid profile gets `403`. |
| `GET /api/users` (admin) | `[{id, name, avatar, hasPassword, isAdmin, isKid, maxRating}]` |
| `POST /api/users` (admin) | `{name, avatar, password?, isAdmin?, isKid?, maxRating?}` returns `201` with the user. `PATCH /api/users/{id}` takes the same fields, all optional; `DELETE /api/users/{id}` deletes the user. |
| `GET/POST/DELETE /api/me/app-password` | GET returns `{exists: bool, createdAt: string\|null}`. POST returns `{password: string}`, a 16-character password for Subsonic and OPDS apps. DELETE returns `204`. `DELETE /api/users/{id}/app-password` (admin) resets another user's. |
| `GET /api/stats`, `/api/stats/storage` (admin) | Usage statistics. |
| `/api/files/*` (admin) | File manager. Not for clients. |
| `/api/device-copies/*` | Server-side preparation of offline copies (`actions.toDevice`). Not covered here. |

---

## 11. Client implementation notes

### Auth

1. On first launch, generate a stable `deviceId` (a UUID string; it must match `[A-Za-z0-9-]{8,64}`) and keep it.
2. Show the profile picker from `GET /api/profiles` (no auth). Draw the avatar as a gradient from
   §2.3. If `hasPassword`, ask for the password.
3. Call `POST /api/auth/token` with
   `{userId, password?, device: {id: deviceId, name: <device name>, model, version: <app version>}}`.
   Store `token` securely, keyed by `serverId` from `/api/health` and `userId`.
4. Send `Authorization: Bearer <token>` and `Accept-Language: en|ru` on **every** request,
   including images, HLS and streams where the player allows it. Send JSON bodies with
   `Content-Type: application/json`. Never send an `Origin` header.
5. Validate on launch with `GET /api/me`. On `401` anywhere, return to the profile picker.
6. Switching profile: you may keep one token per profile. Sign-out is `POST /api/logout`.
7. For players that cannot add headers (AVPlayer), call `POST /api/auth/media-key` and append
   `?mk=<key>` to `/api/stream`, `/api/hls`, `/api/audio` and `/api/tracks` URLs. Refresh the key when it
   has less than about 1 h of its 12 h left.

### Image URLs

- `url = baseURL + card.poster` (or `backdrop`, `logo`, `cover`), when the value is non-empty and starts with `/`.
- Images always need the Bearer header; `mk` is not accepted. Cache them aggressively (7-day max-age).
- An empty string means no image; draw a placeholder. Do not probe for logos.

### Video playback, step by step

1. **Pick the file.**
   - Movie: `GET /api/items/{movieId}`, then use `files[0].id`. A movie with several files has
     several versions; let the user pick.
   - Episode: `GET /api/items/{episodeId}`, then `files[0].id`. For a series, `next` says which
     episode to start with.
2. **Find the resume point** with `GET /api/progress/{itemId}`. Use `positionMs` unless `finished`.
3. **Call `POST /api/play/{fileId}`** with `startSec` (seconds) and `caps`:
   - tvOS (AVPlayer):
     `{videoCodecs:["h264","hevc"], audioCodecs:["aac","ac3","eac3"], containers:["mp4","mov"], hevcNeedsHvc1:true}`.
     Add `"av1"` only on hardware that decodes it.
   - Android TV and Android (ExoPlayer):
     `{videoCodecs:["h264","hevc", …from MediaCodecList], audioCodecs:["aac","mp3","ac3","eac3","opus","flac"] (filter by device support and passthrough), containers:["mp4","mkv","webm"]}`.
     Including `mkv` enables direct play of MKV.
   - Add `quality` (`auto`, `original`, `1080`, `720`, `480`) and `audioIndex` when the user chose them.
4. **Play the `url`.**
   - `mode == "direct"`: open `baseURL + url` (`/api/stream/{fileId}`) as a progressive source,
     with the Bearer header (ExoPlayer `DefaultHttpDataSource.Factory().setDefaultRequestProperties`)
     or `?mk=`. Seek to `startSec` yourself. The player position is the file position.
   - `mode == "remux"` or `"transcode"`: HLS. **Recommended:** load `baseURL + url + "?mk=" + key`
     **without** headers. You get a complete VOD playlist with signed segment URIs, so native
     seeking works across the whole remaining timeline. The alternative is the Bearer header on
     every request, which gives a growing EVENT playlist.
     - File position = `startSec` (from the response) + player position.
     - Start a keepalive timer: `PUT /api/hls/{session}` **every 20 s**. Take the session from the
       url: `/api/hls/{session}/index.m3u8`.
     - Seeking before `startSec` (or beyond the EVENT window), changing audio track or changing
       quality: call `/api/play` again with the new `startSec`, `audioIndex` or `quality` and
       `replaceSession: <session>`, then swap the player item.
     - On `404` from keepalive, or a playback error, re-issue `/api/play` without `replaceSession`.
     - On exit, `DELETE /api/hls/{session}`. Sessions are limited to 2 per profile; a third gives `429`.
5. **Subtitles.** Use `subtitles[]` from the play response. Fetch the `url` (VTT) with the Bearer
   header and side-load it. Subtract nothing for direct play. For HLS, cue time `c` maps to player
   time `c - startSec`.
6. **Progress.** Do what the web player does: `PUT /api/progress/{itemId}` with
   `{positionMs: <file position ms>, durationMs: <response durationMs>}`:
   - **every 10 s while playing**, skipping the write if the position moved less than 0.5 s;
   - on pause;
   - on app backgrounding;
   - on exit, as a final write.

   Use the **item id** (movie or episode), not the file id. The server sets `finished` near the end.
   Use `POST /api/items/{id}/watched` for explicit "mark watched".
7. Autoplay next episode: refetch `GET /api/items/{seriesId}` and read `next`, or walk
   `seasons[].episodes[]`.

### Music playback, step by step

1. Build the queue from album, playlist, artist top tracks, songs or shuffle. Each element is a
   Track with `id` (track id), `durationMs` and `cover`.
2. Stream URL:
   `baseURL + "/api/tracks/{id}/stream?accept=<codecs the device decodes>"`, with the Bearer header
   or `&mk=<key>`.
   - Apple: `accept=aac,mp3,alac,flac`. FLAC is supported by AVPlayer on tvOS 11+.
   - Android: `accept=aac,mp3,flac,opus,vorbis`.
   - To force a smaller stream, pass an `accept` that excludes the source codec, plus `&format=aac|mp3|opus`.
3. If the response has `X-Vault-Transcode: 1` (no Range support), implement seeking by reloading
   with `&t=<seconds>` and offsetting the displayed position by `t`. Original files support normal
   Range seeking.
4. **Scrobble once per track** with `POST /api/music/plays {"trackId": id}`. The web app sends it
   after **min(30 s, duration/2)** of actually-played time. There is no per-track progress.
5. Lyrics: if `hasLyrics`, call `GET /api/music/tracks/{id}/lyrics`. Synced `lines[].t` is in seconds.
6. Favorites: `POST`/`DELETE /api/music/star/{trackId|albumId|artistId}`.

### Audiobook playback, step by step

1. `GET /api/books/{audiobookId}` gives `files[]` (ordered parts), `chapters[]` (book-timeline ms),
   `durationMs` and `progress`.
2. Resume position `P` (ms) = `progress.positionMs`. Use 0 if `finished`, if `P ≥ 0.98 × durationMs`,
   or if `durationMs − P ≤ 30 000`. Find the part `i` such that the sum of `files[0..i-1].durationMs`
   ≤ `P` < sum through `i`; the in-file offset = `P − sum(files[0..i-1].durationMs)`.
3. Queue the parts as `baseURL + "/api/audio/{files[i].id}?accept=aac,mp3,…"`, with Bearer or `&mk=`.
   M4B/AAC plays as the original file; other codecs follow the same transcode rules as music,
   including `t` for seeking.
4. Chapter navigation: `chapters[].startMs` is on the whole-book timeline. Map it to a part and offset the same way.
5. **Progress:** `PUT /api/progress/{audiobookId} {positionMs: <whole-book ms>, durationMs: <book durationMs>}`:
   - **every 10 s while playing**, skipping the write when the position is unchanged at whole-second granularity;
   - on pause or stop;
   - on app backgrounding.
6. Show the in-progress list from the `reading` shelf of `/api/books/home` or `/api/home`.

### Comics (optional for TV)

1. `GET /api/books?kind=comic` lists the series. `GET /api/books/{seriesId}` returns `volumes[]`,
   each with `fileId`, `pages` and `direction`.
2. `GET /api/comics/{fileId}/pages` gives the page sizes. Load
   `GET /api/comics/{fileId}/page/{0-based n}` with the Bearer header.
3. Save with `PUT /api/progress/{volumeId} {"locator":"page:<1-based>","fraction":<(n+1)/count>}`.

### Misc

- Default page size: the web app uses `limit=120` with `offset` paging, everywhere `total` is returned.
- All list, detail and search responses are already filtered for kid profiles (`maxRating`).
  Unrated content is invisible to kids.
- "Remote" clients (outside the LAN, as determined by the server) get quality capped to
  `settings.remoteQuality` (default 1080). `quality.remote` in play responses reflects this.
  Passwordless profiles cannot sign in remotely.

# Antresol for Apple TV

A native tvOS app for [Antresol](https://github.com/sidun-av/antresol), the self-hosted home
media server: films, TV shows, music, audiobooks and comics on the big screen. It talks to
your own server only. SwiftUI, tvOS 17+, English and Russian.

## Features

- **Onboarding**: enter the server as a host, `host:port` or URL (port 8420 by default). Then
  "Who's watching?" profile picker with avatar gradients, password entry for protected profiles,
  and kid profiles. Tokens are kept per server and profile in the Keychain, and the session is
  restored at launch.
- **Home**: a hero tinted with the artwork's colour, Continue Watching (plays at once), and the
  server's shelves: recently added, new episodes, Want to Watch, reading, recently played.
- **Movies and TV Shows**: poster grids with sort pills (recent, title, year) and paging.
- **Details**: movie, show and episode pages offer Play, Resume and Restart, plus watchlist and
  watched toggles. Show pages have seasons and episodes; all of them list cast, versions,
  tracks and file info.
- **Video player**: AVKit with the native transport bar and Info panel.
  - Direct play when Apple TV can decode the file; otherwise the server remuxes or transcodes
    to HLS, and the whole timeline stays seekable.
  - Resume prompt.
  - Audio, subtitle and quality menus. Text subtitles are side-loaded, image subtitles are
    burned in.
  - Up Next with a countdown.
  - Progress is synced every 10 s, and items are marked watched at 92 %.
- **Music**: Listen Now, albums, artists, songs, genres and playlists.
  - Gapless queue with shuffle and repeat, favourites, and play reporting.
  - Now Playing with synced lyrics.
  - Background audio, with Control Center and remote controls.
- **Books**: Reading Now, audiobooks, and manga and comics.
  - Audiobooks play as one book across parts, with chapters, speed, a sleep timer and
    position sync.
  - The comic reader shows single pages or spreads and supports right-to-left.
- **Search**: across every library, with browse tiles.
- **Settings** (the profile tab):
  - Switch profile, or sign out (which revokes the device token on the server).
  - Default video quality, audio and subtitle languages, and autoplay of the next episode.
  - App language: System, English or Русский.
  - Server address and version, and Change Server (hidden for kid profiles).
  - Version and acknowledgements.
- **Top Shelf**: when the app is in the top row, the Home screen shows the profile's Continue
  Watching and Recently Added. Selecting a tile opens its page; Play starts it.
- **Deep links**: `antresol://item/{id}` opens an item's page, and `antresol://play/{id}` plays it.

## Requirements

- An Antresol server, v0.3.0 or newer, reachable from the Apple TV.
- Xcode 16.4 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build the app.
- Swift 6.0+ (any platform, Linux included) to build and test `AntresolKit`.

## Build and run

```sh
brew install xcodegen
xcodegen generate            # creates Antresol.xcodeproj (not committed)
open Antresol.xcodeproj      # run the AntresolTV scheme on an Apple TV or the simulator
```

Command-line build, as CI does it:

```sh
xcodebuild -project Antresol.xcodeproj -scheme AntresolTV \
  -destination 'generic/platform=tvOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

To run on a device, set your team for the `AntresolTV` and `TopShelf` targets.

- Both targets use the App Group `group.app.antresol.tv` and the Keychain group
  `app.antresol.shared`, so register them for your team or change them. They appear in
  `AntresolTV/AntresolTV.entitlements`, `TopShelf/TopShelf.entitlements` and
  `Shared/SharedSession.swift`.
- Without these entitlements the app still works; only the Top Shelf stays on the static
  brand image.

### Tests

```sh
cd AntresolKit
swift test                              # unit tests: decode every API sample, client, playback logic
ANTRESOL_TEST_SERVER=1 swift test       # plus integration tests against http://127.0.0.1:8420
```

`ANTRESOL_TEST_SERVER` can also be a server address. Credentials come from `ANTRESOL_TEST_USER`
and `ANTRESOL_TEST_PASSWORD` and default to `1` and `admin123`. The integration tests undo every
change they make.

UI screenshot tests (`AntresolTVUITests`) run on a tvOS simulator against a mock server:

```sh
python3 scripts/mock-server.py --port 8421 &
xcodebuild test -project Antresol.xcodeproj -scheme AntresolTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

## Architecture

```
AntresolKit/          Swift package, Foundation only (builds and tests on Linux)
  Models/             Codable API models with tolerant decoding
  Networking/         APIClient (async/await), APIError, ServerURLs, ServerAddress, TokenStore
  Playback/           VideoPlaybackSession, MediaKeyStore, ProgressReporter, PlayQueue,
                      AudiobookTimeline, UpNext, WebVTT
  Integration/        DeepLink (antresol:// URLs), TopShelfPlan (Top Shelf sections from /api/home)
AntresolTV/           The tvOS app
  App/                AntresolTVApp, AppState (session phases, language, deep links), Route
  Design/             Theme tokens, button styles, cards, shelves, hero, settings rows
  Services/           ImagePipeline (authenticated, cached artwork), Keychain token store,
                      AppSettings, AppLanguage, DeviceIdentity
  Views/              Onboarding, Shell (tab bar), Home, Library, Detail, Search, Music,
                      Books, Settings
  Playback/           PlaybackCoordinator, VideoPlayerModel/View, menus, subtitles, Up Next
  Audio/              AudioPlayer (app-wide AVQueuePlayer), Now Playing screen and system controls
TopShelf/             TVTopShelfContentProvider extension and artwork downloader
Shared/               Code compiled into both the app and the extension (Keychain, shared session)
AntresolTVUITests/    Screenshot tests against scripts/mock-server.py
```

- **Logic lives in the kit.** Everything that does not need an Apple UI framework sits in
  `AntresolKit`, so it is unit-tested on Linux in CI. This covers API calls, playback session
  rules, progress timing, queueing, audiobook timing, subtitles, deep links and the Top Shelf
  plan.
- **Auth.** Each profile signs in with `POST /api/auth/token` and gets a device token. Every
  request sends `Authorization: Bearer` and `Accept-Language`, and so do image requests. Player
  URLs carry a short-lived media key (`?mk=`) instead, so AVPlayer needs no headers.
- **State.** `AppState` (`@Observable`) owns the server connection and the session phase.
  The signed-in shell has one `PlaybackCoordinator` for video and one `AudioPlayer` for music
  and audiobooks. Each tab has its own `NavigationStack`.
- **Top Shelf.** While a profile is signed in, the app writes the server, profile and language
  to the App Group defaults, and the token to the shared Keychain group. The extension reads
  them and fetches `/api/home`. It downloads the artwork with the Bearer header into the shared
  container, because the system cannot fetch authenticated images. Signing out clears the
  shared session.

See [docs/API.md](docs/API.md) for the server API, [PLAN.md](PLAN.md) for the original plan
and [NOTES.md](NOTES.md) for the per-milestone hand-off log, decisions and known gaps.

## CI

`.github/workflows/ci.yml` runs three jobs:

- `swift build` and `swift test` for the kit in a Swift 6.0.3 Linux container.
- `xcodegen` and `xcodebuild` for the tvOS Simulator (app and Top Shelf extension).
- The UI screenshot tests on a tvOS simulator. Their screenshots are uploaded as an artifact.

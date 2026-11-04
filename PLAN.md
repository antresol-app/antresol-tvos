# Antresol for Apple TV — plan

Native tvOS client for the self-hosted Antresol server (v0.3.0+). Look and feel follow the
existing Antresol apps (iOS + web): pure black background, white type (SF Pro), pill-shaped
top navigation, a full-bleed hero tinted with the artwork's colour, white "Play" pill button,
rounded poster cards with resolution / audio badges, purple brand gradient (#3a1c8c → #9b2fc9).

## Layout
- `AntresolKit/` — Swift package, Foundation only (builds and tests on Linux too):
  models, `APIClient` (token auth via `/api/auth/token`), image/stream URL building,
  playback session (HLS start / keepalive / stop), progress reporting.
- `AntresolTV/` — the tvOS SwiftUI app (XcodeGen `project.yml`, tvOS 17+).
- `.github/workflows/ci.yml` — `swift test` on Linux + `xcodebuild` for the tvOS simulator on macOS.

## Scope (in order)
1. Onboarding: server address (with discovery hints), profile picker, password entry, kid profiles.
2. Home: hero carousel, Continue Watching, recently added shelves, watchlist.
3. Movies / TV Shows grids with sort; detail pages (seasons, episodes, cast, badges).
4. Video player: AVPlayer + HLS, resume, progress sync, audio & subtitle tracks, next episode.
5. Music: albums, artists, playlists, songs, shuffle; Now Playing with lyrics; background audio.
6. Audiobooks: chapters, speed, sleep timer, position sync. Comics: page viewer.
7. Search, Settings (switch profile, sign out, server info), Top Shelf extension (later).

## Build
    brew install xcodegen && xcodegen generate && open Antresol.xcodeproj

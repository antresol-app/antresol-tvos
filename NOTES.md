# Hand-off notes

Running log between milestones. Newest entry last.

## Milestone 1 — AntresolKit, app skeleton, CI

### What exists
- `AntresolKit/` (Swift package, tools 5.10, Foundation only; builds and tests on Linux with Swift 6.0.3).
  - `Models/`: Codable models for every endpoint in docs/API.md. Decoding is tolerant: identifiers are
    strict, every other field falls back to a default (`""`, `0`, `[]`, `nil`) when missing or mistyped
    (`Support/TolerantDecoding.swift`). Flattened objects (`ItemDetail`, `EpisodeCard`, `VolumeCard`) hold a
    `card: Card` and forward Card fields via `@dynamicMemberLookup` (`detail.title`).
    `ItemKind` / `PlaybackMode` are open string structs so unknown server values survive.
  - `Networking/APIClient*.swift`: one method per endpoint (auth/profiles/me/devices, home, items, item,
    search, progress, watched, watchlist, play/keepalive/stop, subtitles, OpenSubtitles search, all music
    endpoints incl. playlists CRUD/star/lyrics/plays/shuffle, books home/list/detail, comic pages).
    Sends Bearer + `Accept-Language` (en|ru) on every request, `Content-Type: application/json` only with a
    body, never `Origin`. Errors map to `APIError` (`unauthorized`, `server(status,message,code,retryAfter)`, …).
    `HTTPTransport` protocol lets tests stub the network.
  - `ServerURLs`: image/stream/HLS/track/audio/subtitle/comic-page URL builders (`?mk=` where allowed).
    `client.authorizationHeaders` is what image loaders must attach (images need Bearer).
  - `ServerAddress.normalize`: "192.168.1.10" -> `http://192.168.1.10:8420`.
  - `TokenStore` protocol keyed by `CredentialKey(serverId, userId)`; `InMemoryTokenStore` for tests.
  - Playback: `MediaKeyStore` (actor, caches mk, refreshes with < 1 h left), `VideoPlaybackSession`
    (actor: `/api/play` with Apple TV caps, mk-signed URL, 20 s keepalive, `replaceSession` on re-start,
    expiry callback on keepalive 404, DELETE on stop), `PlaybackSource` (player <-> file time mapping,
    `canSeekInPlayer`), `ProgressReporter` (actor: 10 s periodic PUT when moved >= 0.5 s, `flush()` for
    pause/background/exit), `AudiobookTimeline` + `ResumePolicy` (whole-book <-> part mapping, web resume
    rules), `ComicProgress`, `ScrobblePolicy`, `WebVTT` parser with HLS offset shifting, `Timestamp`.
  - Tests: `SampleDecodingTests` decodes every `Tests/AntresolKitTests/Samples/*.json` (copied from
    api-samples; a new sample without a registered decoder fails the test). `ClientTests` cover headers,
    error mapping, query encoding, media-key caching, progress reporter and HLS session replace/stop/expiry.
    `IntegrationTests` run against a live server only when `ANTRESOL_TEST_SERVER` is set
    (`1` = http://127.0.0.1:8420, or an address; `ANTRESOL_TEST_USER`/`ANTRESOL_TEST_PASSWORD` default to
    1/admin123). They revert what they change (progress, watchlist, star, temporary playlist) and use the
    fixed device id `antresolkit-integration-tests`.
    Run: `cd AntresolKit && ANTRESOL_TEST_SERVER=1 swift test` — all 48 pass locally against the 0.3.0 server.
- `project.yml` (XcodeGen): target `AntresolTV`, bundle id `app.antresol.tv`, tvOS 17.0, local package
  dependency, Swift 5 language mode, `Info.plist` checked in (ATS arbitrary loads + local networking,
  `CFBundleLocalizations` en/ru, dark style, `UIBackgroundModes: audio` for later music playback).
  The generated `Antresol.xcodeproj` is git-ignored.
- `AntresolTV/`: `AntresolTVApp` (entry), `AppState` (@Observable: phases launching / needsServer /
  serverUnreachable / needsProfile / signedIn; `bootstrap`, `connect(to:)`, `signIn`, `switchProfile`,
  `signOut`, `handleUnauthorized`), `AppSettings` (UserDefaults: server URL, serverId, last user),
  `KeychainTokenStore`, `DeviceIdentity` (stable UUID + model identifier), `Theme` (DESIGN.md tokens,
  avatar gradients), `RootView` + `SplashView` (brand splash with status line).
- Assets: `App Icon & Top Shelf Image.brandassets` with 3-layer (Back/Middle/Front) icon 400x240 @1x/@2x,
  App Store stack 1280x768, Top Shelf 1920x720 and Wide 2320x720 @1x/@2x; `LogoMark` image;
  `LaunchBackground` (black). Regenerate with `node scripts/render-brand-assets.js <out>` (Playwright).
- Localisation: `Localizable.strings` + `InfoPlist.strings` in en.lproj / ru.lproj (plain .strings,
  not a string catalog, so XcodeGen needs no special handling). Add every new UI string to both files.
- CI (`.github/workflows/ci.yml`): `kit-linux` (swift:6.0.3-noble container, build + test; integration
  tests skip) and `app-tvos` (macos-15, Xcode 16.4, xcodegen, xcodebuild for the tvOS Simulator).

### Decisions
- Swift 5 language mode in both package (tools 5.10) and app; models and actors are still `Sendable`.
- `URLSessionTransport` wraps `dataTask` in a continuation (works the same on Linux corelibs and Apple).
- Query strings are encoded strictly (only unreserved characters literal) so "R&B" / "+" survive Go's decoder.
- Playback always signs player URLs with the media key (complete VOD playlists for HLS, no headers needed).
- Lyrics `404 No lyrics` is returned as `nil`, not an error.

### Known gaps (for later milestones)
- The app UI is only the splash/status screen; onboarding (server entry, profile picker, password),
  the shell and all content screens start in milestone 2. `AppState`'s connect/sign-in/sign-out API is
  ready for them.
- SSE (`/api/events`) is not wrapped (spec says it is an optional refresh hint and emits nothing on 0.3.0);
  `ServerURLs.events` exists if needed.
- No image loader yet (milestone 2 should add one that sends `client.authorizationHeaders` and caches).

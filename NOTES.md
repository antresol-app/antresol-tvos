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

## Milestone 2 — Design system, onboarding, profiles, shell

### What exists
- **Design system** (`AntresolTV/Design/`):
  - `Theme`: DESIGN.md colours, gradients (brand, `grad-1..8` avatars, title-seeded placeholder
    gradients via a stable FNV hash), typography scaled for the 1920x1080 pt TV canvas, radii,
    layout constants (80 pt margins, card widths), motion (ease-out curve, focus 1.07 / card lift 1.04).
  - `PillButtonStyle(.primary|.glass)`: white "Play" pill and dark glass pill (turns white when
    focused). `CardButtonStyle` publishes focus as `\.isCardFocused` so a card lifts only its
    artwork (`cardLift`: scale, shadow, light rim) while the caption shifts down, like tvOS lockups.
  - Components: `RemoteImage`, `CardArtwork` (placeholder gradient + title overlay when there is
    no image or it fails), `PosterCard` (2:3 posters, 1:1 album/playlist/audiobook covers, round
    artists; progress bar; title, year/context line, badges), `WideCard` (16:9 backdrop → poster,
    progress), `ShelfRow` (title + horizontal `LazyHStack`, focus section, unclipped lift),
    `HeroView` + `HeroBackground` (backdrop with fades, glow tinted with the artwork's average colour
    via CoreImage, title-seeded fallback), `AvatarView`, `BadgeRow`, `ProgressBar`,
    `ErrorStateView`, `EmptyStateView`. `ItemKind.displayName` gives localized kind names.
- **Images** (`Services/ImagePipeline.swift`): Bearer-authenticated loads, ImageIO downsampling to
  the on-screen size, `NSCache` (192 MB cost limit) + disk cache in `Caches/Artwork` (7-day reuse,
  stale copy used offline, files untouched for 30 days evicted at launch), in-flight de-duplication.
- **Onboarding**: `ServerEntryView` (host, host:port or URL; default port 8420; validated with
  `/api/health`; friendly errors), `ProfilePickerView` ("Who's watching?", avatar tiles with lock for
  protected profiles, server version + address line, Change Server), `PasswordEntryView`
  (SecureField, server error text such as "Wrong password", Menu = cancel).
  Server URL and tokens are in the Keychain (`Keychain` helper); device registers as "Apple TV"
  with a stable per-install UUID. Launch restores the session (`/api/me`); any 401 returns to the
  profile picker (`AppState.message(for:)` routes errors).
- **Shell** (`MainShellView`): native tvOS top tab bar — Search (icon), Home, Movies, TV Shows,
  Music, Books, and the profile tab (user name). Each content tab gets `TabNavigation`
  (NavigationStack + `Route` destinations). The profile tab (`AccountView`) shows the user, role,
  server and version, and Switch Profile / Change Server / Sign Out (with confirmation).
- **Home** (`Views/Home`): hero (first `hero` card, else first Continue Watching item; eyebrow
  "NEW IN LIBRARY · MOVIE"; Play/Resume + Details), Continue Watching as wide cards, every other
  non-empty shelf as poster cards in server order, loading / error (retry) / empty states. Home
  refreshes whenever it reappears so Continue Watching stays current.
- **Detail route**: `Route.item(Card)` → `ItemDetailView` stub (tinted header, kind, title, meta,
  badges; overview, runtime, rating and genres from `/api/items/{id}` for video kinds).
- **UI screenshots in CI**: job `ui-screenshots` runs `AntresolTVUITests/ScreenshotTests` on a tvOS
  simulator against `scripts/mock-server.py` (serves the recorded samples, generates gradient
  artwork). Screenshots are uploaded as an artifact and also printed as base64 JPEG lines
  (`SHOT <name> <data>`) in the job log, because artifact blob downloads are blocked from the agent
  sandbox. Decode with: `gh api repos/sidun-av/antresol-tvos/actions/jobs/<id>/logs` and
  base64-decode each `SHOT` line. The job is `continue-on-error` (simulator flakiness must not block).
  DEBUG-only launch arguments used by it: `-AntresolResetSession YES`, `-AntresolServerURL <addr>`.

### Decisions
- Native `TabView` top tab bar instead of a hand-built pill nav: on tvOS 17 it already renders as a
  centred glass pill with a white selected pill, handles focus and hides on scroll. The brand logo
  is therefore not in the nav bar (it is on onboarding screens and the splash).
- Protected profiles always ask for their password on the picker even when a token is stored, so a
  kid cannot walk into the admin profile; passwordless profiles reuse their stored token.
- Hero "Play/Resume" opens the detail route for now; milestone 4 should wire it to the player.
- Shelf titles come from the server (already localized via Accept-Language); shelf "see all"
  chevrons are omitted until the category pages exist.

### Known gaps
- Search, Movies, TV Shows, Music and Books tabs show a "coming soon" placeholder
  (`SectionPlaceholderView`) — milestones 3 and 5 replace them.
- `ItemDetailView` is a stub: no seasons/episodes, cast, versions, watchlist or play actions (M3/M4).
- Hero is a single item, not a carousel.

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

## Milestone 3 — Browse, details, search, watchlist

### What exists
- **Movies / TV Shows tabs** (`Views/Library`): page title with item count, `SegmentedPill` sort
  (Recently Added / By Title / By Year, remembered per section in `UserDefaults`
  `library.sort.<kind>`), six-column 2:3 poster grid. `LibraryModel` pages `/api/items` 60 at a time,
  loading the next page when a card within the last 18 appears; duplicates across pages are dropped.
  Refreshes in place on reappear and after playback (progress bars stay current).
- **`SegmentedPill`** (`Design/Components`): glass capsule, selected option = white pill. Selection
  changes on click, not on focus, so moving focus up from a grid never re-sorts by accident.
- **Video detail** (`Views/Detail/VideoDetailView` + `VideoDetailModel`), used for movie, series,
  season (opens its series with that season selected) and episode cards:
  - Artwork-tinted header (`HeroBackground`), eyebrow (kind, "TV SHOW", or the episode's
    "Show · Season 1, Episode 2" line), huge title, meta line (year · N seasons · runtime or file
    duration · age rating · genres), badges, 3-line overview, resume bar with "N min left".
  - Movie/episode actions: Play / Resume (from `GET /api/progress`), Restart, Watchlist toggle
    (movies), Watched toggle (`POST /api/items/{id}/watched`), Go to Show (episodes).
  - Series actions: "Play S1, E1" / "Resume S1, E2" (server `next`, else first episode),
    Watchlist, series-wide Watched toggle.
  - Seasons: season pill + horizontal row of 16:9 `EpisodeCardView`s (progress bar, watched
    check mark, "E2 · 20 min", title, 2-line overview). Click opens the episode page; long press
    (context menu) offers Play/Resume, Play from Beginning and Mark as Watched/Unwatched.
  - Cast row (initials avatars, focusable so the row scrolls), About panel (full overview,
    original title, genres, rating, versions, video, audio and subtitle tracks, file name/size);
    the panel is focusable so the page can scroll down to it.
  - Action errors show in red under the buttons; 401 routes to the profile picker as before.
- **Watchlist**: toggled from movie and series pages; Home's "Want to Watch" shelf (server shelf
  `watchlist`) reflects it because Home reloads when it reappears.
- **Search tab** (`Views/Search`): native `.searchable` field and tvOS keyboard; Browse tiles
  (Movies, TV Shows, Music, Books, Audiobooks, Manga & Comics) switch tabs while the field is empty;
  typing searches `/api/search` after a 300 ms pause (each keystroke cancels the previous search).
  Results are shelves: Movies, TV Shows, Artists, Albums, Songs (open their album), Audiobooks,
  Books, Comics; "No results" state.
- **Playback entry point** (`Playback/PlaybackCoordinator`): every Play/Resume/Restart (hero, detail,
  episode menu) calls `PlaybackCoordinator.play(card, from: .resume | .beginning)`; the shell
  presents `VideoPlayerView` full screen. `VideoPlayerModel` resolves series to their next episode,
  reads the resume point, starts `VideoPlaybackSession` (caps, media key, keepalive, expiry
  restart), plays in `AVPlayerViewController` with title/subtitle/overview metadata, reports
  progress every 10 s via `ProgressReporter`, flushes and deletes the HLS session on close, and
  closes itself at the end. `completedSessions` lets Home, grids and detail pages refresh.
- Plurals (`%lld movies/shows/seasons/episodes`) are in `Localizable.stringsdict` (en, ru).
- Mock server: series list, season/episode details, progress, watchlist/watched writes. UI test
  `test03BrowseDetailsAndSearch` captures Movies, movie detail + About, TV Shows, series detail,
  episodes, episode detail, Search and search results.

### Decisions
- Episode cards open the episode page (overview, Resume/Restart, watched) rather than playing at
  once; quick play is in the long-press menu.
- No "related" row: the server API has no related/similar endpoint.
- Cast has no portraits in the API, so cells are gradient initials avatars.
- The media key is cached per signed-in token in `PlaybackCoordinator`.

### Known gaps
- Player is the basic one: no audio/subtitle/quality menus, no side-loaded VTT, no up-next or
  skip-intro; HLS seeks beyond the transcoded range rely on AVPlayer (milestone 4 adds
  `replaceSession` seeking and track menus).
- Music and Books tabs still show the "coming soon" placeholder; album/artist/book cards (including
  search results) open `ItemSummaryView` (header only) until milestone 5.
- No "see all" pages for Home shelves; no filter by genre in the grids (the API has none).

## Milestone 4 — Video player

### What exists
- **Full-timeline playback** (kit, `VideoPlaybackSession.start(at:options:)`): the server is asked
  for the whole file (`startSec` 0) and the player seeks to the resume point itself. Direct play
  always works that way; for HLS the media-key playlist is a complete VOD playlist from 0, and the
  server produces any segment on demand (checked on the real server for remux and transcode: a
  segment 40 s in arrives in ~0.3 s remux / ~1 s transcode). So the native transport bar can seek
  anywhere, backwards included, without re-requesting. Only a growing (EVENT) playlist
  (`hlsComplete` false) is requested at the position, replacing the first session.
  `PlaybackSource.startPosition` / `initialPlayerSeek` carry the seek.
- **Caps** (`VideoPlayerModel.caps`): containers mp4/mov/m4v (no mkv/webm: AVPlayer cannot open
  them, so the server remuxes to HLS), h264 + hevc/av1 only where `VTIsHardwareDecodeSupported`
  says so (max height 1080 without an HEVC decoder), aac/ac3/eac3, `hevcNeedsHvc1`.
- **Player screen** (`Playback/VideoPlayerView`, `VideoPlayerModel`):
  - Preparing view over the tinted artwork; **resume prompt** ("Resume from 12:34" / "Start Over",
    progress bar, "N min left") for `StartPoint.ask` when the saved position is ≥ 5 s.
  - `AVPlayerViewController` with the native transport bar and Info panel; `externalMetadata`
    has title, context line, description, genre, rating and the poster artwork (loaded through
    `ImagePipeline` with the Bearer header).
  - **Transport-bar menus** (`PlayerMenus`, `transportBarCustomMenuItems`): Audio (server tracks,
    re-plays with `audioIndex` at the current position), Subtitles (Off, text tracks side-loaded,
    image tracks burned in with `burnSubtitle`), Quality (Auto (applied) / Original / 1080p / 720p /
    480p, re-plays with `quality`). Changes replace the HLS session (`replaceSession`) and keep the
    position and play/pause state; a failed change shows a banner instead of stopping playback.
  - **Subtitles**: VTT downloaded with the header (`subtitleCues`, retries `Retry-After`), cues on
    the file timeline looked up at `startSec + playerTime`, rendered by `SubtitleOverlayView` in
    `contentOverlayView` (white semibold on a dark plate, lifted above the transport bar when
    paused).
  - **Preferences** (`PlayerPreferences`, UserDefaults): last audio language, last subtitle
    language (or off), quality and `autoplayNext` (default on; settings UI is milestone 6).
    Language codes are normalised to two letters so "eng" and "en" match.
  - **Progress**: `ProgressReporter` every 10 s, plus a flush on pause, when the app leaves the
    foreground and a final write on close (the full duration when the video ended). The final
    write is awaited before the reporter stops (no racing Task).
  - **Up Next** for episodes: the series' seasons give the next episode (`UpNext.episode(after:)`);
    an `AVContentProposal` is attached at `UpNext.proposalTime` (25 s before the end, not before
    80 %) and shown by `UpNextProposalViewController` (still, "UP NEXT", title, synopsis,
    "Play in N" countdown to the end of the episode, Cancel). Play, or reaching the end with
    autoplay on, plays the next episode in the same player (the proposal's own
    `automaticAcceptanceInterval` is 0: AVKit counts it from the item's end, which is what the
    model already handles); the finished episode is marked watched when ≥ 92 % was seen. Cancel
    lets the episode end and the player close.
  - **Errors**: a full-screen error with Try Again (from the last position) and Close. `429` shows
    the server's message (fallback: "This profile is already watching on another device…").
    A player item failure or a keepalive `404` restarts the session at the current position once;
    a second failure within 30 s is shown as an error.
- **Continue Watching** cards on Home now play directly (`.ask` → resume prompt); long press offers
  Details and Play from Beginning. `TabNavigation` owns a `NavigationPath` and exposes
  `\.openRoute` for such context-menu actions.
- `TrackLabels` (shared by the player and the About panel) names tracks: "English Stereo",
  "Russian · AC3 · 5.1", "English (Forced)".
- **Tests**: kit 51 tests (new: growing-playlist start, full-timeline source, `UpNext` order and
  timing; integration test `testHLSResumeKeepsFullTimeline` against the real server, passed
  locally). Mock server: `/api/play` (direct), `/api/stream` with Range from
  `scripts/fixtures/sample.mp4` (60 s generated clip with a running timecode, 280 KB),
  `/api/subs` VTT. UI tests `test04Player` / `test05UpNext` capture the resume prompt, playback
  with subtitles, the transport bar, the menu and Up Next.

### Decisions
- Request `startSec` 0 and seek locally instead of resuming server-side: one extra ffmpeg start at
  0 is cheap, and in exchange the whole timeline is seekable natively.
- Up Next uses the native `AVContentProposal` machinery rather than a SwiftUI overlay, so focus and
  the Menu button behave like the system player.
- Selecting a Continue Watching card plays (like the TV app's Up Next row); detail pages keep their
  explicit Resume / Restart buttons and do not ask again.

### Known gaps
- HLS paths are verified by kit integration tests against the real server; the UI tests run with
  the mock server's direct-play clip, so remux/transcode playback in AVPlayer was not seen on a
  simulator.
- No skip-intro/credits markers (the API has none); Up Next timing is a fixed 25 s lead.
- Subtitle styling is fixed (no size/colour settings); ASS styling is flattened to text by the
  server's VTT conversion.
- OpenSubtitles search/download is not in the player (the server returns 503 when unconfigured).
- Multiple versions of a movie (several files) always play the first file.

## Milestone 5 — Music, audiobooks, comics

### What exists
- **Kit**: `PlayQueue` (queue with shuffle that keeps the current item, repeat off/all/one,
  play next / add to queue / remove), `ScrobbleTracker` (one `POST /api/music/plays` per song after
  min(30 s, half the song) of actually played time; seeks do not count), `AudiobookTimeline` (whole-book ms ↔ part + offset, chapter
  lookup, next/previous chapter, chapter end for the sleep timer), comic spread layout and
  `ComicProgress` locators. Unit tests in `AudioLogicTests`; integration tests `testMusic` and
  `testBooksAndComics` stream a track, an audiobook part and a comic page from the real server
  (61 kit tests, all passing locally with `ANTRESOL_TEST_SERVER=1`).
- **Music tab** (`Views/Music`): title + section pill — Listen Now (server shelves, Shuffle All),
  Albums (sort pill), Artists, Songs, Genres, Playlists; paged grids. Album page (cover header,
  Play, Shuffle, Favorite, Go to Artist, track list grouped by disc), artist page (top songs,
  albums, appears on), playlist and genre pages. Track rows: select plays from that row, long press
  offers Play Next, Add to Queue, favourite, album and artist.
- **Audio player** (`Audio/AudioPlayer`): one app-wide `AVQueuePlayer` with the next item queued
  (gapless). Stream URLs carry the media key and `accept=` the formats AVPlayer decodes
  (aac, mp3, alac, flac); if a FLAC item fails it is retried transcoded. Transcoded streams seek
  by reloading with `t=`. Shuffle, repeat, star/unstar (optimistic, reverted on failure),
  scrobbling, interruption handling, `AVAudioSession` `.playback` (background audio mode is in
  Info.plist). Video playback pauses the audio player.
- **System integration** (`NowPlayingCenter`): `MPNowPlayingInfoCenter` (title, artist, album,
  artwork loaded with the Bearer header, elapsed/duration/rate, chapter for audiobooks) and
  `MPRemoteCommandCenter` (play/pause/toggle, next/previous or 15/30 s skips and chapter jumps,
  scrubbing).
- **Now Playing** (`NowPlayingView`): large artwork over a blurred, artwork-tinted backdrop,
  title/context, focusable scrubber (left/right seek), transport circle buttons, and a right
  panel with Up Next / Lyrics (synced lines follow playback; plain lyrics scroll) or Chapters for
  audiobooks. Shown full screen when playback starts; while something is loaded the shell has an
  icon-only Now Playing tab (waveform / pause icon) as the mini "now playing" entry.
- **Books tab** (`Views/Books`): Reading Now (server shelves), Audiobooks, Manga & Comics, Books,
  with sort pills. Audiobook page: chapters, Play/Resume from the whole-book position, Want to Read.
  Audiobook playback plays all parts as one book, speed 0.75–3×, sleep timer (5–60 min or end of
  chapter), progress `PUT /api/progress` with `positionMs`/`durationMs` every 10 s, on pause and in
  the background. Comic series page (volumes, Continue Reading) and volume page; the comic reader
  shows single pages or spreads (play/pause toggles), honours `rtl`, loads pages with the auth
  header and prefetches one spread back and two ahead, saves the page as progress and shows an
  "End of Volume" card after the last page. E-books show their page with "Reading books isn’t available on Apple TV".
- **UI tests** `test06Music` / `test07Books` capture Listen Now, album, Now Playing with lyrics,
  albums grid, Books home, comic volume and reader, audiobook page and Now Playing. The mock server
  serves generated `track.m4a` / `audiobook.m4a` fixtures.

### Decisions
- Detail pages built on `DetailScroll` + `CollectionHeader` give the header actions the initial
  focus (`primaryDetailAction()` + `defaultFocus` in `DetailScroll`), and their primary buttons stay enabled while the
  page loads (they do nothing until the data is there), so focus lands on them before the list
  appears. Now Playing starts on Play/Pause. The screenshots showed the first list row and the
  scrubber taking focus otherwise.
- The Now Playing tab is icon-only: with a text label the eighth tab pushed the profile tab out of
  the tvOS tab bar.
- Lossless FLAC is requested directly (AVPlayer plays it on tvOS 17); a failure falls back to the
  server's AAC transcode instead of surfacing an error.

### Known gaps
- No playlist editing (create/rename/reorder) on TV; the kit supports it, the UI only plays
  playlists.
- Audio was checked on the simulator with the mock server's AAC fixtures; FLAC/transcoded music and
  multi-part MP3 audiobooks from the real server were verified only by the kit integration tests.
- E-book reading is intentionally not available on TV.

## Milestone 6 — Settings, Top Shelf, polish, docs

### What exists
- **Settings** (`Views/Settings`, the profile tab; replaces `AccountView`):
  - The left column has the avatar, name and role (Administrator, or "Kid profile · up to PG"),
    plus Switch Profile and Sign Out. Sign Out asks for confirmation and revokes the device token
    with `POST /api/logout`.
  - The right column is a scrolling list of glass rows (`SettingsRowButtonStyle`,
    `SettingsRowLabel`, `SettingsInfoRow`) in four sections:
    - Playback: Video Quality, Audio Language, Subtitles and Autoplay Next Episode. These are the
      same `UserDefaults` keys the player uses (`PlayerPreferences.Key`, bound with `@AppStorage`),
      so choices made in the player's menus show here and the other way round.
    - Language: App Language (System / English / Русский).
    - Server: address and version, plus Change Server, which kid profiles do not get.
    - About: version (build) and Acknowledgements.
  - Each choice opens `SettingsChoiceView`, a pushed page with a check mark on the current value,
    which starts focused. Picking an option saves it and goes back.
- **Language override** (`Services/AppLanguage`):
  - The choice is stored in `app.language` and written to the app's `AppleLanguages`, which the
    system applies to everything from the next launch.
  - Right away, SwiftUI text follows `.environment(\.locale)` and the server gets the new
    `Accept-Language`. Home re-fetches when it reappears.
  - A footnote says that some text changes after a relaunch: strings built with
    `String(localized:)` and the system UI.
  - "System" uses the device language, which is captured at launch so it is right even while
    an override is active.
- **Top Shelf extension** (`TopShelf/`, target `TopShelf`, bundle id `app.antresol.tv.topshelf`,
  embedded in the app):
  - `ContentProvider` is a `TVTopShelfContentProvider` with sectioned content: Continue Watching
    (16:9, backdrop first, with a progress bar) and Recently Added (posters; movies and shows
    interleaved).
  - The plan comes from `/api/home` through the kit's `TopShelfPlan`, which is unit-tested and
    checked against the live server.
  - Tiles carry `displayAction` set to `antresol://item/{id}` and `playAction` set to
    `antresol://play/{id}`.
  - `TopShelfArtwork` downloads artwork with the Bearer header into the App Group container
    (fresh for 1 day, removed after 7, a stale copy is used offline) and passes file URLs to
    the system.
  - Without a shared session (signed out) it returns nil, so the static brand Top Shelf image
    shows.
- **Shared session** (`Shared/`, compiled into both targets):
  - `SharedSessionStore` keeps the server URL, profile and language in the App Group defaults
    (`group.app.antresol.tv`), and the token in the shared Keychain group
    `<team prefix>app.antresol.shared`. The group name comes from the `AntresolKeychainGroup`
    Info.plist key, so the build fills in the team prefix.
  - `AppState` publishes the session whenever `phase` or `language` changes, clears it when
    leaving the signed-in state, and calls `TVTopShelfContentProvider.topShelfContentDidChange()`
    when something changed. The shell also calls it after each video session.
  - Both entitlements files list the app's own Keychain group first, so the app's existing
    Keychain items stay where they were.
- **Deep links**:
  - The app registers the `antresol` URL scheme.
  - `.onOpenURL` passes the URL to `AppState.open`, which stores a `pendingDeepLink` until a
    profile is signed in.
  - The shell resolves the item with `/api/items/{id}`. `item` opens its page on the Home tab
    (the Home stack's path is owned by the shell). `play` plays videos with resume.
  - Unknown or forbidden ids are ignored, and a 401 goes back to the profile picker as usual.
  - Parsing lives in the kit's `DeepLink`, which has tests.
- **Polish**:
  - New accessibility labels: the Now Playing waveform on track rows, and the sleep timer button.
  - Every UI string is in both en and ru. A key-coverage script found no missing or unused keys,
    and the Russian screenshots were checked.
  - The mock server now treats profile 2 as a kid (`isKid`, `maxRating` PG), as the sample
    server does. It also logs User-Agents, so CI can show the Top Shelf extension's requests.
- **Docs**: README rewritten (features, requirements, build/run/test, architecture, CI).
- **CI**:
  - The tvOS build job now builds into `build/`, checks that `TopShelf.appex` is embedded with
    its extension point, and greps warnings from `TopShelf/` and `Shared/` too.
  - New UI tests: `test08Settings` (settings, language page, server/about, acknowledgements; kid
    has no Change Server) and `test09DeepLinkAndRussian` (Russian UI, the
    `-AntresolOpenURL antresol://item/19` launch hook, and the Home-screen Top Shelf).
- **Kit**: 66 tests (new: `DeepLinkTests`, `TopShelfPlanTests`, the live
  `TopShelfIntegrationTests`). All pass locally with `ANTRESOL_TEST_SERVER=1`.

### Decisions
- Settings is the profile tab rather than an extra tab. The tab bar is already full: an eighth
  labelled tab pushes the profile tab out of the bar (see milestone 5).
- Kid profiles keep playback and language settings but cannot change the server. Both profile
  kinds can sign out or switch profile, because the picker still protects password profiles.
- The audio and subtitle language lists are fixed (12 common languages, names localised by the
  current locale). The player menus can still store any language a file has.
- The Top Shelf shows video only: Continue Watching is limited to video kinds, and Recently
  Added draws on the movie and show shelves. Books and music have their own surfaces.
- Artwork is stored as local files because the system fetches Top Shelf image URLs without our
  Bearer header, and the server does not accept the media key on images.

### Known gaps
- The Top Shelf and the shared Keychain and App Group need a signed build with a team that has
  `group.app.antresol.tv` and the Keychain group registered. CI builds unsigned, so a real
  device Top Shelf was not seen. The UI test captures the simulator's Home screen
  (`45-top-shelf`).
- The language override changes `String(localized:)` text (some labels and menus) and the
  system UI (keyboard, player chrome) only after a relaunch. tvOS has no API to restart an app.
- No device management screen: the server's `/api/me/devices` list and revoke are not in the UI.
  Sign Out revokes this device.
- No playlist editing on TV (see milestone 5).
- The UI screenshot job is still `continue-on-error` and uses mock data.

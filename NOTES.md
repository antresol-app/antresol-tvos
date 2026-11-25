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
  - `TokenStore` protocol keyed by `CredentialKey(serverId, userId)`; `InMemoryTokenStore` for tests *(removed 2026-11-24, nothing used it)*.
  - Playback: `MediaKeyStore` (actor, caches mk, refreshes with < 1 h left), `VideoPlaybackSession`
    (actor: `/api/play` with Apple TV caps, mk-signed URL, 20 s keepalive, `replaceSession` on re-start,
    expiry callback on keepalive 404, DELETE on stop), `PlaybackSource` (player <-> file time mapping,
    `canSeekInPlayer`), `PlaybackProgressReporter` (actor: 10 s periodic PUT when moved >= 0.5 s, `flush()` for
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
  tests skip) and `app-tvos` (the xcode-27 runner, Xcode 27.2, xcodegen, xcodebuild for the tvOS Simulator).

### Decisions
- Swift 5 language mode in both package (tools 5.10) and app; models and actors are still `Sendable`.
- `URLSessionTransport` wraps `dataTask` in a continuation (works the same on Linux corelibs and Apple).
- Query strings are encoded strictly (only unreserved characters literal) so "R&B" / "+" survive Go's decoder.
- Playback always signs player URLs with the media key (complete VOD playlists for HLS, no headers needed).
- Lyrics `404 No lyrics` is returned as `nil`, not an error.

### Known gaps (for later milestones)
- The app UI is only the splash/status screen. *(Done in milestone 2 and later: onboarding,
  shell and every content screen.)*
- SSE (`/api/events`) is not wrapped (spec says it is an optional refresh hint and emits nothing on 0.3.0);
  `ServerURLs.events` exists if needed. *(Still open.)*
- No image loader yet. *(Done in milestone 2: `ImagePipeline`.)*

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
  artwork). *(Since the release task: screenshots are published to the `screenshots` branch and
  the job is no longer `continue-on-error`; the base64 `SHOT` log lines are gone.)*
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
- Search, Movies, TV Shows, Music and Books tabs show a "coming soon" placeholder. *(Done in
  milestones 3 and 5; `SectionPlaceholderView` is gone.)*
- `ItemDetailView` is a stub. *(Done in milestones 3 and 4: seasons/episodes, cast, versions,
  watchlist and play actions.)*
- Hero is a single item, not a carousel. *(Done in the review fixes: carousel.)*

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
  progress every 10 s via `PlaybackProgressReporter`, flushes and deletes the HLS session on close, and
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
- Player is the basic one. *(Done in milestone 4: audio/subtitle/quality menus, side-loaded VTT,
  Up Next and `replaceSession` seeking; skip-intro stays open, the API has no markers.)*
- Music and Books tabs show the placeholder. *(Done in milestone 5: album, artist, book and comic
  pages; `ItemSummaryView` is only the fallback for kinds without a page.)*
- No "see all" pages for Home shelves *(done in the review fixes: `Route.shelf`)*; no filter by
  genre in the grids (the API has none).

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
  - **Progress**: `PlaybackProgressReporter` every 10 s, plus a flush on pause, when the app leaves the
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
- Multiple versions of a movie (several files) always play the first file. *(Done in the review
  fixes: Versions pill.)*

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
  playlists. *(Done: see "TV gaps closed".)*
- Audio was checked on the simulator with the mock server's AAC fixtures; FLAC/transcoded music and
  multi-part MP3 audiobooks from the real server were verified only by the kit integration tests.
- E-book reading is intentionally not available on TV.
- *(Release 1.1: the music and audiobook screens were seen again on the tvOS 27.2 simulator by
  `test06Music` / `test07Books`; real-server formats are still kit-tested only.)*

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
    (`group.<bundle id>`, `AntresolAppGroup` Info.plist key), and the token in the shared Keychain
    group `<team prefix><bundle id>.shared` (`AntresolKeychainGroup`). Both keys are expanded from
    the `ANTRESOL_APP_GROUP` / `ANTRESOL_KEYCHAIN_GROUP` build settings (release 1.1; before it the
    names were hard-coded to `group.app.antresol.tv` and `app.antresol.shared`).
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
- The dynamic Top Shelf has not been seen working. *(Still open.)*
  - It needs a signed build with a team that has the App Group (`group.<bundle id>`) and the
    Keychain group registered. CI builds unsigned.
  - On the CI simulator, `45-top-shelf` shows the static brand image, and the mock server got no
    request from the extension. Either the extension is not run for UI-test installs, or the
    shared Keychain item cannot be read without a team prefix.
  - The kit's `TopShelfPlan` and the deep-link handling are tested. The first thing to check on
    a device is that `SharedSessionStore.load()` returns the session in the extension.
- The language override changes `String(localized:)` text (some labels and menus) and the
  system UI (keyboard, player chrome) only after a relaunch. tvOS has no API to restart an app.
- No device management screen: the server's `/api/me/devices` list and revoke are not in the UI.
  Sign Out revokes this device. *(Done: Settings > Devices.)*
- No playlist editing on TV (see milestone 5). *(Done.)*
- The UI screenshot job is still `continue-on-error` and uses mock data. *(No longer
  `continue-on-error`, see the release task.)*

## Review fixes (after milestone 6)

Reviewer findings were checked against the code. The real ones are fixed; the rejected ones
are listed below.

### Playback and sessions
- **Kit `VideoPlaybackSession`**:
  - `start` runs one call at a time.
  - `stop()` always wins: it bumps an epoch, and a start still in flight deletes the session
    it created and throws `CancellationError`.
  - A failed start deletes any session it created. If the old session was not replaced, its
    keepalive restarts.
  - The media key is fetched before `/api/play`.
  - The stale-`replaceSession` 404 fallback is gone. The live server ignores an unknown
    `replaceSession`.
  - The keepalive holds the actor weakly and ends with it (plus `deinit`). A `401` ends it
    too, and is reported through `onEnded(.unauthorized)` (it was `onExpired`).
  - New tests: stopping during a start, and a 401 keepalive.
- **`PlaybackProgressReporter`**: its loop ends with its owner, and it has a `deinit`.
- **`URLSessionTransport`**: a cancellation that arrives before the data task exists still
  cancels the task.
- **`HLSSessionID.parse`**: cannot trap on a leading `hls`.
- **`AudioCodec.apple`**: now includes WAV and AIFF.
- **`VideoPlayerModel`**:
  - The resume seek waits for `readyToPlay`, and playing waits for the seek to land.
    Meanwhile `currentFilePosition` reports `source.startPosition`, so no progress write
    can carry 0.
  - `requestedPosition` keeps the resume point. Try Again resumes there after a failed
    first start, a failed Up Next, or a failed episode switch.
  - Track and quality changes queue in `pendingOptions` and run one at a time, so a quick
    audio pick then quality pick keeps both.
  - Duplicate failure signals (item status and failed-to-end) only start one recovery.
    Stale items are ignored.
  - Restarts keep the paused state.
  - `fail()` saves the position, then releases the HLS session, the progress timer and the
    item.
  - In the background the HLS session is released (§5.6). It is restarted, paused, on return.
  - Transport-bar seeks outside a growing (EVENT) playlist ask `/api/play` for a new
    session at the target
    (`AVPlayerViewControllerDelegate.timeToSeekAfterUserNavigatedFrom`).
  - EVENT playlists send the Bearer header on the asset (`AVURLAssetHTTPHeaderFieldsKey`),
    because their segments carry no `mk`. Every sample playlist is complete (VOD), so this
    path is untested against the server.
- **Version picker**: movies with several files show a Versions pill on the detail page.
  `PlaybackCoordinator.Request.fileId` carries the chosen file.
- **`AudioPlayer`**:
  - Every item learns whether its stream is transcoded before any seek. Audiobook parts use
    `BookFile.format`. Songs are probed once per stream, including preloaded ones. As a
    safety net, an item with no seekable range is treated as transcoded.
  - After 3 failures in a row (or the queue length, if smaller), playback stops with a
    notice instead of cycling the queue.
  - Nothing is loaded without a media key.
  - Starts are serialised by a generation counter.
  - `shutdown()` removes the observers and the remote-command handlers. The shell calls it
    when it goes away.
  - `stopAndFlush()` awaits the final audiobook write.

### Session and app state
- **Per-profile clients**:
  - Each signed-in profile gets its own `APIClient` with a fixed token
    (`ServerConnection.profileClient`). The server's client never carries a token.
  - Final writes that are still in flight when the profile changes finish with their own
    token.
  - `signOut` awaits `prepareToLeaveProfile` (set by the shell: `audio.stopAndFlush()`)
    before it revokes the token.
- **Change Server from Settings** is a full-screen cover. The shell, its tab stacks and the
  music are untouched unless another server actually connects.
- **Error messages**: `AppState.userMessage(for:)` gives localized, plain text. It uses the
  server's message when there is one, otherwise a transport, decoding, 404 or 5xx
  explanation. The profile picker, password and server screens use it too.
- **Language override**:
  - Every `String(localized:)` passes `bundle: .localized`, the chosen language's `.lproj`.
    Text built after a change follows it at once.
  - Views that are already on screen and have no other reason to redraw keep their text
    until they redraw.
  - The Top Shelf extension keeps the system bundle.
- **Top Shelf entitlements**: the extension now has only the shared Keychain group. The
  app's own group, which holds every profile's token, is no longer listed.

### UI
- **Paged grids** (`PagedList`, `LibraryModel`):
  - Only a new sort or filter resets the grid.
  - A plain reappear (Back, tab switch, finished video) merges the fresh first page into
    the loaded items (`PageMerge`), so focus, scroll position and later pages stay.
- **Focus**: the Movies, TV Shows, Albums and book-list sort rows are focus sections, so Up
  from any column reaches the pill.
- **Home**:
  - The hero is a carousel:
    - it auto-advances every 8 s while its buttons are not focused;
    - Left on Play and Right on Details page through it;
    - it shows dots and cross-fades the backgrounds.
  - A series hero names its episode ("Play S1, E1"), as the detail page does.
  - Shelf titles carry a chevron and open `Route.shelf` (`ShelfGridView`):
    - Recently Added Movies, New Episodes and Recently Played page through the full lists;
    - Currently Reading and Want to Watch show the cards from `/api/home`, because the API
      has no separate list for them.
- **Play/Pause** on a focused movie, show or episode card starts it (Home, Movies and TV
  Shows, the season row).
- **Detail pages**:
  - Video detail offers Try Again when it fails to load.
  - E-books show the error state.
  - Season pills scroll when they do not fit.
- **Music**:
  - Songs > Shuffle uses the server's whole-library shuffle (All Songs), or pages through
    every favorite (Favorites).
  - Album pages no longer offer Go to Album.
- **Comics**:
  - The reader saves on disappear and when the app leaves the foreground.
  - Its end card offers the next volume: Select reads it in place.
- **Profile picker** is one horizontally scrolling row.
- **Profile tab** shows the avatar, rendered with `ImageRenderer` in original rendering mode.

### Rejected findings
- None were rejected outright.
- One part was not done as suggested: the next-volume action on the comic end card is "press
  Select" rather than a separately focusable pill. The reader is one focus target that
  takes left/right presses, and a second focusable would steal those presses.

### Known gaps
- Selecting a song in Songs queues only the songs loaded so far (shuffle covers the whole
  library). *(Done: the rest is queued in the background.)*
- The profile tab avatar has not been checked on a device. If tvOS template-renders tab
  images, it shows as a white disc, and the Settings page still shows the coloured avatar.
  *(The CI simulator screenshots show the coloured avatar; see "TV gaps closed".)*
- The EVENT-playlist paths (seek outside the window, Bearer on the asset) have not been
  exercised: the sample server always returns complete playlists.
- Strings already on screen keep the old language until their view redraws.

## TV gaps closed (playlists, devices, Songs queue, avatar)

### What exists
- **Kit** (`Sources/AntresolKit/Music/`):
  - `PlaylistEditing`: trimmed names (`normalizedName`), the `order` permutation for moving one
    entry (`moveOrder`, matching the server: `order[i]` is the old position placed at `i`), and
    local `apply(order:)` / `removing(positions:)` so pages show an edit before the server
    answers. `PlaylistUpdate.rename/append/remove/move` build the PATCH bodies.
  - `RemainingPages<Element>`: walks the pages after the ones already loaded, one at a time.
    Transport errors, `429` (honouring `Retry-After`) and `5xx` are retried after 1, 3 and 9 s;
    a `401`, other `4xx` or the last failure ends the walk with that error. Items already
    loaded or delivered are skipped (pages shift when the library changes while paging), and
    the walk follows the server's latest `total`.
  - `PlayQueue.extend(with:)`: adds more of the source list. Not shuffled, it appends; shuffled,
    the new entries are mixed into the upcoming part (the original order still gets them at the
    end, so turning shuffle off restores list order).
  - `DeviceSession.displayOrder` (current device first, then by `lastSeen`) and `lastSeenDate`.
  - Tests: `PlaylistAndPagingTests` (edit bodies and previews, paging with retries, give-up,
    401, duplicate skipping, stop), new `PlayQueueTests` cases, `DeviceListTests`; the live
    `testMusic` now moves and removes entries in its temporary playlist and checks that the
    local preview matches the server. 79 kit tests, all passing locally with
    `ANTRESOL_TEST_SERVER=1`.
- **Playlists on TV** (`Views/Music/PlaylistEditing.swift`, `MusicView`, `MusicDetailViews`,
  `TrackRow`):
  - `PlaylistActions` (shell-owned, in the environment): the Add to Playlist request, a
    `revision` bumped by every playlist change (the Playlists grid reloads on it) and a
    confirmation message.
  - Music > Playlists has a **New Playlist** pill; grid cards have a long-press menu with
    **Rename** and **Delete Playlist** (confirmation dialog).
  - `PlaylistNameView` is the name page (text field, Create/Save, Cancel; Menu cancels; the
    keyboard's Done submits; server errors such as "Enter a playlist name" show in red).
  - Playlist page: Play, Shuffle, **Rename**, **Delete** (pops the page after deleting). Song
    long-press adds **Move Up**, **Move Down** and **Remove from Playlist**. Edits show at once
    and are sent one after another (each waits for the previous); a failed edit shows the error
    and reloads the playlist as saved. Rows are keyed by a per-entry id so focus follows a
    moved song.
  - **Add to Playlist…** is in every song row's long-press menu (album, artist, playlist,
    Songs), and album pages have an icon-only Add to Playlist pill (the favourite pill there is
    icon-only too, so the row still fits beside the cover). The picker (a sheet) lists
    New Playlist… and the profile's playlists; choosing one appends and closes it, New
    Playlist… creates the playlist with the songs.
  - The shell shows a bottom `NoticeBanner` for playlist confirmations ("Added to “Road
    Trip”", "Deleted …") and for the music player's own notices ("Playing next", "Added to
    queue", playback problems), which before were only visible inside Now Playing. The Now
    Playing tab keeps its own banner. `NoticeBanner` moved to `Design/Components` and is shared
    with the video player and Now Playing.
- **Devices** (`Views/Settings/DevicesView.swift`, Settings > Server > Devices): every native
  session of the profile with a model symbol, name, "model · version · Last seen 5 minutes ago"
  (relative, in the app language), "This Apple TV" on the current one. Selecting another
  device asks ("Sign out “Kitchen iPad”?") and revokes it with `DELETE /api/me/devices/{id}`.
  The current device is signed out with Sign Out on the Settings page instead.
- **Songs**: selecting a song plays the loaded songs from there at once and queues the rest of
  the library (or of the favorites) in the background through `RemainingPages` (500 per
  page) and `AudioPlayer.play(tracks:startAt:continuing:)`. The fill task is cancelled by any
  new playback, an audiobook, stop or sign-out; if a page keeps failing, the queue ends there
  and a notice says some songs could not be added.
- **Profile tab avatar**: the CI screenshots (`04-home-hero`, `37-settings`) show the coloured
  gradient avatar in the tab bar. The image is now also marked `.renderingMode(.original)`, and
  the tab has the accessibility label "<name>, Profile and Settings".
- **Mock server**: playlists and device sessions are kept in memory, so create, rename, append,
  reorder, remove, delete and device revoke behave like the server (`PATCH` support added).
- **UI tests**: `test10Playlists` (create with the keyboard, playlist page, song menu, move
  down, add to the new playlist, delete from the grid) and `test11Devices` (devices list,
  sign out the iPad). Screenshots `46`–`58`.

### Decisions
- Reordering on TV is Move Up / Move Down in the song's long-press menu rather than a drag
  mode: it works with the Siri Remote's select-and-hold and keeps focus on the song.
- Adding a song that is already in a playlist adds it again, like the server and web app
  (playlists may hold duplicates; positions, not ids, identify entries).
- Kid profiles can manage their own playlists and devices: both are per profile on the server.
- The background Songs fill queues in list order even when shuffle is turned on later; new
  entries are then mixed into the upcoming part.

### Known gaps
- Playlist and device UI was exercised against the mock server on the simulator; the kit's
  playlist calls and edit semantics were checked against the real 0.3.0 server.
- Albums and artists have no long-press "Add to Playlist" on their grid cards (album pages
  and song rows have it).
- Unchanged from before: dynamic Top Shelf unverified without a signed build; EVENT-playlist
  paths unexercised; text already on screen keeps the old language until it redraws.
  *(All three still open at release 1.1.)*

## Release engineering and screenshot gallery

### What exists
- **Screenshot gallery**: the `ui-screenshots` job boots the simulator explicitly (`simctl
  bootstatus` with a 7-minute alarm; on failure it erases the simulator and boots once more), runs
  the UI tests, exports the attachments, and on pushes to main runs `scripts/build-gallery.py`
  (each attachment saved as `<name>.png`, scaled to 1920 pt wide with `sips`, plus a README per
  test that names the commit and the UI test outcome) and force-pushes it as the single commit of
  the orphan branch `screenshots` with the job's `GITHUB_TOKEN` (`contents: write`). It runs even
  when a UI test failed, so the gallery shows where it went wrong. To look at it:
  `git fetch origin screenshots && git show origin/screenshots:04-home-hero.png > /tmp/x.png`.
  The 58 screenshots cover onboarding, profiles, Home, Movies, TV Shows, details, player, Up Next,
  Music, Now Playing, Books, comics, audiobooks, Search, Settings, Russian, Top Shelf, playlists
  and devices. The job is no longer `continue-on-error`.
- **Release archive job** (`archive-tvos`): `scripts/check-metadata.py`, then `xcodebuild archive`
  for `generic/platform=tvOS` (Release, `CODE_SIGNING_ALLOWED=NO`,
  `CURRENT_PROJECT_VERSION=${{ github.run_number }}`), then checks that the app and the embedded
  `TopShelf.appex` have a valid `PrivacyInfo.xcprivacy`, version 1.0.0, the run number as build
  number and arm64 binaries, and that `ITSAppUsesNonExemptEncryption` is false.
- `project.yml`: `MARKETING_VERSION` 1.0.0; `CURRENT_PROJECT_VERSION` stays 1 for local builds and
  is overridden on the command line for uploads.
- **Privacy manifests**: `AntresolTV/Resources/PrivacyInfo.xcprivacy` (no tracking, no collected
  data; UserDefaults `CA92.1` for the app's settings and `1C8F.1` for the App Group defaults written
  by `SharedSession`; file timestamps `C617.1` for the artwork cache expiry in `ImagePipeline`) and
  `TopShelf/PrivacyInfo.xcprivacy` (UserDefaults `1C8F.1`, file timestamps `C617.1` for
  `TopShelfArtwork` in the group container). No other required-reason API (disk space, boot time,
  active keyboards) is used by the app, the extension or AntresolKit.
- `Info.plist`: `ITSAppUsesNonExemptEncryption = false` (only system HTTPS).
- **App Store metadata** in `fastlane/metadata/{en-US,ru}` (name, subtitle, description, keywords,
  promotional text, release notes, privacy/support/marketing URLs) plus categories
  (Entertainment, Music); `fastlane/Deliverfile` (appletvos, text only). Wording follows the
  website (`sidun-av.github.io/antresol`) but lists only what the TV app does.
- `scripts/ExportOptions-AppStore.plist` (app-store-connect, upload, automatic signing).
- README: "Run on an Apple TV" (App Group and App IDs registration, why the Keychain group needs
  none, pairing, team) and "Ship to TestFlight and the App Store" (version/build, archive and
  export commands, export compliance, TestFlight groups, metadata, privacy label, screenshots).

### Decisions
- The `screenshots` branch is force-pushed as one commit each time instead of growing a history of
  ~60 PNGs per push; the commit sha in its README ties it to main.
- Russian keywords are kept within 100 bytes (App Store Connect counts bytes, so Cyrillic halves
  the room); the check script enforces bytes for keywords and characters elsewhere.
- The description does not claim offline downloads, the e-book reader, Picture in Picture or
  adaptive quality: the TV app has none of those (the website copy describes the iOS app).
- Copyright is set in App Store Connect only; `fastlane deliver` leaves it alone, as there is
  no `copyright.txt`.
- No signing secrets in CI: the archive proves the Release build only; uploads are manual.

### Known gaps
- Never signed or uploaded: App IDs, App Group, App Store Connect record, TestFlight and App
  Privacy answers are the owner's steps (README). *(Release 1.1: see below for what is now set
  up and what still blocks the first upload.)*
- The website's privacy policy and support page describe the iPhone/iPad/Mac app; they should
  mention Apple TV (Top Shelf artwork cached in the App Group container) before submission.
- App Review needs a reachable demo server and profile credentials.
- Store screenshots must be picked by hand from the `screenshots` branch (mock data).

## Design fidelity pass (screenshot review)

Every screenshot on the `screenshots` branch was compared with `docs/design-ref` (tv_*.png,
DESIGN.md) and tvOS conventions. Fixed:

- **Truncated actions**: the detail header capped its whole column at 1400 pt, so in Russian
  "Отметить просмотренным" was cut ("Отметить просмот…"). Only the title keeps the cap now, and
  the pill rows of every detail header (video, album, artist, playlist, books, comics) are an
  `ActionRow`: a horizontal scroll view that slides as focus moves when the pills need more
  than the width, instead of truncating labels.
- **Mixed card shapes in one row**: Currently Reading (Home and Books) mixes 2:3 comic posters
  and square audiobook covers, which left the captions at different heights. Rows whose cards
  have different proportions now share one artwork height (360 pt, the poster height:
  `Collection<Card>.mixedShapeArtworkHeight`, `PosterCard(card:artworkHeight:)`).
- **Placeholder title over the progress bar**: posters without artwork that have progress now
  put the title at the top, as wide cards already did.
- **List alignment**: track, playlist, Songs, chapter, queue and chapter-panel rows started 28 pt
  (cover rows) or ~65 pt (numbered rows) right of the section headings. Row stacks are now
  outdented by the row padding (`listRowOutdent()`, `Theme.Layout.listRowInset`) and numbers are
  leading-aligned, so text lines up with the headings and only the focus plate reaches beyond.
- **Now Playing**: the artwork was centred in the 680 pt column while the title, scrubber and
  controls were leading-aligned; it is leading-aligned now.
- **Settings**: read-only rows (Address, Version, app version) had a dimmed title and a bright
  value, the reverse of the button rows; the title is primary and the value secondary now. The
  settings list no longer scrolls under the tab bar (its scroll view clips).
- **Comic volume page**: the eyebrow repeated the title (the server titles volumes after their
  series); it shows the series only when it differs, else "Manga & Comics".
- **Page headers**: the "2 movies" count is baseline-aligned with the page title (Movies and TV
  Shows now use the shared `PageHeader`).
- **Search browse tiles**: symbol top left in a fixed box and title pinned bottom left, so the
  titles of all six tiles sit on one line (before, they shifted with the symbol height).
- **Empty shelf row on Home**: a shelf reached by scrolling (Recently Played in `06-home-shelves`)
  showed its title but no cards: the lazy outer stack laid its row out at zero height. Home,
  Books > Reading Now and the search results use a plain `VStack` of shelves now (a handful of
  rows each; the rows themselves stay lazy).
- **Settings scrolled under the tab bar**: removing `scrollClipDisabled()` was not enough, since a
  scroll view draws into the safe area the tab bar occupies; the list is masked to its frame with
  a 64 pt fade at the top, so rows scrolled up fade out below the tab bar.
- Track and chapter numbers sit in a 40 pt column (was 52) so titles follow them more closely.

Not changed (checked and kept): the full-screen resume prompt, Up Next and Now Playing use the
80 pt margin inside the safe area (160 pt from the screen edge) like the system player overlays;
shelf titles and badges such as "Audio EN RU" come localized from the server (the mock serves
English); the logo stays the glass mark from `logo-mark.svg`.

## Token scoping for media loads

`APIClient.authorizationHeaders(for:)` sends the Bearer token only to URLs with the server's own
scheme, host and port; any other URL (for example external artwork) gets `Accept-Language` only.
Every image, comic page, Now Playing artwork, Top Shelf artwork and header-authenticated HLS
load uses it. The plain `authorizationHeaders` property is for requests the kit builds itself.

## Release 1.1 (Xcode 27, universal purchase)

### What changed
- **Xcode 27 build**: Foundation in the tvOS 27 SDK has its own `ProgressReporter`, so the kit's
  actor of that name became ambiguous in `AudioPlayer` and `VideoPlayerModel`. It is now
  `PlaybackProgressReporter` everywhere (file, test, docs).
- **Home focus on tvOS 27**: Down from the Home tab skipped the hero's pills (they sit left of
  most tabs) and went to the second Continue Watching card, so `test04Player` / `test05UpNext`
  reached the music shelf and played a song. CI (Xcode 16.4, tvOS 18) still took the old path.
  The pills' focus section now spans the text column; Down from Home lands on Details, the next
  Down on the first Continue Watching card. The tests were right and are unchanged.
- **Identity from build settings**: `project.yml` stays neutral (`app.antresol.tv`, no team).
  `ANTRESOL_BUNDLE_ID` drives the extension (`.topshelf`), UI tests (`.uitests`), App Group
  (`ANTRESOL_APP_GROUP`, `group.<id>`) and Keychain group (`ANTRESOL_KEYCHAIN_GROUP`, `<id>.shared`);
  the entitlements, `CFBundleURLName` and the `AntresolAppGroup` / `AntresolKeychainGroup`
  Info.plist keys expand them. Every target's `Antresol.xcconfig` does `#include? "Local.xcconfig"`
  (git-ignored; `Local.xcconfig.example` is committed), the same pattern as the iOS app.
  `fastlane/Deliverfile` reads `ANTRESOL_BUNDLE_ID` from the environment.
- `MARKETING_VERSION` is 1.1.0.

### Decisions
- Rename the kit type rather than qualify each use (`AntresolKit.ProgressReporter`): the name
  would keep colliding wherever both modules are imported.
- The default Keychain group moved from `app.antresol.shared` to `app.antresol.tv.shared` so it
  follows the bundle id. A signed install from before 1.1 rewrites the shared session on its next
  launch; the old item is left behind in the old group.
- Simulator UI tests need signing (`CODE_SIGN_IDENTITY=-` or a team) because of the
  `keychain-access-groups` entitlement; with `CODE_SIGNING_ALLOWED=NO` the Keychain write fails
  and the tests stop at "Who's watching?". CI's UI test job signs to run locally, so it is fine.

### Known gaps
- CI still selects Xcode 16.4; the tvOS 27 focus behaviour and the Foundation name clash only
  show with Xcode 27.
- A tvOS App Store archive with automatic signing needs a tvOS development profile first, and
  Apple makes one only when the team has an Apple TV registered. The owner's team has none yet.
- Still open from earlier milestones: dynamic Top Shelf never seen on a device, SSE not wrapped,
  EVENT-playlist paths unexercised, no skip-intro markers, no long-press "Add to Playlist" on
  album/artist grid cards, text already on screen keeps the old language until it redraws.
- Privacy policy, App Review demo server and store screenshots: see "Release engineering".

## Liquid Glass, sidebar and the TV-app look (release 1.1)

### What exists
- **Glass** (`Design/Glass.swift`): `glassSurface(in:highlighted:prominent:)` draws Liquid Glass
  on tvOS 26 (`glassEffect`, interactive; white-tinted when focused, a light tint for the primary
  Play pill at rest) and the old flat fills before it. `PillButtonStyle`, `CircleButtonStyle`,
  the segmented pill, settings rows, list-row focus plates, shelf-title focus, the notice banner
  and the comic reader panel use it, so every control the app draws (detail actions, hero
  buttons, Now Playing and audiobook transport, the resume prompt and Up Next over the video)
  is glass with a lift and shadow when focused. Banners and the comic panel use
  non-interactive glass; settings rows are clear at rest with glass on the focus plate; the
  segmented pill is one glass capsule with plain white plates inside. `GlassGroup` wraps rows in a
  `GlassEffectContainer` (merge distance 0, so a lifting pill does not grow a bridge to its
  neighbour). AVKit's transport bar stays native.
- **Sidebar** (`MainShellView`): on tvOS 18+ a `Tab`-based `TabView` with `.sidebarAdaptable`:
  Search (search role), Home, Movies, TV Shows, Music, Books, Now Playing while audio is loaded,
  and the profile last. tvOS 27 adds `tabViewSidebarHeader` with avatar, name and time. The
  collapsed sidebar is the system chip naming the section. tvOS 17 keeps the top tab bar.
- **Home hero**: full-screen (1080 pt) with title, kind · genres + outlined age-rating badge, one
  line of description (from `GET /api/items/{id}`, loaded per featured item), the light Play pill
  and round glass buttons for watchlist (toggles via the API), details and the next item, page
  dots; Continue Watching rises 260 pt into it (`Theme.Layout.heroOverlap`). Item pages are
  cached per featured item and reloaded (old one kept on screen) after `AppState.libraryRevision`
  changes.
- **Lyrics page**: choosing Lyrics in Now Playing switches the layout: artwork colour fills the
  screen (blurred artwork at full opacity), artwork with title and artist centred under it and
  previous/play/next on the left, 64 pt synced lines on the right (current white, others 38 %).
- The mock server adds genres, ratings and descriptions to the featured items and puts three
  items in the hero (`HERO_EXTRAS`); the recorded samples have none of these.

### Decisions
- The deployment target stays tvOS 17: glass is behind `#available(tvOS 26)`, the sidebar
  behind `#available(tvOS 18)` and its header behind tvOS 27, each with the previous look as the
  fallback. The fallbacks are the existing code, so they cost little, and raising the target
  would drop nothing the App Store would gain.
- The system sidebar instead of a custom one, as asked.
- Hero buttons are round icon buttons (accessibility labels Watchlist, Details, Next) like the
  TV app's; the detail pages keep labelled pills.

### Known gaps
- At launch the system sidebar is open and holds focus until the system collapses it, about
  8 s on the simulator; focus then lands on the page's default focus (Play on the hero or on
  a Top Shelf-linked page, `defaultFocus(..., priority: .userInitiated)`). Moving focus out
  sooner failed with a delayed `FocusState` assignment and with `focusScope` +
  `prefersDefaultFocus` + `resetFocus`. The timed assignment remains for tvOS 17 only.
- Compared with Apple's references, the mock has no real artwork (gradient placeholders, the
  series has no backdrop), so the hero and lyrics screens look emptier; the lyrics have two lines.
- The lyrics page keeps a small transport row and the Up Next / Lyrics pill visible; the Music
  app hides its controls until the remote is touched.
- Glass was checked on the tvOS 27.2 simulator only, not on a device or on tvOS 26.
- tvOS 17 coverage: the fallbacks (top tab bar, flat fills, the timed deep-link focus) were
  only compiled, never run. Only the tvOS 27.2 simulator runtime is installed here, and the UI
  tests now navigate through the sidebar, so they would not run there unchanged.

## Live channels («ТВ»)

### What exists
- `AntresolKit/Models/Channels.swift`: `Channel`, `ChannelProgram`, `ChannelList`,
  `ChannelGuide` (tolerant decoding, `rules` not decoded) and the pure logic: sections by
  category in the order of their lowest number (`ChannelSection.group`), programme progress,
  what is on at a time (`Channel.program(at:)` moves on to `next`, `ChannelGuide.onAir(at:)`),
  channel up / down by number with wrap-around (`Channel.neighbour`) and the logo gradient.
- `APIClient+Channels.swift`: `channels()`, `channelGuide(id:hours:)` and
  `startLiveChannel(id:mediaKey:)`, which fetches the live playlist first and retries the
  server's `503` "starting" answers (short `Retry-After`) before handing the URL to AVPlayer;
  other errors (busy, screen time, gone) are thrown with the server's message.
  `ServerURLs.liveChannel(id:mediaKey:)`. Unit tests in `ChannelTests` and the two samples.
- The TV tab (`Views/TV`), between TV Shows and Music: the page title and a section pill (All,
  then the sections; it moves under the title when it does not fit), All as a row of channel
  cards per section, one section as a three-column grid. `ChannelCard` is a 16:9 lockup: the
  programme's backdrop (else the logo tile) with the logo in the corner and a live progress
  bar, then "10 · Name" and the programme. The list is fetched every 30 s while the tab shows.
- The live player (`LivePlayerView` / `LivePlayerModel`), presented by the shell like the video
  player (`PlaybackCoordinator.watch`): an `AVPlayerLayer` with no transport bar, so nothing can
  be scrubbed. A UIKit controller takes the remote: Up / Down (click or swipe) and channel
  buttons (`pageUp` / `pageDown`) zap by number with wrap-around, Select toggles the panel,
  Play/Pause pauses and rejoins at the live edge, Menu leaves. The bottom panel (logo,
  "10 · Name", Live, title, episode line, time range with progress, "At 23:30 — next") shows
  on every change and hides after 6 s. While the stream starts: the programme's backdrop and a
  spinner ("Starting the channel…" after a `503`). Errors: "The channel can't be shown" with
  the server's message, Try Again and Close; Up / Down still zap from there. The guide and
  the channel list are refreshed every 30 s.
- `ChannelScreenshotTests` drives the tab and the player against a real server with channels;
  it is skipped unless `CHANNELS_SERVER`, `CHANNELS_PROFILE` (and `CHANNELS_PASSWORD`) are set
  (`TEST_RUNNER_…`). The mock server serves the channel samples with their times moved to now,
  but has no live stream.

### Decisions
- The player is not `AVPlayerViewController`: its transport bar offers scrubbing in the live
  window and takes Up / Down for its own panels, and zapping needs both.
- Section and channel order come from the kit (as the web's `byCategory`), so Android and
  tvOS agree.
- A `503` with a long `Retry-After` (too many channels on) is shown, not retried.

### Known gaps
- Swipes and the channel buttons were not exercised: the simulator's UI tests send clicks
  (`upArrow` / `downArrow`) only.
- The "starting" state with its text was not captured (the test server mostly holds the first
  request until the stream is ready instead of answering `503`).

## Live channels, second round (Continue, zap without black, mini-guide, Top Shelf)

### What exists
- **Kit**: `Channel.upNext(at:)` (what follows the programme on air, nil once `next` is on
  air itself), `ChannelStrip` (the mini-guide: the current channel's section in the TV tab's
  order, starting at the current channel; a channel missing from the list gets a strip of its
  own), `LastChannelStore` (the last channel id per server and profile in `UserDefaults`,
  resolved against the current list so a channel the profile no longer sees is dropped),
  `TopShelfChannels` (up to 10 channels with a programme on air, in the TV tab's order:
  "10 · Name — Title", backdrop, else poster, else `/api/channels/{id}/logo.png`, progress,
  `antresol://channel/{id}`) and `DeepLink.channel(id:)` (`itemId` is now optional). Tests in
  `LiveTVTests`.
- **TV tab**: a "Continue" row first (`ContinueChannelCard`): the page-wide card of the last
  channel with the programme's backdrop (else the logo gradient), a left-to-right scrim, the
  logo, "10 · Name" and Live, the title, the episode line, progress with the time range and
  "Next at 23:30 — …". It shows once a channel has played on this device and reloads when the
  player closes. Channel cards got a third line, "Next at HH:MM — title" (always laid out so a
  row's captions line up).
- **Player**: two `AVPlayer`s with their own `AVPlayerLayer`s in one view. A zap pauses the
  picture on screen (its last frame stays, dimmed, with a small glass spinner) and loads the
  new channel into the player underneath; they swap when the new item is ready and its layer
  `isReadyForDisplay` (or 1.5 s after ready, if the layer never says so). The banner is a glass
  panel at the bottom (logo, "10 · Name", Live, title, progress and times, next, and hints for
  Up and Down) over a soft scrim; it slides in on every change and on Select and fades after
  5 s. Down (click or swipe) opens the mini-guide: a row of the section's channel cards over
  a scrim, focus on the current one (marked with a play glyph); Select switches, Up or Menu
  closes it, the next Menu leaves. While it is open the picture view is not focusable and
  passes the presses on. Now Playing: title, "10 · Name", the backdrop, live (no scrubber);
  whatever was there before (paused music) is put back on close. A channel that plays is
  remembered as the profile's last channel.
- **Remote**: Up and the channel buttons zap (Up / Page Up next, Page Down previous), Down
  opens the mini-guide, Left / Right show the banner, Select toggles it, Play/Pause pauses.
- **Top Shelf**: an "On Air Now" («Сейчас в эфире») section between Continue Watching and
  Recently Added; `/api/channels` is fetched alongside `/api/home`, and a failed or missing
  list just leaves the section out. Tiles carry the programme's progress; Select and Play
  both open `antresol://channel/{id}`.
- **Deep link** `antresol://channel/{id}`: the shell loads the channel list, selects the TV
  tab and opens the live player (ignored for a channel the profile does not see, or while a
  video plays).
- `ChannelScreenshotTests.testContinueZapAndMiniGuide` captures every new state,
  `testChannelLink` opens `antresol://channel/{id}` through the system (which asks "Open in
  …?" first; Select confirms) and `testTopShelf` the Home screen.

### Decisions
- Down opens the mini-guide instead of switching to the previous channel (the design doc's
  "swipe / click down opens the mini-guide"). The previous channel is Page Down, or one card
  to the left in the mini-guide.
- The held frame is the old player paused, not a snapshot image: nothing to render, and it
  costs nothing when the new channel is quick.
- The mini-guide's channel order is fixed when it opens, so a list refresh does not move the
  row under the focus; the cards' programmes still update.

### Known gaps
- The dynamic Top Shelf is still unseen: on the tvOS 27.2 simulator the extension process
  exits with `exit(3)` a few milliseconds after exec, before any of its code runs (HeadBoard
  logs "connection to service … interrupted"), for both ad-hoc and team signing settings. The
  section is covered by the kit's tests only.
- Swipes and the channel buttons are still not exercised by the UI tests (clicks only).
- The Top Shelf's "On Air Now" goes stale between the system's refreshes of the extension.
- Up from the Continue card lands on the section pill's option nearest it, not on the
  selected one (the pill has no default focus; giving it one made it take the page's first
  focus in every tab, so it was left as it is).
- Right after a programme boundary the cards and the Continue card can miss their "Next"
  line until the next list refresh (the list's `next` is then on air).

## Live channels, third round (one list, the guide, audio and subtitles, TV is TV)

### What exists
- **Kit**: `Channel.favorite` (no logo: a channel is its number and name), programmes with
  `id`, `kind`, `rating`, `genres`, `external` and the `audio` / `subtitles` renditions
  they have (`LiveTrack`), `ChannelList.lastChannel`, `ChannelFilter` (All, Favourites,
  themes; `zapList`), `ChannelEPGWindow` / `ChannelGuideGrid` (`GET /api/channels/epg`
  windows merged per channel), `GuideScale`, `PlaybackPrefs`, `LiveTrackSelection` and
  `ChannelService`, the only way the app talks to the server about channels.
  `ChannelGuideTests.testChannelsLeaveNoHistory` runs a whole session through it and fails
  on any write but the favourite and the last channel.
- **TV tab** (`Views/TV`): `TVView` (header: title, the last-channel pill, Channels | Guide,
  filters), the numbered list (`ChannelRow`), `GuideView`, `ProgramDetailView`, `TVModel`.
  `tv.mode` and `tv.filter` are remembered in `UserDefaults` (and can be set with launch
  arguments, which the UI tests use).
- **Guide focus**: every block is a SwiftUI button; each row is a `focusSection()` with
  `defaultFocus(…, priority: .userInitiated)` on the programme at the time anchor, and
  `focusMoved` puts a vertical move right if the engine picked another block. The anchor
  follows horizontal moves (the block's start, never before the view's start).
- **Live player**: the options row (Select) with Audio, Subtitles, the star and the channel
  row; `TrackMenu` lists the programme's entries and selects the HLS rendition by `NAME`
  (else by language); subtitles come from `AVPlayerItemLegibleOutput` and are drawn by the
  view, above the banner when it is up. Down (click) is channel down now; the mini-guide
  opens with a swipe down or from the options row.
- **Film player**: voice-over files beside the video and cleaned voice-overs (the kit sends
  `X-Vault-Caps: external-audio`; `audioSrc` with an external track; menu order and labels
  as on the web).
- `ChannelScreenshotTests`: `testList`, `testFavourites`, `testGuide`, `testLivePlayer`,
  `testFilmVoiceOver`, `testTopShelf`, `testChannelLink`; `CHANNELS_LANGUAGE=en` runs them in
  English.

### Decisions
- The guide does not take the remote itself: a UIKit focus view inside SwiftUI is wrapped
  by SwiftUI's own focus item, so its `shouldUpdateFocus` is never asked when focus leaves
  and the focus engine moved focus out of the grid on Left. Real SwiftUI buttons with
  per-row default focus keep the engine and the grid in agreement.
- The guide zooms to the schedule (`GuideScale`): a typical programme gets ~360 pt, never
  less than the usual half hour = 320 pt. The test library's seven-minute films would
  otherwise be slivers.
- The options row instead of `AVPlayerViewController`'s transport bar: the live player has
  no transport bar (nothing to scrub, and Up / Down zap).
- No favourite-studio ordering of the Audio menu beyond the server's own order: the web
  player shows the server's order (cleaned tracks under their source) and the studios list
  is a household setting only administrators can read.

### Known gaps
- The Top Shelf extension still exits on the tvOS 27.2 simulator before running, so the
  On Air Now tiles (and the placeholder picture) were not seen.
- Swipes on a real Siri Remote were not exercised (the UI tests send clicks).

## Owner list, 2026-11-15 (trailers, watched marks, stills, cast, settings, tab reset)

### What exists
- **Kit**: `Card.watched` and `Card.thumb` (episode still; `wideArtwork` = thumb, backdrop,
  poster), `CastMember.photo`, `Trailer` / `TrailerList` and `APIClient.trailers(itemId:)`
  (`GET /api/items/{id}/trailers`; entries without a key or not on YouTube are dropped).
- **Watched**: `WatchedMark` + `watchedDimming(_:isFocused:)` on `PosterCard`, `WideCard` and
  `EpisodeCardView` (replaces the old checkmark); focus lifts most of the dimming. Marking
  watched on a page bumps `libraryRevision`, so grids and Home redraw their marks.
- **Stills**: episode tiles, Continue Watching and the Up Next offer use `wideArtwork`;
  `RemoteImage` takes fallbacks, so a 404 frame gives way to the series' backdrop.
- **Cast**: portraits over the initials (the initials stay as the placeholder and fallback).
- **Trailers**: `TrailerButton` on movie and series pages (fetched once per page, beside the
  detail load). `youtube://watch/<key>` when `canOpenURL` says the YouTube app is there
  (`LSApplicationQueriesSchemes`: youtube); else a sheet with the https URL as a QR code.
- **Settings**: the Server section (address, version, Devices, Change Server) is gone, with
  `DevicesView`, `ServerEntryView`'s `close` and their strings. The kit keeps its device API.
- **Tab reset** (`TabResetCoordinator`): the shell owns every tab's path; leaving a tab that
  has a page pushed or was scrolled (`reportsTabScroll`, tvOS 18+) starts a 5 s timer, after
  which its path is emptied and its root rebuilt (`.id`). Settings always resets (cheap).
  `-AntresolTabResetSeconds` stretches the delay for UI tests.
- **Movies / TV Shows**: column spacing fills the content width (was 46 pt, leaving the right
  margin 42 pt wider); the header no longer scrolls, the grid scrolls below it with a fade.
- **Mock server**: watched marks, thumbs, cast portraits, trailers for items 19 and 2, and 22
  generated movies so the grid scrolls.

### Known gaps
- The YouTube app path is unverified: the simulator has no YouTube app, so only the QR sheet
  was seen. Top Shelf still uses the backdrop for episode tiles (one image, no fallback).
- The TV tab is reset only after a pushed page, not after scrolling the channel list (its
  first state is the last channel, which a scroll check cannot tell apart).

## App review round, 2026-11-16 (Menu, resume point, players, speed)

### What changed
- **Menu**: the QR sign-in screen is the root of the sign-in flow and has no exit command, so
  Menu there leaves the app. The server screen is opened with Change Server only, and its
  Menu still comes back.
- **Resume point**: a failed `GET /api/progress` is no longer "no progress". The player
  shows the error (Try Again) instead of starting at 0 and writing over the saved position;
  the detail page keeps the position it had. Progress and the media key are asked for
  beside the item.
- **Players**: `playerDidClose(_:)` and `liveChannelDidClose(_:)` take their request and
  clear only it (a late close no longer dismisses the next player).
  `PlaybackCoordinator.isPresenting` pauses the hero carousel and the TV tab's refresh
  under a full-screen player.
- **Subtitles** (`CaptionStyle`): both self-drawn renderers take the text size, text colour
  and plate from Settings > Accessibility > Subtitles and Captioning. The app's own look
  stands for the system default (a value equal to the default domain's is not applied), so
  nothing changes for a viewer who set nothing. Font and text edge are not applied.
- **TV tab**: `TVModel` stores `filters`, `activeFilter`, `channels`, `guideRows` and
  `guideScale`, derived when the list, the guide or the filter changes.
- **Artwork** (`ImagePipeline`): one download per URL whatever the sizes, one decode per
  size, the download cancelled with its last waiter. `RemoteImage.maxPixelSize` is in pixels
  of a 2x screen and is scaled by the display scale.
- **Smaller**: `LibraryModel` is gone (Movies and TV Shows use `PagedList`), `TimedNotice`
  replaces three copies of the four-second message, Now Playing's scrub bar is its own view.

### Known gaps
- Nothing of this round was run on an Apple TV or in the simulator; the kit tests and the
  simulator build are the only checks. The Menu change, the caption style and the artwork
  cancellation need a look on a device.
- Left as they were: the delayed focus assignments (live controls, track menu, TV tab, the
  two detail pages), the Home refetch behind a shelf's See All, and the song stream probe
  before the first play.

## App review round, second pass, 2026-11-17 (first run in the simulator)

### What changed
- **Artwork**: at most four decodes at once (`ConcurrencyLimiter`, kit), one thread of the
  shared pool left free.
- **Music**: a song not played before starts without waiting for the stream probe; whether
  the server transcodes it is learned beside the playback (as for the queued next song).
- **Reduce Motion**: the hero does not advance by itself, the live player's banner, channel
  row and track menu fade instead of sliding, Now Playing's artwork resizes unanimated.
- **Top Shelf**: section titles in the session's language (they were in the system's);
  the artwork sweep runs once per load.
- **Files**: `LiveNowPlaying` and `StreamOption` / `LiveLegibleReceiver` left
  `LivePlayerModel.swift`; one `ImagePipeline.nowPlayingArtwork` for music and live TV.
- **UI tests**: `test01ServerEntry` (stale since 4481d42) and `test12EpisodeGuide` (red
  since b83eb9f added it) repaired; README says how a run reaches the mock server.

### Seen in the simulator (tvOS 27.2, Apple TV 4K 3rd generation, the mock server)
- All 16 `ScreenshotTests` pass, in three runs of a few tests each.
- Menu on the QR sign-in screen leaves the app; from the server screen (Change Server) and
  from the profile picker it comes back to the QR screen. (A mock with the pairing
  endpoints: `scripts/mock-server.py` has none, so the committed tests never see it.)
- Subtitles with the system's default caption style look as on main's screenshots.
- Artwork made of line gratings is drawn at the screen's resolution at 2x and at 1x.
- The TV tab opens on the last channel; the guide moves and opens a programme.

### Known gaps
- Not run: the live player (the mock has no streams), so its delayed focus assignments
  stay as they were, as do the detail pages' (tvOS 17 only; no linked album in the mock)
  and the TV tab's (it lands on the last channel as it is).
- Not seen running: the dynamic Top Shelf (the simulator shows the static image), Reduce
  Motion on, a transcoded song, a caption style other than the default.
- Left on purpose: the Home refetch behind See All (it is also the grid's refresh), the
  resting card shadow (a visual change), the repeated track discovery on a live tune-in,
  `@State` engines built in `MainShellView.init`, Top Shelf artwork downscaling.
  *(Since 2026-11-24: Top Shelf artwork is asked for at the tile's width and the card's shadow
  no longer animates its blur radius, the faint resting shadow stays; see "Quality wave".)*
- Kit API nothing in the app calls (tests only), kept: `Models/Books.swift` beyond
  `isBook` / `withoutBooks`, `devices()`, `revokeDevice(id:)`, `searchSubtitles`,
  `downloadSubtitle`, `libraryStatus()`, `ServerURLs.download`, `ServerURLs.events`.
  *(Since 2026-11-24 `Models/Books.swift`, `revokeDevice`, `searchSubtitles`, `downloadSubtitle`
  and `libraryStatus` are gone: see "Quality wave".)*

## App review round, third pass, 2026-11-17 (the live player and sign-in in the simulator)

### What changed
- **Mock server**: every channel plays one short live stream (the first 12 s of the video
  fixture, looped, three audio renditions named as the sample programme's voices). The
  port after the main one is the same server with QR sign-in and one transcoded song;
  the main port is as it was, so the screenshot tests see what they saw. The log line has
  the User-Agent again (Python 3.15 rebuilt the line without it).
- **`RuntimeTests`** (UI, the mock): Menu on the sign-in screens, the live player, the
  hero's auto-advance (it expects the hero to stay when Reduce Motion is on), a
  transcoded song.
- **Focus**: the live options row, the audio / subtitle list and the TV tab assign focus
  at once (they waited 80 and 150 ms).
- **Live tune-in**: an item that is shown in the turn it becomes ready chooses its
  tracks once. `live tracks:` log lines per first tune-in / zap / pick: 2 / 3 / 1 before,
  1 / 2 / 1 after.
- **Guide pages** (`ChannelGuideGrid.merge`): the server names a programme of several
  files after its first file inside the queried window and leaves out the files outside
  it, so a programme cut by a page's edge comes twice, under two ids and two starts. The
  merge kept the fresh copy only (the programme lost its head, or its tail scrolling
  back, and changed its key under the focus; tvOS never drew the two over each other).
  The halves are joined now: the whole span under the key the guide already had.
- **Kit tests**: the Top Shelf's strings files have the three section titles for `en`
  and `ru`, the two values a session's language takes.

### Seen in the simulator (tvOS 27.2, Apple TV 4K 3rd generation, the mock server)
- `RuntimeTests` pass three times in a row; the 16 `ScreenshotTests` pass (run before the
  guide-page change, which they do not reach).
- Menu on the QR screen leaves the app; from the server screen it comes back.
- The live player plays, switches channels, opens the options row on Audio and the
  list on the playing voice; Menu returns to the row the player was opened from.
- Reduce Motion on (`defaults write com.apple.Accessibility ReduceMotionEnabled -bool
  true` in the simulator): the hero stays on its first page for 12 s (it moves on
  without the setting); the live test passes with the fades.
- The transcoded song: the player's request is answered 4 s before the app's own one,
  the clock runs meanwhile, and a seek asks for the stream again with `t=`.

### Known gaps
- **The audio list opened again within about a second of a pick does not take focus**
  (it stays on Audio; Up reaches the list). So it was with the 80 ms wait too. The test
  waits for the list to close before opening it again.
- A tune-in asks for the master playlist twice (the app's request that starts the
  channel and reads the renditions, then the player's) and, when the voice chosen is not
  the stream's default, loads the default rendition's first segments before the chosen
  one's. Both left: the first is how a channel is started, the second needs the choice
  to be made before the item loads.
- The focus changes were checked in the simulator only; a slow Apple TV may differ.
- The dynamic Top Shelf is still not seen running (the simulator shows the static
  image and the extension makes no request).
- In the guide the now line is drawn over a programme's first letters during its first
  minute. The iOS guide draws the line over the blocks too; left for a decision.
- A programme whose file boundary falls exactly on a page's edge still comes as two
  blocks side by side (it cannot be told from the same film shown twice in a row). The
  mock's guide ignores `from`, so the joined programme was checked by the kit test only.
- The detail pages' delayed focus (tvOS 17, a linked album) is as it was.

## App review round, fourth pass, 2026-11-17 (the independent review's findings)

### What changed
- **Resume point** (RV-1): Try Again after a failed progress request asks for the saved
  position again. `open()` set the item before the position had arrived, so the retry
  took the item as resolved and began at 0 (after Up Next: at the previous episode's
  offset). The choice is `PlaybackRetry.plan` (kit): a start counts as known only once a
  session was begun for the item.
- **Guide pages** (RV-5, RV-6, and the Android twin's review): the newer page wins over
  what was known for its span. The server gives a programme's id to another programme
  when a schedule is rebuilt, so the merge trusts nothing known: same key or same start
  → the page's copy; a known programme that starts inside the page's span or overlaps
  one of the page's is dropped; a join is void when its key or span would clash with
  another of the page's programmes; keys are unique in a row. Only library programmes
  are joined (external entries all have item 0), and under one id only when both copies
  agree on the edge that is not cut (a moved programme is not stretched).
- **Focus** (RV-2, RV-10): the TV tab keeps the row it wants focused (`focusRequest`):
  the list scrolls there, the row takes focus as it appears, the delayed assignment is
  a fallback of three tries. The audio / subtitle list takes focus on every opening
  (`menuOpenings`), not on `onAppear`: opened again inside its 0.26 s leaving
  transition it is the same view brought back, and `onAppear` does not run (seen in the
  log: no `onAppear` between the two openings).
- **Artwork** (RV-3, RV-9, RV-11): `ArtworkPixels.longestSide` (kit) is the size rule;
  full-screen backdrops pass a floor of 1920, so a 1080p screen gets its every pixel
  again and 4K still decodes 1920. A file whose decode fails leaves the disk cache. A
  late waiter removes only its own decode entry.
- **Music** (RV-7, RV-8): the stream probe's answer is applied only to the item of the
  queue entry it was asked for; a seek held before an unknown song's item is ready is
  decided again then (`SongSeek.plan`, kit) and reloads the stream when it has no ranges.
- **Tests** (RV-4): the mock's second port keeps what it was asked (`/mock/events`,
  `/mock/reset`), can fail one progress request (`/mock/fail-progress/<id>`), lists 24
  channels with the 18th as the last one watched, and answers the app's own question
  about the transcoded song after 6 s. `testTranscodedSong` checks the order of requests
  and the clock after the seek; `testTryAgainResumesAtTheSavedPosition` and
  `testTVTabOpensOnAFarLastChannel` are new; `testLivePlayer` opens the audio list again
  at once. CI runs `testHeroAutoAdvance` a second time with Reduce Motion on. The video
  player's file position is an accessibility value in debug builds (`player.position`).

### Known gaps
- No unit test for RV-7, RV-9 and RV-11: the code is in the app target, which has no
  unit-test bundle; they were built and exercised by the UI runs only as far as those go
  (no damaged image, no probe race in the mock).
- A programme a rebuilt schedule moved AND renumbered between two page loads cannot be
  told from one cut by the page's edge (same item, overlapping, across the edge): it is
  still joined. A stable programme id from the server would end the guessing.
- Decodes are still not cancellable and wait in arrival order (RV-11's first point).
- The held-seek reload (RV-8) and the 1080p decode size were not seen on an Apple TV.
- Still open from the third pass: the mock's guide ignores `from` (the joined programme
  is checked by kit tests only), and a tune-in with a voice other than the stream's
  default loads the default rendition's first segments (needs the choice before the
  item loads: a restructuring).

## App review round, fifth pass, 2026-11-17 (the delta review's findings)

### What changed
- **Guide focus** (D-1): a block's focus identity is its row and its programme
  (`GuideView.focusKey`). Two external channels of one guide source have the same
  programme ids (`x<guide>-<start ms>`), so Down between two such blocks did not change
  the focused value: the grid did not scroll with it and both rows were marked.
- **Guide pages** (D-3, D-4, D-5), the merge rule now:
  - the page's programmes come in; same key or same start: the page's copy;
  - a known programme that starts inside the page's span is dropped;
  - one that starts outside it and lies over one of the page's is dropped when it is a
    library programme or reaches into the span; an external entry wholly outside the
    span stays (XMLTV guides overlap: O 10:00–11:59 and A 11:30–12:10);
  - a programme cut by the edge is joined; under another id the known part may also end
    where the fresh one does (the film's tail seen first keeps its key scrolling back);
  - an external row that is empty in a page whose external rows are all empty is no
    word (the server asks the guide store once for all of them and answers 200 with
    empty rows when that fails); a library row's emptiness is the truth (an error there
    is a 500).
- **Guide requests**: none outlives `reloadGuide` (`RequestGate`, kit). A page on its
  way when the guide was started over (the TV tab coming back from a programme's page
  does that) was merged into the empty grid and kept the first window from being asked
  for: the guide stayed on its spinner.
- **Artwork** (D-6): a cached file is removed only when it does not decode at 16 px
  either (`ArtworkDecoding`, kit: the ImageIO part of the pipeline, with tests).
- **Music** (D-7): a held seek that finds no ranges at ready no longer marks the song as
  transcoded for the session (`HeldSongSeek`, kit): the reload asks the server first;
  the server's "original" means the ranges are late (the player seeks); only a second
  time without ranges and without an answer is remembered.
- **TV tab focus** (D-8): the repeated focus request is made only while focus is where
  it was when the row was asked for (`FocusPlace`: the focused item's frame;
  `FocusFallback`, kit), and the request ends when the page goes away.
- **Player** (D-9): Try Again opens the card the way it was last opened (`lastStart`): a
  series card opened with "ask" asks again. `retry()` runs only from the error screen
  (a second press while the first is under way did open the item twice).
- **CI** (D-2, D-10): Reduce Motion is put back in an `always()` step and after the
  boot; the main run fails if it is on (`…EXPECT_REDUCE_MOTION=0`); the Reduce Motion
  run has a result bundle (exported, in the gallery) and fails unless exactly one test
  ran.
- **Mock, second port only**: a guide of twelve rows and three external channels (two
  with the same programme ids), a series card at the end of Continue Watching.
  `RuntimeTests`: `testGuideMovesBetweenRowsWithTheSameProgrammeIds`,
  `testTryAgainAsksAgainForASeriesCard`.

### Known gaps
- No unit test for RV-7 (one comparison of queue entry ids) and RV-11 (the late waiter:
  needs a hook between a decode's end and its waiter). RV-9 has one now
  (`ArtworkDecodingTests`).
- `FocusPlace` and the fallback it guards are not seen at work: the first assignment has
  always landed in the simulator. If an item's frame changed without focus moving, the
  fallback would not be made (focus would stay where it was).
- D-6 and D-7 are rules with unit tests; no memory pressure and no late ranges were
  produced in the simulator.
- The server joins "last file + first file of the repeat" when a window starts inside
  the last file of a film that is shown again right after (`programs()` compares the
  next file with the first one listed, not with the film's first file): the client then
  joins that with the known first showing. A server fix (not made here).
- `testTVTabOpensOnAFarLastChannel` does not fail on the code before bf34ad6 (the TV tab
  of bf34ad6^ in a scratch copy): it passed six times, also with the last channel at the
  90th row of 100. The focus assigned after a pause lands in the simulator; the case
  bf34ad6 fixed was not reproduced there, and the test guards the result, not the fix.
- An external row kept as "no word" (a failed external guide query) keeps only what was
  known: the window counts as loaded, and its span is not asked for again until the
  guide is reloaded.
- The CI workflow was not run; its commands were run by hand on the Mac.


## Addon ways (the neutral `x/app` protocol)

The server's addons offer the apps ways to watch a title or keep a copy of it. The app knows no
addon's id or wording: labels, step titles and rows come from the server in the profile's language;
the app's own strings are only «Watch», «Cancel» and «Nothing Found». The protocol is in
`docs/API.md` §14.

### What exists

- `AntresolKit`: `AddonWays.swift` and `WaySteps.swift` (models), `APIClient+Ways.swift` and
  `APIClient+InputPlay.swift` (calls), `AddonCatalog` (discovery, cached per sign-in).
  `VideoPlaybackSession` can take a requester instead of a library file, and
  `PlaybackProgressReporter` another sender, so an addon's stream reuses the keepalive, the
  seek-by-session and the periodic progress of the library player.
- Pages: `WayButtons.swift` (the ways that watch, the round keep buttons with the state ring, an
  episode's menu entries), `WaySheet.swift` (the step-by-step chooser), `TitleDetailView.swift` (a
  title the library lacks: `/api/title`, a show's episodes from the tracking list). Search adds one
  section per addon that searches, after the library's groups.
- `WayPlayerModel` / `WayPlayerView`: the player of what a way started. `input` goes through the core's
  input player (202 polled every 1.5 s up to 90 s, then the `/api/play` answer, progress on the input);
  `play` is the addon's own stream with its session and progress. A stale link (the media answers
  410, or any failure once per 30 s) asks `x/app/run` again with `refresh`.

### Decisions

- A way that watches runs `quick` (the remembered or best choice) on Select and opens the chooser only
  when the addon answers `pick`; «Audio & quality…» in the menu beside it opens the chooser. A way that keeps
  a copy always opens the chooser (the quality and the release are the person's choice).
- Watching ways are one pill and a chevron button (the next section). *(Was: one way as its own button,
  several behind «Watch», each once more as «label…».)*
- `outside` and `inside` are judged per episode in the guide: an episode the library lacks is
  «outside», one it has is «inside». An episode still to air has no ways. Select on a missing episode
  runs the first watching way.
- Discovery is silent: a kid's profile, a server without addons, `403`/`404`, an unreadable answer
  or another protocol version offer nothing. A busy server or a dropped connection is asked again
  after a minute; a definite refusal is kept for the sign-in. The catalog is looked at again when the
  Home tab comes up (tvOS has no pull-to-refresh), at most every 30 s.
- Subtitles of an addon stream are fetched with the Bearer token like every other subtitle (the media
  key is accepted on some of their paths only).
- `session` and `progress` of a `{play}` answer are read from inside `play` first, then beside it
  (the real addons put them inside).
- A run that restarts a stream after a stale link sends the player's position as `startSec`, `0`
  included: left out, the addon would start at its own saved position.
- Trailers: the web lists a title's trailers (the best three) whether or not the server plays them
  (`play`): with `play` in its own sheet, without it in the video site's embedded player. An Apple TV has
  no embedded web player, so the button was already the same: it shows for any trailer, plays in the app's
  own player with `play`, and otherwise in the YouTube app or behind a QR code. The chooser now lists the
  best three too, as the web's menu does.

### Known gaps

- A quick run that is slow (an addon getting a stream ready) shows only the button's spinner; there is no
  way to give it up.
- The way player's menus are the next section's: the stream's subtitles, its qualities and «Audio & source…».
- An episode's page (not the show's) has no ways, and neither has a season's own page.
- The screens were driven only against `scripts/mock-server.py --addons` (`testAddonWays`). The real
  addons' answers (their `x/app` description, a search, steps of both kinds, the state, a title page)
  were decoded with the models by hand, and a watch run's stream was fetched with its media key,
  its progress written and its session closed; none of that is kept as a fixture. A `ref` can be
  2 KB long: it is stored and sent as it came.
- Both addons use the way id `watch`; a way is told apart by its addon too, so two ways with one id
  stay two buttons.
- A run answers `422` with the server's words when a source no longer has the file; it shows as the
  notice of a quick run, or under the chooser's list.

### Play button, busy state, player menu (fix/ways-play)

The owner found three problems on the iPhone; the same fixes are here (the iPhone app got them first).

- **Busy state**: a run was keyed by the way id alone, so starting one episode's way showed the busy state on
  that way on every episode and on the page's main button. `WayRunKey` (way + kind, TMDB id, season, episode;
  the library flag left out) and `WayRunGate` (AntresolKit) keep the one run in flight; only the button of that
  way on that subject spins (`AddonWays.isRunning(_:for:)`). One run at a time stays: a second press anywhere is
  ignored (the buttons are not `.disabled`: that loses the focus). An episode's card, which had no feedback
  at all, shows a spinner over itself while its own run is under way (`wayBusy`).
- **Play and the menu**: the pill is «Play» (play glyph) on a page with no Play of its own; on a page that has one
  it carries the way's own label, as a second, glass pill. It runs `WayMenu.defaultWay`: the way chosen for the
  title (`WayDefaults`, UserDefaults, per profile, per title: an episode uses its show's) while the addons still
  offer it, else the first. The chevron (`Menu`, the pill's second `Segment`) lists the watching ways, each as
  «label — hint», the default ticked (a `Toggle`: a menu draws it as a tick); choosing one remembers it and runs
  it; «Audio & quality…» (after a divider) opens the chooser of the ticked way. An episode's long-press menu is
  «Play», a divider, the same rows, then the keep ways. «Choose Manually» and the old «Watch» dialog are gone.
  A way that keeps a copy stays a round button. An episode card not in the library that a way plays (the card's Select
  runs it) is as bright as a library one; a card nothing plays stays dimmed, one still to air greyed
  (`GuideEpisode.State.opacity(isFocused:playable:)`).
- **Hints** come from the way's glyph, not from an addon or its words (the protocol has no hint): a globe is
  «Starts right away», a play triangle «Plays while downloading», a download or list glyph none (`AddonWay.hint`,
  worded in the app's strings). That is a guess at what the real addons mean by their glyphs; a `hint` field of
  the protocol would replace it.
- **Player**: `WayPlayerModel.current` is what plays (the request the player opened with stays the
  presentation's identity). The bar has Subtitles when the answer lists any, Quality when it has
  `quality: {options, current}` with two or more options and a `ref` to play another with (`WayPlay.qualityChoice`),
  and «Audio & source…» (a way's stream always; a stream that is not ready has no bar). A quality switch is
  `x/app/run` again with `refresh`, the answer's `ref` (it plays the same stream, in the quality it plays in),
  the chosen `quality` and `startSec` at the player's position; an answer without a `ref` runs the call as it was
  and offers no quality. «Audio & source…» pauses the stream and opens the way's chooser in a sheet of the
  player (the shell's cannot show under the full-screen cover); a run chosen there starts at the position the
  stream is at, the old stream's position is saved and its session let go (`switchStream`), and a `done` answer
  is a notice. The stream's own audio and subtitle renditions (`AVMediaSelection`) are the system panel's: it
  lists them by itself, so an answer that lists none still has them.
- Not verified against the real addons: the `quality` and `ref` fields of a play answer and `x/app/run`'s `quality`
  are the iPhone app's protocol additions, which the addon side was getting at the same time; an addon that does
  not send them behaves as before (no Quality menu).

## TV tab: the list on a panel beside the programme's card

The owner chose variant A of the earlier layout study (the Android TV app got the same page).

- Before: three columns (a 400 pt category column, an 860 pt list, a flexible preview), the lower third empty with few
  channels, and the `Channels | Guide` switch pushed to the far right by a spacer.
- Now (`TVView.swift`): the header holds the title, `Channels | Guide`, the category button and the number pad, all on the
  left. Channels: the list is on a panel (46% of the width less a 48 pt gap, the page's full height down to the safe
  area) and the programme's card has the rest: the still across the card, a scrim, the facts, title, episode, time and
  progress, overview, what is next, and «Press · Watch / Hold · Add to Favourites» (two new strings, en and ru). Row
  height = the panel's room / channels between 124 and 208 pt; from 168 pt a row has the programme's still (228×128).
- The category column is gone, on purpose: variant A has no room for a third column, the Guide already filtered by the
  category button and its full-screen list (`CategoriesPanel`: current category focused, Menu closes it as it was, a
  choice hands focus to the channels), and the Android app has always had the button. Both views now have the same
  header and the same way to narrow them. It costs one more press than moving through a column (the column narrowed the
  list as focus moved); the live narrowing is not kept.
- Tests: `RuntimeTests.testChannelListFavouritesFirst` and `testTiviMateRemote` open the category list through the button
  (`focusCategoryButton`); `scripts/mock-server.py --channels N` gives the main port N channels for screenshots of a
  short or a long list (`ChannelScreenshotTests/testList`).
- Not verified on a real Apple TV: the focus engine's choice of the row when Down leaves the header (the simulator
  was driven with the remote's key presses), and the rows' lift at the panel's edge.


## Owner round, 2026-11-23 (what the iPhone review found, checked on the Apple TV)

The owner's list for the iPhone app, taken against this app in the tvOS 27.2 simulator, English and Russian.

- **Badges** (`BadgeRow`): every chip is `BadgeMetrics.height` (30 pt) tall whatever it holds, so one with an icon is no
  larger than one without. An audio or subtitles badge with no languages (`Subtitles`, `Субтитры`) keeps the word beside
  its icon, in the app's language (`BadgeLabel`), instead of showing the icon alone. On a list row lit white (focused) the
  chips turn dark (`badgesOnLightPlate`, set by `ListRowButtonStyle`): light on the white plate had vanished. In the
  chooser's rows the chips keep their width (`fixedSize`), the label and its second line give way: «Subtitles» was cut to
  «Subt…».
- **Chooser** (`WaySheetView`): a step's note is the footer of its list (in the scrolling content, under the rows, as a
  Settings choice has its footnote), or under «Nothing found» for a step without rows. It was between the title and the
  rows.
- **Settings**: nothing to do. The profile page has been one page, Playback, TV, Separate Histories, Language, About This App
  last; there is no «Away address» here.
- **Primary buttons**: nothing to do. A pill is `lineLimit(1)` and the action row scrolls sideways, so «Продолжить» stays on one
  line (`testChooserLayout` checks the pill's height in both languages).
- **Pinned header**: nothing to do. Movies and Shows pin the title and the sort pill above the grid and mask the grid under
  them (rows fade out), so no title is left over scrolled content; `testPosterOpensAndClosesWithFocusBack` attaches the scrolled page.
- **Zoom from the poster**: tried, not shipped. `matchedTransitionSource` on the poster's artwork and
  `navigationTransition(.zoom)` on the pushed page compile for tvOS 18 and ran (logged: the page took the zoom branch, the
  last focused tile was the source), but the tvOS 27.2 simulator shows a plain cross-fade, the page at its final size from the
  first frame. Not verifiable on a device here; the push stays as it was.
- **Round buttons' glyphs**: `RoundGlyph` (a `Label` that moves its symbol) and `GlyphOptics.table` move the few symbols whose
  ink is off-centre in their box, by hundredths of the font size: `chevron.right` left by 0.059 em, the star up, the subtitles
  bubble down, the speaker, shuffle and erase arrows sideways. The numbers come from `scripts/measure-glyph-centres.swift`
  (the symbol drawn as a round button draws it; minus the mean of the middle of its ink's box and its centre of mass).
  Checked on the simulator's screenshots (Home's round buttons, the live player's options row, the number pad): every glyph
  is within 0.5 pt of its circle's middle. The play triangle needs nothing: its box sits right of the middle and its mass
  left of it, evenly.
- **Tests**: `RuntimeTests` gained `testChooserLayout` (mock with `--addons`), `testSettingsOnOnePage`,
  `testPosterOpensAndClosesWithFocusBack` and `testRoundButtonGlyphs`, and runs in Russian with
  `TEST_RUNNER_ANTRESOL_TEST_LANGUAGE=ru` (the app's own strings are read from `ru.lproj` for the labels). The mock's
  chooser has rows with `Audio RU EN`, `Subtitles` and `Субтитры` badges and a note on its second step.
- **A trap**: the UI tests need a signed build. With `CODE_SIGNING_ALLOWED=NO` the app has no Keychain access, cannot keep
  the server address `-AntresolServerURL` gives it, lands on the server screen and lists the servers of the network, and a
  press of Select there connects to a real one. The new tests stop at the first failed step (`continueAfterFailure = false`)
  for that reason.

## Quality wave, 2026-11-24

Branch `fix/q-tvos`, from the review in `_antresol-quality-nov24/tvos.md`.

- **Images**: `ServerURLs.image(_:width:)` asks the server for `?w=<smallest step >= width>` (not for
  video frames, paths with a query, other hosts, or logos: the sized copy is a JPEG). `RemoteImage`, the hero
  tint, Now Playing and the up-next art pass their decode size; Top Shelf asks 1280 (16:9) or 960 (poster) wide,
  four at a time, straight to disk. `ImagePipeline` has its own `URLSession` (4 connections a host, no
  `URLCache`), maps cached files and trims `Caches/Artwork` to 300 MB oldest-first on launch.
- **TV tab**: a refreshed channel list, guide, categories or channel is assigned only when it changed.
- **Keychain**: items are `...AfterFirstUnlockThisDeviceOnly`; an older item is updated in place on its first
  read (never deleted, so nobody is signed out; a failed update is logged by status code and retried on the
  next read). The Top Shelf session is stored only when its token was.
  *Check once on a real Apple TV after the update: still signed in, Top Shelf fills.*
- **Server address**: a host away from the home network typed without a scheme is tried over https first
  (`ServerAddress.candidates(for:)`); plain http to one needs a second press of Connect after a note.
- **Removed (nothing called them)**: `Models/Books.swift`, `searchSubtitles`, `downloadSubtitle`,
  `revokeDevice`, `libraryStatus`, `InMemoryTokenStore`, `Theme.Radius.smallCard`, the book and comic-page
  samples, the library-status sample.
- **Design**: focus scales, press scales, shadows and scrims are tokens (`Theme.Motion.Focus` / `Press`,
  `Theme.Shadow`, `Theme.Colors.scrim`), see `docs/design-ref/DESIGN.md`. Card shadow: the faint resting one
  fades out as the lifted one fades in, neither changes its blur radius; resting and focused look as before.
- Not done: TVQ-12 (font tokens, text under 23 pt), the way player's `TimedNotice` (player-core batch).

## Round 25 November 2026

- **Server address, the transport error**: `ServerAddress.connect(to:allowUnencrypted:attempt:)` (AntresolKit) is the
  candidate loop `AppState.connect` had, with one rule more: a failure that shows the host cannot be reached at all
  (`APIError.isHostUnreachable`: `cannotFindHost`, `dnsLookupFailed`, `notConnectedToInternet`, carried by
  `APIError.transport(_, hostUnreachable:)`) is the answer, at once. The https attempt that failed that way is the
  evidence that plain http fails too, so no plain-http request is sent before the viewer agrees, and the viewer
  is not asked to agree to an unencrypted connection to a host that does not exist: the screen says «Couldn't reach
  the server». A refused connection, a timeout or a failed handshake prove nothing about the host's other port and
  still ask first (https on 443 may be closed while http on 8420 answers). After the viewer agreed, both schemes are
  tried and the last failure is shown, as before. `UnencryptedConnection` moved to AntresolKit with it.
- **UI-test hook**: `-AntresolNoDiscovery YES` (Debug) keeps the Bonjour browser from finding anything, so a server of
  the network cannot take focus from the control a test is about to press Select on
  (`testAnAddressThatDoesNotResolveIsNotOfferedUnencrypted`, which types a `.invalid` name: it never resolves).
- **Search finds what the library lacks (checked end to end)**: it already did: the addons' `x/app` searches (the
  server's one catalogue search: web's `searchBlocks` and the iPhone's addon sections ask the same call; the core's
  kid-only «Найти и попросить» is not in any app) add a shelf per addon after the library's, and a title the library
  lacks opens `TitleDetailView` (`GET /api/title/…`, the ways, a show's seasons), one it has opens the library's page.
  What was missing was a run of it: `testSearchOpensATitleTheLibraryLacks` (mock with `--addons`, adult profile)
  types a query, reaches each shelf with the remote, opens a show and a film the library lacks and one it has, checks
  focus on arrival (the pill), down to the seasons and back, and that Menu returns to the card it came from.
  The pure part of the search, asking every addon at once and showing a section per addon that found titles in the
  order of the addons, moved to AntresolKit (`AddonSearching.sections`, tests with answers arriving in the wrong
  order, failures, nothing found, and a consumer that stops).
- **Trailers on that page**: none, as on the iPhone's. The server lists trailers by a library item
  (`GET /api/items/{id}/trailers`); nothing gives them for a TMDB id the library lacks. A title page with a
  Trailer button would need a server call by `kind` and `tmdbId`.
- **A channel whose audio Apple TV cannot decode plays through the server** (round 25 November, second half): the
  server's channel list says `stream.remuxAudio` (the provider's audio is not AAC or MP3: MP2, AC-3, DTS ...; the
  provider's address plays without a sound) and offers `stream.relay`, a path that converts the audio to AAC.
  `StreamSource.playing` turns such a source into the relay (a server path, so the player opens it with the media key
  like the server's redirect, and sends none of the provider's headers: the relay sends the source's own);
  `ChannelStream.playable(on:)` applies it, so the order of the sources, the fallbacks, the bad-source memory and the
  silence check stay as they were. A server that does not say (older, or no relay) changes nothing: the field is read
  as `false`. A relay on offer without the flag (every external channel has one for the web) is not taken. The banner
  says «Via Antresol» for it. Known gap: the first tune-in of a channel the server has not looked at yet may still be
  silent (the list the app holds says nothing yet); it is flagged from the list's next load.
  The mock's second port got `POST /mock/external-audio` (two external channels, 200 flagged and 201 not; the relay
  asks for the media key and writes it into every link of its playlists, as the server does) and
  `testAChannelWhoseAudioNeedsTheServerPlaysThroughTheRelay` drives both from the remote.
- **Only what Apple TV cannot decode goes through the relay** (round 25 November, third part): the server also says
  `stream.audioCodec`, the first audio codec it converts (ffprobe's name: `mp2`, `ac3`, `eac3`, `dts` ...), with the
  flag. Apple TV decodes AAC, MP3, AC-3 and E-AC-3 itself, so `StreamSource.playing` keeps such a source at the
  provider's address (its own headers, no media key) and the server converts nothing for it; MP2, DTS, anything else
  and a flag with no codec named (an older server) still go through the relay. Android keeps going by the flag alone.
  The mock sends no codec, so its flagged channel is the older-server case and still plays through the relay.

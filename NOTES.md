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
- Search, Movies, TV Shows, Music and Books tabs show a "coming soon" placeholder
  (`SectionPlaceholderView`) — milestones 3 and 5 replace them.
- `ItemDetailView` is a stub: no seasons/episodes, cast, versions, watchlist or play actions (M3/M4).
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
- The dynamic Top Shelf has not been seen working.
  - It needs a signed build with a team that has `group.app.antresol.tv` and the Keychain group
    registered. CI builds unsigned.
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
- **`ProgressReporter`**: its loop ends with its owner, and it has a `deinit`.
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
  promotional text, release notes, privacy/support/marketing URLs) plus copyright and categories
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
- Copyright follows the website footer ("2026 Aleksandr Sidun"). The server repository's LICENSE
  names a different holder; the user should confirm which applies to the App Store listing.
- No signing secrets in CI: the archive proves the Release build only; uploads are manual.

### Known gaps
- Never signed or uploaded: App IDs, App Group, App Store Connect record, TestFlight and App
  Privacy answers are the owner's steps (README).
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

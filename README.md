# Antresol for Apple TV

A native tvOS app for [Antresol](https://github.com/sidun-av/antresol), the self-hosted home
media server: films, TV shows and music on the big screen. It talks to
your own server only. SwiftUI, tvOS 17+, English and Russian.

## Features

- **Look**: Liquid Glass on tvOS 26 and later (the app's own pills, round controls, segmented
  pills and settings rows use the system glass, lit white when focused), and the system
  sidebar on tvOS 18 and later: profile and time at the top, Search, Home, Movies, Shows,
  TV and Music, collapsing to a chip naming the section. Earlier systems keep the top tab
  bar and flat dark-glass fills.
- **Onboarding**: "Set up with your phone" first: a QR code of a small setup endpoint the Apple
  TV opens on its home-network address while the screen is up (`/setup`, one-time key, home
  network clients only). The Antresol app on a signed-in phone sends its server there and
  approves the sign-in at once; a phone camera opens a page to type the server address. The
  remote stays a fallback: servers on the home network found with Bonjour (`_antresol._tcp`,
  server with LAN discovery), or "Enter Address with the Remote": a host, `host:port` or URL
  (port 8420 by default). Then "Sign in with your phone": a QR code and a
  6-character code that a signed-in phone approves (the Antresol app or the server's `/pair`
  page), renewed when it expires; or "Sign In with the Remote": the "Who's watching?" profile picker with avatar gradients, password entry for protected profiles,
  and kid profiles. Tokens are kept per server and profile in the Keychain, and the session is
  restored at launch.
- **Home**: a full-screen hero carousel like the TV app's (title, kind and genres with the age
  rating, a one-line description, Play and round watchlist, info and next buttons, page dots),
  Continue Watching rising into it (a click resumes, a long press offers the movie's or
  episode's page or a fresh start), and the server's shelves: recently added,
  new episodes, Want to Watch, recently played. The server's books, audiobooks and comics are
  left out: the TV app does not offer them.
- **Movies and Shows**: poster grids with sort pills (recent, title, year) and paging; the
  title and pill stay put while the grid scrolls below them.
- **Cards**: watched movies, episodes and fully watched shows are dimmed with an eye mark;
  episode tiles show the episode's own still (a frame of its video when it has none).
- **Tabs**: a tab left for five seconds goes back to its first page, scrolled to the top;
  coming back sooner keeps it as it was.
- **Details**: movie, show and episode pages offer Play, Resume and Restart, plus watchlist and
  watched toggles, and Trailer when the server knows one (the YouTube app plays it; without
  it, a QR code opens it on a phone; several trailers offer a choice). Show pages have seasons
  and episodes; all of them list cast with portraits, versions,
  tracks and file info. With server 0.5.0 or newer a show lists every aired episode, marked
  downloaded or not (only downloaded ones play), and the known upcoming ones greyed with their
  date.
- **Video player**: AVKit with the native transport bar and Info panel.
  - Direct play when Apple TV can decode the file; otherwise the server remuxes or transcodes
    to HLS, and the whole timeline stays seekable.
  - Resume prompt.
  - Audio, subtitle and quality menus. Text subtitles are side-loaded, image subtitles are
    burned in.
  - Up Next with a countdown. At the credits of an episode (server segments) it is "Next
    Episode", filling over 10 s of playing, beside "Watch Credits"; no countdown when a scene
    follows the credits. Credits entered another way (resume, a seek, autoplay off) offer the
    same two as buttons over the video, since the system panel comes only when playback
    reaches the credits' start.
  - Skip pills from the server's recap, intro and credits segments (3 s or longer): "Skip
    Recap" / "Skip Intro" over the video for 8 s after the segment starts (Select presses
    it), later as a button of the transport bar; "Skip Credits" of a film or last episode.
    "Skip Automatically" in the transport bar turns on, per profile and on every device,
    skipping the recap or intro by itself (once per segment, with a note and Go Back) and
    going on from the credits.
  - Progress is synced every 10 s, and items are marked watched at 92 %.
- **Music**: Listen Now, albums, artists, songs, genres and playlists.
  - Gapless queue with shuffle and repeat, favourites, and play reporting. Choosing a song in
    Songs queues the whole library from there.
  - Playlists: create, rename and delete; add songs or albums; move and remove songs.
  - Now Playing with synced lyrics: the lyrics page takes the artwork's colour, with the
    artwork, title and artist on the left and large lines on the right, the current one bright.
  - Background audio, with Control Center and remote controls.
- **TV**: the server's live channels made of the library, as a television has them.
  - One numbered list on a panel (the left ~46% of the page, its full height) beside a card of the
    focused channel's programme: the programme's still across the card, its title, episode, time and
    progress ("until 21:40"), overview and what is next. A row has the channel's number, logo, name and
    what is on with its progress; with a few channels the rows are tall and carry the programme's still,
    with many they are compact. Focus starts on the last channel. The category button next to the
    Channels | Guide switch opens the list of All, Favourites and the server's categories (AI topics,
    sources, playlist groups, with counts); a long press stars a channel.
  - The Guide: channels × time with a ruler, the now line and a block per programme; the
    remote moves between blocks keeping the time; a programme opens its details (Watch while
    it is on air, the channel's star).
  - The live player: Up / Down switch channels inside the list it was opened from (the old
    picture held until the new one starts); the banner shows the number, the name, what is on
    and next; Select opens the options (audio and subtitles of the programme, the star, the
    channel row); a swipe down opens the channel row.
  - TV is TV: a channel leaves no progress, history, resume point or watched mark; only the
    favourites and the last channel are saved on the server.
- **Search**: across movies, shows and music, with browse tiles. Each server addon that searches
  adds its own section, under its own heading, after the library's results; a title the library
  has opens its page, any other opens a page of its own.
- **Addon ways**: what the server's addons offer a title (docs/API.md §14), in the server's own
  words. A movie or show page shows the ways that watch as one pill with a chevron button beside
  it: with no Play of its own (a title the library lacks) the pill is «Play», else it carries the
  way's own label after Play. Select runs the way chosen for the title (else the first) with its
  remembered or best choice; the chevron opens a short menu: a row per way with a line on how it
  plays, the chosen one ticked (choosing another makes it the title's way and runs it), and «Audio
  & quality…», the step-by-step chooser. The ways that keep a copy on the server are round buttons
  with a progress ring (a long press cancels). An episode's Select runs the show's way, and its
  long-press menu has «Play», the same rows and the keep ways, also for episodes the library
  lacks; only the episode a run was started for shows its spinner. The streams play in the app's
  own player, whose bar has the stream's Subtitles and Quality (when the addon offers several; a
  switch restarts at the same position) and «Audio & source…», the way's chooser over the stream,
  which goes on from the position it is at. Nothing shows without addons or in a kid's profile.
- **Settings** (the profile tab):
  - Switch profile, or sign out (which revokes the device token on the server).
  - Default video quality, audio and subtitle languages, and autoplay of the next episode.
  - The film player lists voice-over files beside the video and their cleaned versions
    ("Cleaned"), each cleaned one under the track it was made from.
  - App language: System, English or Русский.
  - No server settings: the address, devices and library are managed in the web app.
  - Version and acknowledgements.
- **Top Shelf**: when the app is in the top row, the Home screen shows the profile's Continue
  Watching, the channels On Air Now and Recently Added. Selecting a tile opens its page; Play
  starts it; a channel opens its live player.
- **Deep links**: `antresol://item/{id}` opens an item's page, `antresol://play/{id}` plays it
  and `antresol://channel/{id}` opens a live channel. A link to a book opens Home.

## Requirements

- An Antresol server, v0.3.0 or newer, reachable from the Apple TV.
- Xcode 27.2 or newer (the tvOS 27 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build the app.
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

The app and the Top Shelf extension share their session through two entitlements, used in
`AntresolTV/AntresolTV.entitlements`, `TopShelf/TopShelf.entitlements` and
`Shared/SharedSession.swift`:

- the App Group `group.<bundle id>`, `group.app.antresol.tv` by default (server, profile and
  language, plus downloaded Top Shelf artwork);
- the Keychain group `<Team ID>.<bundle id>.shared` (the profile's token).

Without them the app still works; only the Top Shelf stays on the static brand image.

### Your team and bundle id

`project.yml` is neutral: bundle id `app.antresol.tv`, no team. Every target's config file,
`Antresol.xcconfig`, includes a git-ignored `Local.xcconfig` when it exists, and its values
override the defaults (for Debug and Release, and they survive `xcodegen generate`):

```sh
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM and ANTRESOL_BUNDLE_ID
```

Everything else follows `ANTRESOL_BUNDLE_ID`: the Top Shelf extension is `<id>.topshelf`, the UI
tests `<id>.uitests`, the App Group `group.<id>` (`ANTRESOL_APP_GROUP`) and the shared Keychain
group `<id>.shared` (`ANTRESOL_KEYCHAIN_GROUP`). The entitlements and the `AntresolAppGroup` /
`AntresolKeychainGroup` Info.plist keys the code reads are expanded from these build settings.
To ship in the same App Store record as an existing iOS app (universal purchase), use that
app's bundle id and team.

## Run on an Apple TV

1. Join the Apple Developer Program and note your Team ID (Membership details).
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
   (shown for the default bundle id; use yours from `Local.xcconfig`):
   - **Identifiers > App Groups**: register `group.app.antresol.tv`.
   - **Identifiers > App IDs**: register `app.antresol.tv` and `app.antresol.tv.topshelf`, enable
     **App Groups** on both and assign `group.app.antresol.tv` to each.
   - The Keychain group needs no registration: Keychain Sharing groups are allowed for every
     App ID of the team that lists them. Xcode's automatic signing adds App Groups and
     Keychain Sharing to the provisioning profiles.
   - Automatic signing needs a development profile even for an App Store archive, and Apple
     only makes a tvOS one when the team has at least one Apple TV registered (pairing it in
     step 3 registers it).
3. Pair the Apple TV: on the TV open Settings > Remotes and Devices > Remote App and Devices,
   then in Xcode Window > Devices and Simulators select it and enter the code.
4. Set `DEVELOPMENT_TEAM` in `Local.xcconfig` (see above), `xcodegen generate` and open
   `Antresol.xcodeproj`; both targets sign automatically with that team.
5. Pick the Apple TV as the run destination and Run. To check Top Shelf, sign in to a profile,
   move the app into the top row of the Home screen and focus it.

## Ship to TestFlight and the App Store

The version is `MARKETING_VERSION` in `project.yml` (1.1.0). The build number,
`CURRENT_PROJECT_VERSION`, is 1 in `project.yml` and must grow with every upload: pass it on the
command line (CI uses the run number, `github.run_number`).

1. In [App Store Connect](https://appstoreconnect.apple.com) > Apps > New App: platform tvOS,
   name Antresol, primary language English (U.S.), your bundle id, any SKU. To add Apple TV to an
   existing iOS app with the same bundle id instead (universal purchase), open that app and use
   the "+" next to the platform list in the sidebar to add tvOS.
2. Archive and upload (an App Store Connect role of App Manager or higher, signed in to Xcode;
   without an Xcode account, add `-authenticationKeyPath <AuthKey.p8> -authenticationKeyID <key>
   -authenticationKeyIssuerID <issuer>` of an App Store Connect API team key to both commands):

   ```sh
   xcodegen generate
   xcodebuild archive -project Antresol.xcodeproj -scheme AntresolTV \
     -destination 'generic/platform=tvOS' -archivePath build/Antresol.xcarchive \
     CURRENT_PROJECT_VERSION=<build> -allowProvisioningUpdates
   xcodebuild -exportArchive -archivePath build/Antresol.xcarchive \
     -exportOptionsPlist scripts/ExportOptions-AppStore.plist -exportPath build/export \
     -allowProvisioningUpdates
   ```

   `destination: upload` in the export options sends the build straight to App Store Connect.
   Xcode's Organizer (Window > Organizer > Distribute App > App Store Connect) does the same.
3. Export compliance is answered by `ITSAppUsesNonExemptEncryption = NO` in `Info.plist` (the app
   uses only the system's HTTPS), so the build goes to TestFlight without a question.
4. TestFlight: when the build finishes processing, add it to an internal testing group. Testers
   install the TestFlight app on Apple TV and sign in with their Apple Account. External testers
   need Beta App Review, which needs a demo server: put its address and a profile and password in
   Test Information.
5. App Store page: the texts are in `fastlane/metadata` (en-US and ru; check them with
   `python3 scripts/check-metadata.py`). Upload them with `fastlane deliver` (the `Deliverfile`
   targets `appletvos` and sends text only). Screenshots (1920x1080) can be taken from the
   [`screenshots` branch](https://github.com/antresol-app/antresol-tvos/tree/screenshots). App Privacy: "Data Not Collected"; both bundles
   carry a `PrivacyInfo.xcprivacy` with no tracking and the required-reason APIs (UserDefaults,
   file timestamps). App Review also needs the demo server details in the review notes.

## Tests

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

- The tests look for the mock server at `127.0.0.1:8421`. Another port goes through the
  test runner's environment, which `xcodebuild` fills from its own `TEST_RUNNER_…` variables
  (not from arguments after the command: those are build settings and never reach the tests,
  which then wait for a server that is not there and fail one by one on their timeouts):

  ```sh
  python3 scripts/mock-server.py --port 8497 &
  TEST_RUNNER_ANTRESOL_MOCK_SERVER=127.0.0.1:8497 xcodebuild test -project Antresol.xcodeproj -scheme AntresolTV \
    -destination "id=$SIM_UDID" -only-testing:AntresolTVUITests/ScreenshotTests/test02OnboardingAndHome
  ```

- `RuntimeTests` use the same mock server for what the screenshots do not show: Menu on the
  sign-in screens, the live player (every channel of the mock plays one short looped stream,
  `scripts/fixtures/live`), a transcoded song, a failed progress request with Try Again, a
  last channel far down the list, the guide's rows of two external channels with the same
  programme ids, and the hero's auto-advance. The hero test expects the
  hero to stay when the simulator has Reduce Motion on (`xcrun simctl spawn <udid> defaults
  write com.apple.Accessibility ReduceMotionEnabled -bool true`); CI runs it a second time
  that way, with `TEST_RUNNER_ANTRESOL_EXPECT_REDUCE_MOTION=1` so the run fails if the
  setting is not on, and the main run with `…=0`, so it fails if the setting was left on
  (`defaults delete com.apple.Accessibility ReduceMotionEnabled` puts it back). The mock
  also listens on the next port (8422 for `--port 8421`): the
  same server with QR sign-in, a long channel list, a longer guide with external channels,
  a series in Continue Watching, skip segments in its play answers (the skip pill on screen
  is the debug probe `player.skip`) and its test hooks (`/mock/events`,
  `/mock/reset`, `/mock/fail-progress/<id>`; see the script's header), none of which the
  main port has, so the screenshot tests keep seeing what they saw.
- `testAddonWays` needs the mock with `--addons` (two neutral addons: ways that watch and keep,
  a chooser, the chevron's menu of the ways, an input player that answers `202` first) and `TEST_RUNNER_ANTRESOL_MOCK_ADDONS=1`;
  it skips itself otherwise.
- The tests run in Russian with `TEST_RUNNER_ANTRESOL_TEST_LANGUAGE=ru` (the app is launched in Russian, and
  `RuntimeTests` look labels up in `ru.lproj/Localizable.strings`). Build the tests signed (no
  `CODE_SIGNING_ALLOWED=NO`): an unsigned app has no Keychain, cannot keep the mock's address and lands on the server
  screen, where a press of Select would connect to a server of the network.
- Without an Apple TV simulator yet: `xcrun simctl create "Apple TV 4K (3rd generation)"
  com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K <a tvOS runtime of
  "xcrun simctl list runtimes">`, and boot it before the run (`xcrun simctl bootstatus <udid> -b`).
- A test takes about a minute and the whole of `ScreenshotTests` about twenty. Run one test
  first (`-only-testing:`); when it fails at once, look at the mock server's log: no requests
  after `/api/health` means the app is not reaching it. `ChannelScreenshotTests` and
  `StoreScreenshotTests` skip themselves without their own variables (`TEST_RUNNER_CHANNELS_…`, `TEST_RUNNER_DEMO_…`:
  a real server).

## Architecture

```
AntresolKit/          Swift package, Foundation only (builds and tests on Linux)
  Models/             Codable API models with tolerant decoding
  Networking/         APIClient (async/await), APIError, ServerURLs, ServerAddress, TokenStore,
                      ChannelService (every channel request; favourites and last channel only)
  Playback/           VideoPlaybackSession, MediaKeyStore, PlaybackProgressReporter, PlayQueue,
                      ResumePolicy, UpNext, WebVTT
  Integration/        DeepLink (antresol:// URLs), TopShelfPlan (Top Shelf sections from /api/home),
                      TopShelfChannels (On Air Now)
AntresolTV/           The tvOS app
  App/                AntresolTVApp, AppState (session phases, language, deep links), Route
  Design/             Theme tokens, button styles, cards, shelves, hero, settings rows
  Services/           ImagePipeline (authenticated, cached artwork), Keychain token store,
                      AppSettings, AppLanguage, DeviceIdentity
  Views/              Onboarding, Shell (sidebar; top tab bar before tvOS 18), Home, Library, Detail, Search, TV,
                      Music, Settings
  Playback/           PlaybackCoordinator, VideoPlayerModel/View, LivePlayerModel/View, menus, subtitles, Up Next
  Audio/              AudioPlayer (app-wide AVQueuePlayer), Now Playing screen and system controls
TopShelf/             TVTopShelfContentProvider extension and artwork downloader
Shared/               Code compiled into both the app and the extension (Keychain, shared session)
AntresolTVUITests/    Screenshot tests against scripts/mock-server.py
```

- **Logic lives in the kit.** Everything that does not need an Apple UI framework sits in
  `AntresolKit`, so it is unit-tested on Linux in CI. This covers API calls, playback session
  rules, progress timing, queueing, subtitles, deep links and the Top Shelf
  plan.
- **Auth.** Each profile signs in with `POST /api/auth/token` and gets a device token. Every
  request sends `Authorization: Bearer` and `Accept-Language`, and so do image requests. Player
  URLs carry a short-lived media key (`?mk=`) instead, so AVPlayer needs no headers.
- **State.** `AppState` (`@Observable`) owns the server connection and the session phase.
  The signed-in shell has one `PlaybackCoordinator` for video and one `AudioPlayer` for music.
  Each tab has its own `NavigationStack`.
- **Top Shelf.** While a profile is signed in, the app writes the server, profile and language
  to the App Group defaults, and the token to the shared Keychain group. The extension reads
  them and fetches `/api/home` and `/api/channels`. It downloads the artwork with the Bearer header into the shared
  container, because the system cannot fetch authenticated images. Signing out clears the
  shared session.

See [docs/API.md](docs/API.md) for the server API, [PLAN.md](PLAN.md) for the original plan
and [NOTES.md](NOTES.md) for the per-milestone hand-off log, decisions and known gaps.

## CI

`.github/workflows/ci.yml` runs four jobs:

- `swift build` and `swift test` for the kit in a Swift 6.0.3 Linux container.
- `xcodegen` and `xcodebuild` for the tvOS Simulator (app and Top Shelf extension).
- `xcodebuild archive` of the Release configuration for devices, unsigned, with the run number as
  build number; it checks the App Store metadata, the privacy manifests, versions and the embedded
  Top Shelf extension.
- The UI screenshot tests on a tvOS simulator against the mock server. The screenshots are
  uploaded as an artifact and, on pushes to main, published to the
  [`screenshots` branch](https://github.com/antresol-app/antresol-tvos/tree/screenshots) with a README that shows them all.

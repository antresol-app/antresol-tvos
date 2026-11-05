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
  - Gapless queue with shuffle and repeat, favourites, and play reporting. Choosing a song in
    Songs queues the whole library from there.
  - Playlists: create, rename and delete; add songs or albums; move and remove songs.
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
  - Devices signed in to the profile, with sign-out of other devices.
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

The app and the Top Shelf extension share their session through two entitlements, used in
`AntresolTV/AntresolTV.entitlements`, `TopShelf/TopShelf.entitlements` and
`Shared/SharedSession.swift`:

- the App Group `group.app.antresol.tv` (server, profile and language, plus downloaded Top
  Shelf artwork);
- the Keychain group `<Team ID>.app.antresol.shared` (the profile's token).

Without them the app still works; only the Top Shelf stays on the static brand image.

## Run on an Apple TV

1. Join the Apple Developer Program and note your Team ID (Membership details).
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):
   - **Identifiers > App Groups**: register `group.app.antresol.tv`.
   - **Identifiers > App IDs**: register `app.antresol.tv` and `app.antresol.tv.topshelf`, enable
     **App Groups** on both and assign `group.app.antresol.tv` to each.
   - The Keychain group needs no registration: Keychain Sharing groups are allowed for every
     App ID of the team that lists them, and the entitlements already list
     `$(AppIdentifierPrefix)app.antresol.shared` for both targets. Xcode's automatic signing
     adds App Groups and Keychain Sharing to the provisioning profiles.
   - With your own bundle ids, change `bundleIdPrefix`/`PRODUCT_BUNDLE_IDENTIFIER` in
     `project.yml`, the group in both `.entitlements` files and `SharedSession.appGroup`.
3. Pair the Apple TV: on the TV open Settings > Remotes and Devices > Remote App and Devices,
   then in Xcode Window > Devices and Simulators select it and enter the code.
4. `xcodegen generate`, open `Antresol.xcodeproj`, and in Signing & Capabilities choose your
   team with "Automatically manage signing" for **AntresolTV** and **TopShelf** (regenerating
   the project resets this; pass `DEVELOPMENT_TEAM=<Team ID>` on the `xcodebuild` command line
   instead to keep it scripted).
5. Pick the Apple TV as the run destination and Run. To check Top Shelf, sign in to a profile,
   move the app into the top row of the Home screen and focus it.

## Ship to TestFlight and the App Store

The version is `MARKETING_VERSION` in `project.yml` (1.0.0). The build number,
`CURRENT_PROJECT_VERSION`, is 1 in `project.yml` and must grow with every upload: pass it on the
command line (CI uses the run number, `github.run_number`).

1. In [App Store Connect](https://appstoreconnect.apple.com) > Apps > New App: platform tvOS,
   name Antresol, primary language English (U.S.), bundle id `app.antresol.tv`, any SKU.
2. Archive and upload (an App Store Connect role of App Manager or higher, signed in to Xcode):

   ```sh
   xcodegen generate
   xcodebuild archive -project Antresol.xcodeproj -scheme AntresolTV \
     -destination 'generic/platform=tvOS' -archivePath build/Antresol.xcarchive \
     DEVELOPMENT_TEAM=<Team ID> CURRENT_PROJECT_VERSION=<build> -allowProvisioningUpdates
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
   [`screenshots` branch](https://github.com/sidun-av/antresol-tvos/tree/screenshots). App Privacy: "Data Not Collected"; both bundles
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

`.github/workflows/ci.yml` runs four jobs:

- `swift build` and `swift test` for the kit in a Swift 6.0.3 Linux container.
- `xcodegen` and `xcodebuild` for the tvOS Simulator (app and Top Shelf extension).
- `xcodebuild archive` of the Release configuration for devices, unsigned, with the run number as
  build number; it checks the App Store metadata, the privacy manifests, versions and the embedded
  Top Shelf extension.
- The UI screenshot tests on a tvOS simulator against the mock server. The screenshots are
  uploaded as an artifact and, on pushes to main, published to the
  [`screenshots` branch](https://github.com/sidun-av/antresol-tvos/tree/screenshots) with a README that shows them all.

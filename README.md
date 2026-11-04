# Antresol — Apple TV

The Antresol home media player for Apple TV. Connects to your own
[Antresol server](https://github.com/sidun-av/antresol). See [PLAN.md](PLAN.md) and [NOTES.md](NOTES.md).

## Layout
- `AntresolKit/` — Swift package (Foundation only): API models, client, playback and progress logic.
  `cd AntresolKit && swift test` (set `ANTRESOL_TEST_SERVER=1` to also run the live-server tests).
- `AntresolTV/` — the tvOS SwiftUI app. `project.yml` generates the Xcode project.

## Build
    brew install xcodegen && xcodegen generate && open Antresol.xcodeproj

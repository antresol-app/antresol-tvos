import AntresolKit
import SwiftUI

/// The Now Playing screen for music and audiobooks: large artwork over a blurred, tinted
/// backdrop; title, scrubber and transport controls on the left; Up Next, Lyrics or
/// Chapters on the right. Shown full screen when playback starts and as the Now Playing tab.
struct NowPlayingView: View {
    /// In the tab the top tab bar overlaps the page, so content starts lower.
    var isInTab = false

    @Environment(AudioPlayer.self) private var audio

    var body: some View {
        if let item = audio.current {
            NowPlayingContent(item: item, isInTab: isInTab)
        } else {
            EmptyStateView(systemImage: "waveform", title: "Nothing is playing", message: "Play an album, a playlist or an audiobook and it shows up here.")
                .background(Theme.Colors.background.ignoresSafeArea())
        }
    }
}

private struct NowPlayingContent: View {
    let item: AudioPlayer.Item
    let isInTab: Bool

    enum Panel: Hashable {
        case upNext, lyrics, chapters
    }

    @Environment(AudioPlayer.self) private var audio
    @State private var panel: Panel = .upNext
    @State private var showsSpeed = false
    @State private var showsSleep = false
    /// Playback controls start out focused, not the scrubber above them.
    @FocusState private var focusedControl: FocusedControl?

    enum FocusedControl: Hashable {
        case playPause
    }

    private var artworkSize: CGFloat { isInTab ? 440 : 520 }

    var body: some View {
        ZStack {
            NowPlayingBackground(item: item)
            HStack(alignment: .top, spacing: 90) {
                leftColumn
                    .frame(width: 680, alignment: .leading)
                rightPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.top, isInTab ? 150 : 70)
            .padding(.bottom, 50)
        }
        .defaultFocus($focusedControl, .playPause)
        .overlay(alignment: .bottom) {
            if let notice = audio.notice {
                NoticeBanner(message: notice)
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.easeOut, value: audio.notice)
        .onPlayPauseCommand { audio.togglePlayPause() }
        .onChange(of: availablePanels) { _, panels in
            if !panels.contains(panel), let first = panels.first { panel = first }
        }
        .onAppear {
            if let first = availablePanels.first, !availablePanels.contains(panel) { panel = first }
        }
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardArtwork(title: item.album.isEmpty ? item.title : item.album, paths: [item.artwork], cornerRadius: 16, maxPixelSize: artworkSize * 2)
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
                .scaleEffect(audio.isPlaying ? 1 : 0.94)
                .animation(Theme.Motion.slowEaseOut, value: audio.isPlaying)

            VStack(alignment: .leading, spacing: 6) {
                if let chapter = audio.currentChapter, !chapter.title.isEmpty {
                    Text(verbatim: chapter.title)
                        .font(Theme.Typography.eyebrow)
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                Text(verbatim: item.title)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: metaLine([item.artist, item.album]))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
            }
            .padding(.top, 36)

            ScrubBar(
                position: scrubPosition,
                duration: scrubDuration,
                step: audio.book != nil ? 30 : 10,
                isBuffering: audio.isBuffering,
                seek: seek,
                select: audio.togglePlayPause
            )
            .padding(.top, 28)

            controls
                .padding(.top, 28)
        }
    }

    private var scrubPosition: Double {
        audio.book != nil ? Double(audio.bookPositionMs) / 1000 : audio.position
    }

    private var scrubDuration: Double {
        if let book = audio.book { return Double(book.durationMs) / 1000 }
        return audio.durationSec
    }

    private func seek(_ seconds: Double) {
        if audio.book != nil {
            audio.seek(toBookMs: Int(seconds * 1000))
        } else {
            audio.seek(to: seconds)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if audio.book != nil {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) {
                    transportButton("Back 15 Seconds", "gobackward.15") { audio.skip(by: -15) }
                    transportButton("Previous Chapter", "backward.end.fill") { audio.previous() }
                    playPauseButton
                    transportButton("Next Chapter", "forward.end.fill") { audio.next() }
                    transportButton("Forward 30 Seconds", "goforward.30") { audio.skip(by: 30) }
                }
                HStack(spacing: 20) {
                    Button {
                        showsSpeed = true
                    } label: {
                        Label {
                            Text(verbatim: AudioFormat.speed(audio.speed))
                        } icon: {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                    .accessibilityLabel(Text("Playback Speed"))

                    Button {
                        showsSleep = true
                    } label: {
                        Label {
                            SleepTimerLabel()
                        } icon: {
                            Image(systemName: "moon.zzz")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                    .accessibilityLabel(Text("Sleep Timer"))
                }
            }
            .focusSection()
            .confirmationDialog("Playback Speed", isPresented: $showsSpeed) {
                ForEach(AudioPlayer.speeds, id: \.self) { speed in
                    Button(AudioFormat.speed(speed) + (speed == audio.speed ? " ✓" : "")) { audio.setSpeed(speed) }
                }
            }
            .confirmationDialog("Sleep Timer", isPresented: $showsSleep) {
                ForEach(AudioPlayer.SleepTimer.choices, id: \.self) { timer in
                    Button(AudioFormat.sleepTimer(timer)) { audio.setSleepTimer(timer) }
                }
                if audio.sleepTimer != nil {
                    Button("Turn Off Timer", role: .destructive) { audio.setSleepTimer(nil) }
                }
            }
        } else {
            HStack(spacing: 18) {
                Button {
                    audio.setShuffle(!audio.queue.isShuffled)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(CircleButtonStyle(diameter: 80, isActive: audio.queue.isShuffled))
                .accessibilityValue(Text(audio.queue.isShuffled ? LocalizedStringKey("On") : LocalizedStringKey("Off")))

                transportButton("Previous", "backward.fill") { audio.previous() }
                playPauseButton
                transportButton("Next", "forward.fill") { audio.next() }
                    .disabled(audio.queue.nextIndex == nil)

                Button {
                    audio.cycleRepeat()
                } label: {
                    Label("Repeat", systemImage: audio.queue.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .buttonStyle(CircleButtonStyle(diameter: 80, isActive: audio.queue.repeatMode != .off))
                .accessibilityValue(Text(verbatim: AudioFormat.repeatMode(audio.queue.repeatMode)))

                if let track = audio.currentTrack {
                    let starred = audio.isStarred(track)
                    Button {
                        audio.toggleStar(track)
                    } label: {
                        Label(starred ? "Remove from Favorites" : "Add to Favorites", systemImage: starred ? "star.fill" : "star")
                    }
                    .buttonStyle(CircleButtonStyle(diameter: 80, isActive: starred))
                }
            }
            .focusSection()
        }
    }

    private var playPauseButton: some View {
        Button {
            audio.togglePlayPause()
        } label: {
            Label(audio.isPlaying ? "Pause" : "Play", systemImage: audio.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(CircleButtonStyle(diameter: 112))
        .focused($focusedControl, equals: .playPause)
    }

    private func transportButton(_ title: LocalizedStringKey, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(CircleButtonStyle(diameter: 80))
    }

    // MARK: Right panel

    private var availablePanels: [Panel] {
        if audio.book != nil {
            return (audio.book?.chapters.count ?? 0) > 1 ? [.chapters] : []
        }
        return (audio.currentTrack?.hasLyrics ?? false) ? [.upNext, .lyrics] : [.upNext]
    }

    @ViewBuilder
    private var rightPanel: some View {
        let panels = availablePanels
        if !panels.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                if panels.count > 1 {
                    SegmentedPill(options: panels.map { SegmentedPill<Panel>.Option(value: $0, title: Self.title($0)) }, selection: $panel)
                } else if let only = panels.first {
                    Text(verbatim: Self.title(only))
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .frame(minHeight: 72)
                }
                switch panel {
                case .upNext:
                    UpNextPanel()
                case .lyrics:
                    if let track = audio.currentTrack {
                        LyricsPanel(track: track)
                            .id(track.id)
                    }
                case .chapters:
                    if let book = audio.book {
                        ChaptersPanel(book: book)
                    }
                }
            }
            .focusSection()
        }
    }

    private static func title(_ panel: Panel) -> String {
        switch panel {
        case .upNext: return String(localized: "Up Next", bundle: .localized)
        case .lyrics: return String(localized: "Lyrics", bundle: .localized)
        case .chapters: return String(localized: "Chapters", bundle: .localized)
        }
    }
}

/// "Sleep Timer", or what it is set to with a live countdown.
private struct SleepTimerLabel: View {
    @Environment(AudioPlayer.self) private var audio

    var body: some View {
        if let deadline = audio.sleepDeadline {
            Text(timerInterval: Date()...max(Date(), deadline), countsDown: true)
                .monospacedDigit()
        } else if audio.sleepTimer == .endOfChapter {
            Text("End of Chapter")
        } else {
            Text("Sleep Timer")
        }
    }
}

/// Blurred artwork washed with the artwork's tint, fading to black.
private struct NowPlayingBackground: View {
    let item: AudioPlayer.Item

    var body: some View {
        ZStack {
            HeroBackground(card: Card(id: 0, kind: .album, title: item.album.isEmpty ? item.title : item.album, poster: item.artwork))
            if !item.artwork.isEmpty {
                RemoteImage(path: item.artwork, maxPixelSize: 300)
                    .blur(radius: 90)
                    .opacity(0.45)
                    .scaleEffect(1.3)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Scrubber

/// The playback position: a focusable bar. Left and right seek by `step` (presses add
/// up before the seek is sent), select toggles play/pause.
private struct ScrubBar: View {
    let position: Double
    let duration: Double
    let step: Double
    let isBuffering: Bool
    let seek: (Double) -> Void
    let select: () -> Void

    @FocusState private var isFocused: Bool
    @State private var target: Double?
    @State private var commitTask: Task<Void, Never>?

    private var shown: Double { target ?? position }

    private var fraction: Double {
        duration > 0 ? min(max(shown / duration, 0), 1) : 0
    }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                    if isFocused {
                        Circle()
                            .fill(.white)
                            .frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.4), radius: 6)
                            .offset(x: proxy.size.width * fraction - 13)
                    }
                }
                .frame(height: proxy.size.height)
            }
            .frame(height: isFocused ? 12 : 8)
            HStack {
                Text(verbatim: PlaybackTime.clock(shown))
                Spacer()
                if isBuffering {
                    ProgressView().scaleEffect(0.6).frame(height: 20)
                }
                Spacer()
                Text(verbatim: "−" + PlaybackTime.clock(max(0, duration - shown)))
            }
            .font(Theme.Typography.cardMeta.monospacedDigit())
            .foregroundStyle(isFocused ? Theme.Colors.label : Theme.Colors.label2)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(Theme.Motion.easeOut, value: isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: nudge(-step)
            case .right: nudge(step)
            default: break
            }
        }
        .onTapGesture(perform: select)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback Position"))
        .accessibilityValue(Text(verbatim: PlaybackTime.clock(shown)))
    }

    private func nudge(_ delta: Double) {
        guard duration > 0 else { return }
        target = min(max(0, (target ?? position) + delta), max(0, duration - 1))
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let value = target else { return }
            seek(value)
            // Keep showing the target until the player catches up.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            target = nil
        }
    }
}

// MARK: - Panels

private struct UpNextPanel: View {
    @Environment(AudioPlayer.self) private var audio

    var body: some View {
        let upcoming = Array(audio.queue.upcoming)
        if upcoming.isEmpty {
            Text(audio.queue.repeatMode == .all ? "The queue starts over after this song." : "Nothing up next.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
                .focusable()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(upcoming) { entry in
                        Button {
                            audio.play(entry: entry.id)
                        } label: {
                            QueueRowLabel(item: entry.element)
                        }
                        .buttonStyle(ListRowButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                audio.remove(entry: entry.id)
                            } label: {
                                Label("Remove from Queue", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .listRowOutdent()
            }
            .scrollClipDisabled()
        }
    }
}

private struct QueueRowLabel: View {
    let item: AudioPlayer.Item
    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        HStack(spacing: 24) {
            CardArtwork(title: item.album.isEmpty ? item.title : item.album, paths: [item.artwork], cornerRadius: 8, maxPixelSize: 140, showsPlaceholderTitle: false)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
                Text(verbatim: item.artist)
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(isFocused ? Theme.Colors.labelInverse.opacity(0.65) : Theme.Colors.label2)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            if item.durationMs > 0 {
                Text(verbatim: PlaybackTime.clock(Double(item.durationMs) / 1000))
                    .font(Theme.Typography.meta.monospacedDigit())
                    .foregroundStyle(isFocused ? Theme.Colors.labelInverse.opacity(0.65) : Theme.Colors.label2)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ChaptersPanel: View {
    let book: BookDetail
    @Environment(AudioPlayer.self) private var audio

    var body: some View {
        let current = audio.currentChapter
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            audio.seek(toBookMs: chapter.startMs)
                        } label: {
                            ChapterRowLabel(chapter: chapter, number: index + 1, isCurrent: chapter == current)
                        }
                        .buttonStyle(ListRowButtonStyle())
                        .id(chapter.id)
                    }
                }
                .padding(.vertical, 12)
                .listRowOutdent()
            }
            .scrollClipDisabled()
            .onAppear {
                if let current { proxy.scrollTo(current.id, anchor: .center) }
            }
        }
    }
}

/// Lyrics of the current song: synced lines follow the music with the current line
/// highlighted; plain lyrics scroll line by line.
private struct LyricsPanel: View {
    let track: Track

    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var loader = ContentLoader<Lyrics?>()

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            case .failed(let message):
                Text(verbatim: message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
                    .focusable()
            case .loaded(let lyrics):
                if let lyrics, lyrics.synced, !lyrics.lines.isEmpty {
                    SyncedLyrics(lines: lyrics.lines, current: lyrics.lineIndex(at: audio.position))
                } else if let lyrics, !lyrics.lyrics.isEmpty {
                    PlainLyrics(lines: lyrics.lyrics.components(separatedBy: .newlines))
                } else {
                    Text("No lyrics for this song.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label2)
                        .focusable()
                }
            }
        }
        .task(id: track.id) {
            await loader.load(using: appState) { try await $0.lyrics(trackId: track.id) }
        }
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricLine]
    let current: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(index == current ? Theme.Colors.label : Theme.Colors.label3)
                            .scaleEffect(index == current ? 1 : 0.96, anchor: .leading)
                            .animation(Theme.Motion.easeOut, value: current)
                            .id(index)
                    }
                }
                .padding(.vertical, 200)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .onChange(of: current) { _, index in
                guard let index else { return }
                withAnimation(Theme.Motion.slowEaseOut) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }
}

private struct PlainLyrics: View {
    let lines: [String]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    LyricLineView(text: line)
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
    }
}

/// One focusable lyric line, so the remote can scroll through plain lyrics.
private struct LyricLineView: View {
    let text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        Text(verbatim: text.isEmpty ? " " : text)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(isFocused ? Theme.Colors.label : Theme.Colors.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
    }
}

/// Display strings for the audio player.
enum AudioFormat {
    /// "1×", "1.25×".
    static func speed(_ value: Float) -> String {
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
        return number + "×"
    }

    static func sleepTimer(_ timer: AudioPlayer.SleepTimer) -> String {
        switch timer {
        case .minutes(let minutes): return String(localized: "\(minutes) min", bundle: .localized)
        case .endOfChapter: return String(localized: "End of Chapter", bundle: .localized)
        }
    }

    static func repeatMode(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return String(localized: "Off", bundle: .localized)
        case .all: return String(localized: "Repeat All", bundle: .localized)
        case .one: return String(localized: "Repeat One", bundle: .localized)
        }
    }
}

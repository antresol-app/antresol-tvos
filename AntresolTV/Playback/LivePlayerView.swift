import AVFoundation
import AntresolKit
import Combine
import SwiftUI
import UIKit

/// The full-screen live player presented by the shell for
/// `PlaybackCoordinator.presentedChannel`. The picture fills the screen; the channel banner
/// (the number, the name, Live, what is on with its progress, what is next) slides in on
/// every change and fades after 5 s. Up / Down (clicks) and the channel buttons zap through
/// the list the player was opened from; a swipe down opens the mini-guide, a row of those
/// channels with focus on the current one; Select brings up the options row (star, audio,
/// subtitles, channels); Menu closes what is open first, then leaves. A zap holds the old
/// picture, dimmed, until the new channel's first frame.
struct LivePlayerView: View {
    let request: PlaybackCoordinator.LiveRequest

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: LivePlayerModel

    init(request: PlaybackCoordinator.LiveRequest) {
        self.request = request
        _model = State(initialValue: LivePlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.state {
            case .failed(let message):
                LiveErrorView(model: model, message: message) { dismiss() }
            default:
                LivePlayerSurface(model: model) { dismiss() }
                    .ignoresSafeArea()
                if model.isHoldingFrame {
                    // The previous channel's last frame, dimmed, with a quiet spinner.
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .overlay {
                            ProgressView()
                                .padding(36)
                                .glassSurface(in: Circle(), highlighted: false, interactive: false)
                                .padding(.bottom, 200)
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if case .connecting(let isStarting) = model.state {
                    LiveConnectingView(model: model, isStarting: isStarting)
                        .allowsHitTesting(false)
                }
                if let text = model.subtitleText, !model.showsGuide {
                    LiveSubtitle(text: text, raised: model.showsInfo)
                }
                if model.showsInfo {
                    LiveBanner(model: model)
                        .transition(Theme.Motion.rise(reduceMotion: reduceMotion))
                }
                if model.showsGuide {
                    LiveChannelRail(model: model)
                        .transition(Theme.Motion.rise(reduceMotion: reduceMotion))
                }
            }
        }
        .animation(Theme.Motion.slowEaseOut, value: model.showsInfo)
        .animation(Theme.Motion.slowEaseOut, value: model.showsGuide)
        .animation(Theme.Motion.easeOut, value: model.showsControls)
        .animation(Theme.Motion.easeOut, value: model.openMenu)
        .animation(Theme.Motion.easeOut, value: model.isHoldingFrame)
        .animation(Theme.Motion.easeOut, value: model.state)
        .task { model.start(appState: appState, coordinator: coordinator) }
        .task {
            // A programme boundary picks the next programme's tracks; «В эфир» follows the lag.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.tick()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.suspend()
            case .active: model.resumeFromBackground()
            default: break
            }
        }
        .onDisappear {
            model.stop()
            coordinator.liveChannelDidClose(request)
        }
    }
}

// MARK: - Subtitles

/// The subtitle cue, centred near the bottom (the film player's look, in the viewer's
/// caption style), lifted above the banner while it is up.
private struct LiveSubtitle: View {
    let text: String
    let raised: Bool
    @State private var style = CaptionStyle.current

    var body: some View {
        VStack {
            Spacer()
            Text(verbatim: text)
                .font(.system(size: style.fontSize, weight: .semibold))
                .foregroundStyle(Color(uiColor: style.textColor))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .shadow(color: .black.opacity(0.9), radius: 4, y: 1)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(Color(uiColor: style.plateColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: 1500)
                .padding(.bottom, raised ? 330 : 96)
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(Theme.Motion.easeOut, value: raised)
        .onReceive(NotificationCenter.default.publisher(for: CaptionStyle.didChange).receive(on: DispatchQueue.main)) { _ in
            style = .current
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: text))
    }
}

// MARK: - Banner and mini-guide

/// The channel banner: a glass panel along the bottom edge. The channel's identity is its
/// number and name (with its uploaded logo, when it has one); then what is on, its progress and times, and what is next.
/// With the options row up, the star, audio, subtitles and the channel list sit on its
/// right and take focus.
private struct LiveBanner: View {
    let model: LivePlayerModel

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let onAir = model.onAir(at: context.date)
            VStack(alignment: .trailing, spacing: 24) {
                Spacer()
                if let menu = model.openMenu {
                    TrackMenu(model: model, kind: menu)
                        .padding(.trailing, Theme.Layout.margin + 32)
                        .transition(Theme.Motion.rise(reduceMotion: reduceMotion))
                }
                HStack(alignment: .center, spacing: 44) {
                    Text(verbatim: String(model.channel.number))
                        .font(.system(size: 76, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.label2)
                        .frame(minWidth: 120, alignment: .trailing)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 18) {
                            ChannelLogo(model.channel, height: 44)
                            Text(verbatim: model.channel.name)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.label)
                                .lineLimit(1)
                            if model.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.label2)
                            }
                            if model.isBehindLive { GoLiveBadge() } else { LiveBadge() }
                        }
                        if let now = onAir.now {
                            Text(verbatim: now.fullTitle)
                                .font(Theme.Typography.sectionTitle)
                                .foregroundStyle(Theme.Colors.label)
                                .lineLimit(1)
                            HStack(spacing: 24) {
                                LiveProgressBar(value: now.progress(at: context.date), height: 8)
                                    .frame(width: 420)
                                Text(verbatim: now.timeRange(locale))
                                    .font(Theme.Typography.meta)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Colors.label2)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("Nothing on now")
                                .font(Theme.Typography.sectionTitle)
                                .foregroundStyle(Theme.Colors.label)
                        }
                        if let next = onAir.next {
                            Text(verbatim: next.nextLine(locale))
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.label2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if model.showsControls {
                        LiveControls(model: model)
                            .transition(.opacity)
                    } else {
                        RemoteHints()
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 32)
                .padding(.horizontal, 40)
                // A dark backing keeps the glass legible over a bright, saturated picture.
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 12, style: .continuous))
                .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 12, style: .continuous), highlighted: false, interactive: false)
                .padding(.horizontal, Theme.Layout.margin)
                .padding(.bottom, 60)
            }
            .background(alignment: .bottom) { BottomScrim(height: 520) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(model.showsControls)
    }
}

/// The options row: audio, subtitles, the star and the channel list, as round glass
/// buttons (the system player's transport-bar idiom).
private struct LiveControls: View {
    let model: LivePlayerModel

    @FocusState private var focused: Control?

    enum Control: Hashable {
        case goLive, audio, subtitles, favorite, channels
    }

    var body: some View {
        let audio = model.audioEntries()
        let subtitles = model.subtitleEntries()
        GlassGroup(spacing: 24) {
            HStack(spacing: 24) {
                if model.isBehindLive {
                    control(.goLive, "Go Live", "forward.end.fill", isActive: false) {
                        model.goLive()
                        model.closeControls()
                    }
                }
                if audio.count > 1 {
                    control(.audio, "Audio", "speaker.wave.2.fill", isActive: model.openMenu == .audio) {
                        model.openMenu = model.openMenu == .audio ? nil : .audio
                    }
                }
                if !subtitles.isEmpty {
                    control(.subtitles, "Subtitles", model.subtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill", isActive: model.openMenu == .subtitles) {
                        model.openMenu = model.openMenu == .subtitles ? nil : .subtitles
                    }
                }
                control(.favorite, model.isFavorite ? "Remove from Favourites" : "Add to Favourites", model.isFavorite ? "star.fill" : "star", isActive: false) {
                    model.toggleFavorite()
                }
                control(.channels, "Channels", "list.bullet", isActive: false) {
                    model.showGuide()
                }
            }
        }
        .focusSection()
        .defaultFocus($focused, first(audio: audio, subtitles: subtitles))
        .onAppear {
            // The picture gives up focus as the row appears: hand it to the row.
            focused = first(audio: audio, subtitles: subtitles)
        }
        .onExitCommand { model.closeControls() }
        .onMoveCommand { direction in
            if direction == .up, model.openMenu == nil { model.closeControls() }
        }
        // Menu (Back) on an open list closes it: focus goes back to the button that opened it.
        .onChange(of: model.openMenu) { old, new in
            guard new == nil, let old else { return }
            focused = old == .audio ? .audio : .subtitles
        }
    }

    /// Audio when there is a choice, else subtitles, else the star.
    private func first(audio: [LiveTrack], subtitles: [LiveTrack]) -> Control {
        if model.isBehindLive { return .goLive }
        return audio.count > 1 ? .audio : (subtitles.isEmpty ? .favorite : .subtitles)
    }

    private func control(_ id: Control, _ title: LocalizedStringKey, _ symbol: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(CircleButtonStyle(diameter: 84, isActive: isActive))
        .focused($focused, equals: id)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("live.\(id)")
    }
}

/// The audio or subtitle list over the options row: the programme's entries with their
/// labels («Русский — LostFilm»), a check on the one that plays. Any number of entries (a
/// channel carries up to 8 voices and 6 subtitle languages): past what fits above the
/// banner the list scrolls, the focused row kept in view. A pick sticks for the session
/// (programmes and channels) and is not saved anywhere.
private struct TrackMenu: View {
    let model: LivePlayerModel
    let kind: TrackMenuKind

    @FocusState private var focused: String?
    /// The rows' own height (the list is as tall as they are, up to `maxListHeight`).
    @State private var contentHeight: CGFloat = 0

    /// The tallest the list gets before it scrolls: it stays clear of the top of the
    /// screen above the banner (about six rows).
    static let maxListHeight: CGFloat = 540
    static let visibleRows = 6

    var body: some View {
        let all = kind == .audio ? model.audioEntries() : model.subtitleEntries()
        // a cleaned voice is not a row: «Clean voice-over» under the voices (the film player's switch)
        let current = kind == .audio ? all.first { $0.name == model.audioTrack?.name } : nil
        let cleanedOn = current?.cleanedOf != nil
        let entries = all.filter { $0.cleanedOf == nil }
        let selected = kind == .audio ? (current?.cleanedOf ?? model.audioTrack?.name ?? "") : (model.subtitleTrack?.name ?? "")
        let twin = { (name: String) in all.first { $0.cleanedOf == name } }
        let cleanedTwin = kind == .audio ? twin(selected) : nil
        let count = entries.count + (kind == .subtitles ? 1 : 0)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind == .audio ? "Audio" : "Subtitles")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Colors.label3)
                Spacer()
                if count > Self.visibleRows {
                    Text(verbatim: "\(count)")
                        .font(Theme.Typography.eyebrow)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.label3)
                }
            }
            .padding(.horizontal, Theme.Layout.listRowInset)
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        if kind == .subtitles {
                            row(id: "", title: String(localized: "Off", bundle: .localized), isOn: selected.isEmpty) {
                                model.selectSubtitle(nil)
                            }
                            .id("")
                        }
                        ForEach(entries) { entry in
                            row(id: entry.name, title: entry.voiceAndLanguage.voice, detail: entry.voiceAndLanguage.language, isOn: entry.name == selected) {
                                if kind == .audio { model.selectAudio((cleanedOn ? twin(entry.name) : nil) ?? entry) } else { model.selectSubtitle(entry) }
                            }
                            .id(entry.name)
                        }
                        if let tw = cleanedTwin {
                            row(id: "clean", title: String(localized: "Clean voice-over", bundle: .localized),
                                detail: String(localized: "Without the original speech under it", bundle: .localized), isOn: cleanedOn) {
                                model.selectAudio(cleanedOn ? (all.first { $0.name == selected } ?? tw) : tw)
                            }
                            .id("clean")
                        }
                    }
                    // room for the focused row's lift
                    .padding(.vertical, 8)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                }
                .frame(height: contentHeight == 0 ? Self.maxListHeight : min(contentHeight, Self.maxListHeight))
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .padding(24)
        .frame(width: 720, alignment: .leading)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 8, style: .continuous))
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 8, style: .continuous), highlighted: false, interactive: false)
        .focusSection()
        .defaultFocus($focused, selected)
        // Keyed on the opening, not on the list's appearance: a list opened again while
        // it is still leaving (its 0.26 s transition) is the same view brought back, with
        // no `onAppear`, and focus stayed on the button that opened it.
        .task(id: model.menuOpenings) { focused = selected }
        .onExitCommand { model.openMenu = nil }
    }

    private func row(id: String, title: String, detail: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 28)
                Text(verbatim: title)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if let detail {
                    // the language, quiet, on the trailing side (a settings row's value)
                    Text(verbatim: detail)
                        .font(Theme.Typography.meta)
                        .opacity(0.6)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(ListRowButtonStyle())
        .focused($focused, equals: id)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("live.track.\(id.isEmpty ? "off" : id)")
    }
}

/// What the remote does here: Up / Down switch channels, a swipe down lists them, Select
/// opens the options.
private struct RemoteHints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Switch Channel", systemImage: "chevron.up.chevron.down")
            Label("Options", systemImage: "circle.circle")
        }
        .labelStyle(HintLabelStyle())
        .font(Theme.Typography.cardMeta)
        .foregroundStyle(Theme.Colors.label2)
        .padding(.trailing, 12)
    }
}

private struct HintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.system(size: 20, weight: .bold))
                .frame(width: 44, height: 44)
                .glassSurface(in: Circle(), highlighted: false, interactive: false)
            configuration.title
        }
    }
}

/// A soft dark fade up from the bottom edge, so text and glass read over a bright picture.
private struct BottomScrim: View {
    let height: CGFloat
    /// The darkness at the bottom edge.
    var depth: Double = 0.7

    var body: some View {
        LinearGradient(colors: [.clear, .black.opacity(depth * 0.55), .black.opacity(depth)], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
    }
}

/// The mini-guide: the channels of the list the player was opened from, along the bottom,
/// focus on the current one. Each card is the programme's still with the number and the
/// name, what is on and its progress. Select switches; Up or Menu closes the row.
private struct LiveChannelRail: View {
    let model: LivePlayerModel

    @FocusState private var focused: Int?
    /// Fixed when the row opens, so a refresh or a zap does not move it under the focus.
    @State private var order: [Int]?

    private static let cardWidth: CGFloat = 400

    var body: some View {
        let channels = fresh(order ?? model.zapList.map(\.id))
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(verbatim: model.filter == .all ? String(localized: "Channels", bundle: .localized) : model.filter.title(in: model.categories))
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
                .padding(.horizontal, Theme.Layout.margin)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Layout.cardSpacing) {
                        ForEach(channels) { channel in
                            Button {
                                model.tune(to: channel)
                            } label: {
                                RailCard(channel: channel, isCurrent: channel.id == model.channel.id, width: Self.cardWidth)
                            }
                            .buttonStyle(CardButtonStyle())
                            .focused($focused, equals: channel.id)
                            .id(channel.id)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.margin)
                    .padding(.vertical, 28)
                }
                .scrollClipDisabled()
                // A horizontal scroll view takes all the height it is offered; the row
                // keeps to its cards so it sits on the bottom edge.
                .fixedSize(horizontal: false, vertical: true)
                .onAppear {
                    order = model.zapList.map(\.id)
                    proxy.scrollTo(model.channel.id, anchor: .center)
                    focused = model.channel.id
                }
            }
            .defaultFocus($focused, model.channel.id)
            .padding(.bottom, 30)
        }
        // Captions sit straight on the picture: a deeper fade than the banner's.
        .background(alignment: .bottom) { BottomScrim(height: 760, depth: 0.9) }
        .ignoresSafeArea()
        .focusSection()
        .onExitCommand { model.hideGuide() }
        .onMoveCommand { direction in
            if direction == .up { model.hideGuide() }
        }
    }

    /// The row's channels as the latest list has them (what is on moves on).
    private func fresh(_ ids: [Int]) -> [Channel] {
        let latest = Dictionary(model.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in latest[id] ?? (model.channel.id == id ? model.channel : nil) }
    }
}

/// A channel in the mini-guide: the programme's still (a play mark on the channel being
/// watched) with its progress, then "10 · Name" and what is on.
private struct RailCard: View {
    let channel: Channel
    let isCurrent: Bool
    let width: CGFloat

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let program = channel.program(at: context.date)
            VStack(alignment: .leading, spacing: 0) {
                ProgrammeStill(program: program, maxPixelSize: width * 2)
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottom) {
                        if let program, program.isOnAir(at: context.date) {
                            LiveProgressBar(value: program.progress(at: context.date), height: 5)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 16)
                                .shadow(color: .black.opacity(0.4), radius: 4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCurrent { NowWatchingMark() }
                    }
                    .cardLift(isFocused: isFocused)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        ChannelLogo(channel, height: 32)
                        Text(verbatim: channel.label)
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.Colors.label)
                            .lineLimit(1)
                    }
                    Text(verbatim: program?.fullTitle ?? String(localized: "Nothing on now", bundle: .localized))
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                .padding(.top, 20)
                .offset(y: isFocused ? 12 : 0)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Marks the channel on screen in the mini-guide.
private struct NowWatchingMark: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Theme.Colors.label)
            .frame(width: 48, height: 48)
            .glassSurface(in: Circle(), highlighted: false, interactive: false)
            .padding(16)
            .accessibilityLabel(Text("Now Watching"))
    }
}

/// The programme's backdrop, dimmed, with a spinner while the stream is being prepared.
private struct LiveConnectingView: View {
    let model: LivePlayerModel
    let isStarting: Bool

    var body: some View {
        ZStack {
            if let backdrop = model.onAir(at: Date()).now?.backdrop, !backdrop.isEmpty {
                RemoteImage(path: backdrop, maxPixelSize: ArtworkPixels.screenWidth, minPixelSize: ArtworkPixels.screenWidth)
                    .opacity(0.35)
                    .ignoresSafeArea()
            }
            VStack(spacing: 28) {
                ProgressView()
                    .padding(36)
                    .glassSurface(in: Circle(), highlighted: false, interactive: false)
                if isStarting {
                    Text("Starting the channel…")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.label2)
                }
            }
            .padding(.bottom, 200)
        }
    }
}

/// Why the channel cannot be shown, with Try Again and Close. Up and Down still zap.
private struct LiveErrorView: View {
    let model: LivePlayerModel
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Text(verbatim: model.channel.label)
                .font(Theme.Typography.headline)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.label2)
            if model.channel.external {
                // an external channel: what happened is the title, what to do under it
                Text(verbatim: message)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.label)
                Text("The channel’s source isn’t answering. Switch channels or try again later.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            } else {
                Text("The channel can’t be shown")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.label)
            }
            if !model.channel.external, message != String(localized: "The channel can’t be shown", bundle: .localized) {
                Text(verbatim: message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
            GlassGroup(spacing: 28) {
                HStack(spacing: 28) {
                    Button {
                        model.retry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    Button(action: close) {
                        Text("Close")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }
            }
            .padding(.top, 10)
            .focusSection()
        }
        .padding(Theme.Layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onMoveCommand { direction in
            switch direction {
            case .up: model.zap(1)
            case .down: model.zap(-1)
            default: break
            }
        }
        .onExitCommand(perform: close)
    }
}

// MARK: - Picture and remote

/// The picture (two `AVPlayerLayer`s, the one on screen above the one a zap loads into; no
/// transport bar: live has nothing to scrub) and the remote: Up / Down (clicks) and the
/// channel buttons zap, a swipe up zaps up, a swipe down opens the mini-guide, Left /
/// Right show the banner, Select opens the options row, Play/Pause pauses, Menu leaves.
/// While the mini-guide or the options row is up the picture gives up focus and presses.
private struct LivePlayerSurface: UIViewControllerRepresentable {
    let model: LivePlayerModel
    let exit: () -> Void

    func makeUIViewController(context: Context) -> LivePlayerController {
        let controller = LivePlayerController(layers: model.layers)
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: LivePlayerController, context: Context) {
        update(controller)
    }

    private func update(_ controller: LivePlayerController) {
        let model = model
        controller.onZap = { model.zap($0) }
        controller.onGuide = { model.showGuide() }
        controller.onSelect = { model.showControls() }
        controller.onInfo = { model.showInfo() }
        controller.onPlayPause = { model.togglePause() }
        controller.onExit = exit
        controller.show(layer: model.front)
        controller.takesRemote = !model.showsGuide && !model.showsControls
        controller.view.accessibilityLabel = model.channel.label
    }
}

final class LivePlayerController: UIViewController {
    var onZap: (Int) -> Void = { _ in }
    var onGuide: () -> Void = {}
    var onSelect: () -> Void = {}
    var onInfo: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onExit: () -> Void = {}

    /// False while the mini-guide or the options row has focus: the picture is not
    /// focusable then, so moving focus up from them cannot land on it.
    var takesRemote = true {
        didSet {
            guard takesRemote != oldValue else { return }
            pictureView.isFocusable = takesRemote
            if takesRemote {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        }
    }

    private let layers: [AVPlayerLayer]
    private var pictureView: PictureView { view as! PictureView }

    init(layers: [AVPlayerLayer]) {
        self.layers = layers
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let view = PictureView(layers: layers)
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Next Channel", bundle: .localized)) { [weak self] _ in
                self?.onZap(1)
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Previous Channel", bundle: .localized)) { [weak self] _ in
                self?.onZap(-1)
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Channels", bundle: .localized)) { [weak self] _ in
                self?.onGuide()
                return true
            },
        ]
        self.view = view
    }

    /// Puts the layer at `index` on top; the other one sits underneath.
    func show(layer index: Int) {
        for (i, layer) in layers.enumerated() {
            layer.zPosition = i == index ? 1 : 0
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Swipes on the Siri Remote's touch surface; clicks arrive as presses.
        for (direction, action) in [(UISwipeGestureRecognizer.Direction.up, #selector(swipedUp)), (.down, #selector(swipedDown))] {
            let swipe = UISwipeGestureRecognizer(target: self, action: action)
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [view]
    }

    @objc private func swipedUp() {
        if takesRemote { onZap(1) }
    }

    @objc private func swipedDown() {
        if takesRemote { onGuide() }
    }

    private static let handledPresses: Set<UIPress.PressType> = [
        .upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .select, .playPause, .menu,
    ]

    private func handled(_ presses: Set<UIPress>) -> Set<UIPress> {
        takesRemote ? presses.filter { Self.handledPresses.contains($0.type) } : []
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let mine = handled(presses)
        for press in mine {
            switch press.type {
            case .upArrow, .pageUp: onZap(1)
            case .downArrow, .pageDown: onZap(-1)
            case .leftArrow, .rightArrow: onInfo()
            case .select: onSelect()
            case .playPause: onPlayPause()
            case .menu: onExit()
            default: break
            }
        }
        let others = presses.subtracting(mine)
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    // The handled presses end here too, so nothing up the chain acts on them.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.subtracting(handled(presses))
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.subtracting(handled(presses))
        if !others.isEmpty { super.pressesChanged(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.subtracting(handled(presses))
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }
}

/// A focusable view holding the player layers, each filling it.
private final class PictureView: UIView {
    private let layers: [AVPlayerLayer]
    var isFocusable = true

    init(layers: [AVPlayerLayer]) {
        self.layers = layers
        super.init(frame: .zero)
        layers.forEach(layer.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for playerLayer in layers {
            playerLayer.frame = bounds
        }
        CATransaction.commit()
    }

    override var canBecomeFocused: Bool { isFocusable }
}

import AVFoundation
import AntresolKit
import Combine
import SwiftUI
import UIKit

/// The full-screen live player presented by the shell for
/// `PlaybackCoordinator.presentedChannel`. The picture fills the screen; the channel banner
/// (the number, the name, Live, what is on with its progress, what is next) slides in on
/// every change and fades after 5 s. The remote is TiviMate's: Up / Down (clicks and swipes)
/// and the channel buttons zap through the list the player was opened from; Select or Left
/// opens the channel list over the left of the picture at the channel on screen (Left again:
/// the category column, Right: back); Right or a long Select brings up the banner's options
/// (star, audio, subtitles, quality, previous channel, number, channels); Menu closes a list,
/// then the banner, then leaves. The channel keeps playing under every list. Digits
/// (a remote or keyboard that sends them, or the options row's number pad) tune to a
/// channel by its number. A zap holds the old picture, dimmed, until the new channel's
/// first frame.
struct LivePlayerView: View {
    let request: PlaybackCoordinator.LiveRequest

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: LivePlayerModel
    @State private var numberInput = ChannelNumberInput()

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
                LivePlayerSurface(model: model, onDigit: { [numberInput, model] digit in
                    numberInput.type(digit, channels: model.channels)
                }) { dismiss() }
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
                    LiveChannelPanel(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            if model.showsNumberPad {
                NumberPad(input: numberInput, channels: model.channels) { model.closeNumberPad() }
                    .transition(.opacity)
            } else {
                ChannelNumberOverlay(input: numberInput)
            }
        }
        // Digits while the options row, a list or the mini-guide has focus (the picture
        // takes them itself otherwise).
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let digit = ChannelNumberEntry.digit(in: press.characters) else { return .ignored }
            numberInput.type(digit, channels: model.channels)
            return .handled
        }
        .animation(Theme.Motion.easeOut, value: model.showsNumberPad)
        .animation(Theme.Motion.slowEaseOut, value: model.showsInfo)
        .animation(Theme.Motion.slowEaseOut, value: model.showsGuide)
        .animation(Theme.Motion.easeOut, value: model.showsCategories)
        .animation(Theme.Motion.easeOut, value: model.showsControls)
        .animation(Theme.Motion.easeOut, value: model.openMenu)
        .animation(Theme.Motion.easeOut, value: model.isHoldingFrame)
        .animation(Theme.Motion.easeOut, value: model.state)
        .task {
            numberInput.tune = { [model] number in model.tune(number: number) }
            model.start(appState: appState, coordinator: coordinator)
        }
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
                        if let note = model.audioNote {
                            Label(note, systemImage: "speaker.slash.fill")
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.label)
                                .lineLimit(1)
                                .accessibilityIdentifier("live.audioNote")
                        }
                        if let path = model.playbackPath {
                            Text(verbatim: PlaybackPathText.line(path))
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.label3)
                                .lineLimit(1)
                                .accessibilityIdentifier("live.path")
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

/// The banner's quiet line: how the stream arrives («Напрямую · host» / «Через Antresol»),
/// its format and codecs, and «Источник n из m» when the channel has fallbacks.
enum PlaybackPathText {
    static func line(_ path: LivePlaybackPath) -> String {
        var parts: [String] = []
        switch path.route {
        case .direct(let host):
            parts.append(host.isEmpty ? String(localized: "Direct", bundle: .localized) : String(localized: "Direct · \(host)", bundle: .localized))
        case .antresol:
            parts.append(String(localized: "Via Antresol", bundle: .localized))
        }
        parts += path.technical
        if path.showsAttempt, let attempt = path.attempt, let count = path.count {
            parts.append(String(localized: "Source \(attempt) of \(count)", bundle: .localized))
        }
        return parts.joined(separator: " · ")
    }
}

/// The options row: audio, subtitles, the star, the previous channel and the channel list,
/// as round glass buttons (the system player's transport-bar idiom).
private struct LiveControls: View {
    let model: LivePlayerModel

    @FocusState private var focused: Control?

    enum Control: Hashable {
        case goLive, audio, subtitles, quality, favorite, previous, number, channels
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
                // the film player's «Качество» (its symbol and choices)
                if !model.qualityEntries.isEmpty {
                    control(.quality, "Quality", "slider.horizontal.3", isActive: model.openMenu == .quality) {
                        model.openMenu = model.openMenu == .quality ? nil : .quality
                    }
                }
                control(.favorite, model.isFavorite ? "Remove from Favourites" : "Add to Favourites", model.isFavorite ? "star.fill" : "star", isActive: false) {
                    model.toggleFavorite()
                }
                if model.previousChannel != nil {
                    control(.previous, "Previous Channel", "arrow.uturn.backward", isActive: false) {
                        model.tunePrevious()
                    }
                }
                control(.number, "Channel Number", "number", isActive: false) {
                    model.openNumberPad()
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
            switch old {
            case .audio: focused = .audio
            case .subtitles: focused = .subtitles
            case .quality: focused = .quality
            }
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
        if kind == .quality { qualityList } else { trackList }
    }

    /// «Качество»: the same list, one row per choice.
    private var qualityList: some View {
        let entries = model.qualityEntries
        let selected = entries.first(where: \.isOn)?.id ?? ""
        return list(title: "Quality", count: entries.count, selected: selected) {
            ForEach(entries) { entry in
                row(id: entry.id, title: entry.title, isOn: entry.isOn) {
                    model.selectQuality(entry.pick)
                }
                .id(entry.id)
            }
        }
    }

    private var trackList: some View {
        let all = kind == .audio ? model.audioEntries() : model.subtitleEntries()
        // a cleaned voice is not a row: «Clean voice-over» under the voices (the film player's switch)
        let current = kind == .audio ? all.first { $0.name == model.audioTrack?.name } : nil
        let cleanedOn = current?.cleanedOf != nil
        let entries = all.filter { $0.cleanedOf == nil }
        let selected = kind == .audio ? (current?.cleanedOf ?? model.audioTrack?.name ?? "") : (model.subtitleTrack?.name ?? "")
        let twin = { (name: String) in all.first { $0.cleanedOf == name } }
        let cleanedTwin = kind == .audio ? twin(selected) : nil
        let count = entries.count + (kind == .subtitles ? 1 : 0)
        return list(title: kind == .audio ? "Audio" : "Subtitles", count: count, selected: selected) {
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
    }

    /// The list's frame: its title (and count past what fits), the scrolling rows.
    private func list<Rows: View>(title: LocalizedStringKey, count: Int, selected: String, @ViewBuilder rows: () -> Rows) -> some View {
        let content = rows()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
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
                        content
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

/// What the remote does here: Up / Down switch channels, Select (or Left) lists them, Right
/// opens the options.
private struct RemoteHints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Switch Channel", systemImage: "chevron.up.chevron.down")
            Label("Channels", systemImage: "circle.circle")
            Label("Options", systemImage: "chevron.right")
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

/// The channel list over the left of the picture (TiviMate): the channels of the list the
/// player was opened from — number, logo, name, what is on and its progress — focus on the
/// channel on screen, which keeps playing. Select switches; Left opens the category column
/// beside it (Select there picks the list, Right comes back); Right or Menu closes the list.
private struct LiveChannelPanel: View {
    let model: LivePlayerModel

    @FocusState private var focusedChannel: Int?
    @FocusState private var focusedCategory: ChannelFilter?
    /// Fixed when the list opens, so a refresh or a zap does not move it under the focus.
    @State private var order: [Int]?

    static let channelWidth: CGFloat = 700
    static let categoryWidth: CGFloat = 420

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if model.showsCategories {
                categoryColumn
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            channelColumn
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Layout.margin - 20)
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            LinearGradient(stops: [.init(color: .black.opacity(0.92), location: 0), .init(color: .black.opacity(0.8), location: 0.75), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: (model.showsCategories ? Self.categoryWidth + 12 : 0) + Self.channelWidth + Theme.Layout.margin + 220)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onExitCommand { model.hideGuide() }
        .onChange(of: model.showsCategories) { _, shows in
            if shows {
                focusedCategory = model.filter
            } else {
                focusedChannel = model.channel.id
            }
        }
    }

    private var title: String {
        model.filter == .all ? String(localized: "Channels", bundle: .localized) : model.filter.title(in: model.categories)
    }

    private var channelColumn: some View {
        let channels = fresh(order ?? model.zapList.map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
                .lineLimit(1)
                .padding(.horizontal, Theme.Layout.listRowInset)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(channels) { channel in
                            Button {
                                model.tune(to: channel)
                            } label: {
                                PanelChannelRow(channel: channel, isCurrent: channel.id == model.channel.id)
                            }
                            .buttonStyle(ListRowButtonStyle())
                            .focused($focusedChannel, equals: channel.id)
                            .id(channel.id)
                            .accessibilityIdentifier("live.list.\(channel.number)")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
                .task(id: model.listOpenings) {
                    order = model.zapList.map(\.id)
                    proxy.scrollTo(model.channel.id, anchor: .center)
                    // the row exists once scrolled to (a lazy stack)
                    try? await Task.sleep(for: .milliseconds(50))
                    if !model.showsCategories { focusedChannel = model.channel.id }
                }
            }
        }
        .frame(width: Self.channelWidth)
        .focusSection()
        .defaultFocus($focusedChannel, model.channel.id)
        .onMoveCommand { direction in
            switch direction {
            case .left: model.showCategories()
            case .right: model.hideGuide()
            default: break
            }
        }
    }

    private var categoryColumn: some View {
        let options = model.filterOptions
        return VStack(alignment: .leading, spacing: 12) {
            Text("Categories")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
                .padding(.horizontal, Theme.Layout.listRowInset)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(options) { option in
                            Button {
                                model.selectCategory(option.filter)
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 20, weight: .bold))
                                        .opacity(option.filter == model.filter ? 1 : 0)
                                        .frame(width: 24)
                                    Text(verbatim: option.title(in: model.categories))
                                        .font(Theme.Typography.headline)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(verbatim: "\(option.count)")
                                        .font(Theme.Typography.meta)
                                        .monospacedDigit()
                                        .opacity(0.6)
                                }
                            }
                            .buttonStyle(ListRowButtonStyle())
                            .focused($focusedCategory, equals: option.filter)
                            .id(option.filter)
                            .accessibilityAddTraits(option.filter == model.filter ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
                .onAppear { proxy.scrollTo(model.filter, anchor: .center) }
            }
        }
        .frame(width: Self.categoryWidth)
        .focusSection()
        .defaultFocus($focusedCategory, model.filter)
        .onMoveCommand { direction in
            if direction == .right { model.hideCategories() }
        }
    }

    /// The list's channels as the latest list has them (what is on moves on).
    private func fresh(_ ids: [Int]) -> [Channel] {
        let latest = Dictionary(model.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in latest[id] ?? (model.channel.id == id ? model.channel : nil) }
    }
}

/// A row of the player's channel list: number, logo, name (a play mark on the channel on
/// screen), what is on and its progress.
private struct PanelChannelRow: View {
    let channel: Channel
    let isCurrent: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let program = channel.program(at: context.date)
            HStack(spacing: 18) {
                Text(verbatim: String(channel.number))
                    .font(Theme.Typography.headline)
                    .monospacedDigit()
                    .opacity(0.7)
                    .frame(minWidth: 64, alignment: .trailing)
                ChannelLogo(channel, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        if isCurrent {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                                .accessibilityLabel(Text("Now Watching"))
                        }
                        Text(verbatim: channel.name)
                            .font(Theme.Typography.headline)
                            .lineLimit(1)
                        if channel.favorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .opacity(0.7)
                        }
                    }
                    Text(verbatim: program?.fullTitle ?? String(localized: "Nothing on now", bundle: .localized))
                        .font(Theme.Typography.meta)
                        .opacity(0.7)
                        .lineLimit(1)
                    if let program, program.isOnAir(at: context.date) {
                        LiveProgressBar(value: program.progress(at: context.date), height: 4)
                            .frame(width: 260)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
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
/// transport bar: live has nothing to scrub) and the remote, TiviMate's: Up / Down (clicks
/// and swipes) and the channel buttons zap; Select (a short press) or Left (click or swipe)
/// opens the channel list; Right (click or swipe) or a long Select opens the banner's options;
/// Play/Pause pauses; Menu hides the banner, then leaves. While a list or the options row is
/// up the picture gives up focus and presses.
private struct LivePlayerSurface: UIViewControllerRepresentable {
    let model: LivePlayerModel
    let onDigit: (Character) -> Void
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
        controller.onOptions = { model.showControls() }
        controller.onPrevious = { model.tunePrevious() }
        controller.onPlayPause = { model.togglePause() }
        controller.onDigit = onDigit
        controller.onBack = { model.handleBack() }
        controller.onExit = exit
        controller.show(layer: model.front)
        controller.takesRemote = !model.showsGuide && !model.showsControls && !model.showsNumberPad
        controller.view.accessibilityLabel = model.channel.label
    }
}

final class LivePlayerController: UIViewController {
    var onZap: (Int) -> Void = { _ in }
    /// The channel list (Select, Left).
    var onGuide: () -> Void = {}
    /// The banner with its options (Right, a long Select).
    var onOptions: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onPlayPause: () -> Void = {}
    /// A digit key of a remote or keyboard that has them (`UIKey`).
    var onDigit: (Character) -> Void = { _ in }
    /// Menu: true when it hid something (the banner) instead of leaving.
    var onBack: () -> Bool = { false }
    var onExit: () -> Void = {}

    /// The presses this controller took at their start: their end is its own too, whatever
    /// opened meanwhile (a list, the options row).
    private var ownPresses: Set<ObjectIdentifier> = []
    /// Select went down here and has not been taken by the long press: its release opens the list.
    private var selectPending = false
    /// How long Select is held for the options.
    static let longPressDuration: TimeInterval = 0.6

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
            UIAccessibilityCustomAction(name: String(localized: "Channel Up", bundle: .localized)) { [weak self] _ in
                self?.onZap(1)
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Channel Down", bundle: .localized)) { [weak self] _ in
                self?.onZap(-1)
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Channels", bundle: .localized)) { [weak self] _ in
                self?.onGuide()
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Options", bundle: .localized)) { [weak self] _ in
                self?.onOptions()
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Previous Channel", bundle: .localized)) { [weak self] _ in
                self?.onPrevious()
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
        let swipes: [(UISwipeGestureRecognizer.Direction, Selector)] = [
            (.up, #selector(swipedUp)), (.down, #selector(swipedDown)), (.left, #selector(swipedLeft)), (.right, #selector(swipedRight)),
        ]
        for (direction, action) in swipes {
            let swipe = UISwipeGestureRecognizer(target: self, action: action)
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        // Holding Select: the options (a short press opens the channel list on release).
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldSelect(_:)))
        hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        hold.minimumPressDuration = Self.longPressDuration
        // the presses still reach `pressesBegan` / `pressesEnded` (the short press is decided there)
        hold.cancelsTouchesInView = false
        view.addGestureRecognizer(hold)
    }

    @objc private func heldSelect(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, selectPending else { return }
        selectPending = false
        onOptions()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [view]
    }

    @objc private func swipedUp() {
        if takesRemote { onZap(1) }
    }

    @objc private func swipedDown() {
        if takesRemote { onZap(-1) }
    }

    @objc private func swipedLeft() {
        if takesRemote { onGuide() }
    }

    @objc private func swipedRight() {
        if takesRemote { onOptions() }
    }

    private static let handledPresses: Set<UIPress.PressType> = [
        .upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .select, .playPause, .menu,
    ]

    private func handled(_ presses: Set<UIPress>) -> Set<UIPress> {
        takesRemote ? presses.filter { Self.handledPresses.contains($0.type) || Self.digit(of: $0) != nil } : []
    }

    /// The presses whose start this controller took.
    private func owned(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { ownPresses.contains(ObjectIdentifier($0)) }
    }

    private static func digit(of press: UIPress) -> Character? {
        press.key.flatMap { ChannelNumberEntry.digit(in: $0.charactersIgnoringModifiers) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let mine = handled(presses)
        for press in mine {
            ownPresses.insert(ObjectIdentifier(press))
            if let digit = Self.digit(of: press) {
                onDigit(digit)
                continue
            }
            switch press.type {
            case .upArrow, .pageUp: onZap(1)
            case .downArrow, .pageDown: onZap(-1)
            case .leftArrow: onGuide()
            case .rightArrow: onOptions()
            // decided on release: a long press is the options (`heldSelect`)
            case .select: selectPending = true
            case .playPause: onPlayPause()
            case .menu: if !onBack() { onExit() }
            default: break
            }
        }
        let others = presses.subtracting(mine)
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    // The presses taken at their start end here too, so nothing up the chain acts on them.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let mine = owned(presses)
        for press in mine {
            ownPresses.remove(ObjectIdentifier(press))
            if press.type == .select, selectPending {
                selectPending = false
                onGuide()
            }
        }
        let others = presses.subtracting(mine)
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.subtracting(owned(presses))
        if !others.isEmpty { super.pressesChanged(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let mine = owned(presses)
        for press in mine {
            ownPresses.remove(ObjectIdentifier(press))
            if press.type == .select { selectPending = false }
        }
        let others = presses.subtracting(mine)
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

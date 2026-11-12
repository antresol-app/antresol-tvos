import AntresolKit
import SwiftUI

/// The TV tab: the server's live channels («ТВ») as a television has them. One numbered
/// list (Channels) or the programme guide (Guide), switched at the top; filters All,
/// Favourites and the themes narrow either view without reordering it. Focus starts on
/// the channel the profile watched last, and a small pill returns to it. Long-press a row
/// (or open a programme in the guide) to star a channel.
struct TVView: View {
    /// How often the list (what is on now and next) is fetched again.
    static let refreshInterval: Duration = .seconds(30)

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var model = TVModel()
    @State private var details: ProgramDetails?
    /// The focused channel row: the page's focus starts on the last channel.
    @FocusState private var focusedRow: Int?
    /// The first load put focus on the last channel (once per visit of the page).
    @State private var placedFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVHeader(model: model, watchLast: watchLast)
                .padding(.horizontal, Theme.Layout.margin)
                .padding(.bottom, 28)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .horizontal)
        // Coming into the page (from the sidebar or back from the player), focus goes to
        // the last channel, not to the header's first control.
        .defaultFocus($focusedRow, initialRow, priority: .userInitiated)
        .navigationDestination(item: $details) { details in
            ProgramDetailView(details: details, model: model)
        }
        // Again in a new interface language: channel and theme names come from the server.
        .task(id: appState.language) {
            model.attach(appState)
            // «ТВ» opened: the server refreshes external sources marked «при открытии»
            if let client = appState.client { Task { await ChannelService(client: client).opened() } }
            if model.grid.loadedFrom != nil { await model.reloadGuide() }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .onChange(of: model.phase) { _, phase in
            // The list arrives after the page took focus (on the header): move it to the
            // last channel once, as a TV does.
            guard phase == .loaded, !placedFocus, model.mode == .channels, let initialRow else { return }
            placedFocus = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                focusedRow = initialRow
            }
        }
        .onChange(of: playback.liveSessions) {
            // The player may have changed favourites and the last channel.
            Task { await model.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await model.refresh() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.list.channels.isEmpty {
                EmptyStateView(
                    systemImage: "tv",
                    title: "No channels yet",
                    message: "Channels appear by themselves once the library has at least six movies of a genre or a series with eight episodes."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.mode {
                case .channels:
                    ChannelListView(model: model, focused: $focusedRow, initial: initialRow, watch: watch)
                case .guide:
                    GuideView(model: model, open: { details = $0 }, watch: watch)
                }
            }
        }
    }

    /// The last channel when the list shows it, else the first channel.
    private var initialRow: Int? {
        let channels = model.channels
        return channels.first { $0.id == model.list.lastChannel }?.id ?? channels.first?.id
    }

    private func watch(_ channel: Channel) {
        playback.watch(channel, channels: model.list.channels, filter: model.activeFilter)
    }

    private func watchLast() {
        guard let last = model.list.last else { return }
        playback.watch(last, channels: model.list.channels, filter: model.activeFilter)
    }
}

/// What the guide opens: a programme of a channel.
struct ProgramDetails: Hashable {
    let channelId: Int
    let program: ChannelProgram
}

// MARK: - Header

/// The page title with the view switch («Каналы | Телегид») and the return to the last
/// channel, then the filters («Все · Избранное · <themes>»).
private struct TVHeader: View {
    let model: TVModel
    let watchLast: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 32) {
                Text("TV")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 24)
                // (no «Back to …» pill: the list opens on the last channel, tinted)
                SegmentedPill(
                    options: [
                        .init(value: TVModel.Mode.channels, title: String(localized: "Channels", bundle: .localized)),
                        .init(value: TVModel.Mode.guide, title: String(localized: "Guide", bundle: .localized)),
                    ],
                    selection: Binding(get: { model.mode }, set: { model.mode = $0 })
                )
            }
            .focusSection()
            ScrollView(.horizontal, showsIndicators: false) {
                SegmentedPill(
                    options: model.filters.map { .init(value: $0, title: $0.title) },
                    selection: Binding(get: { model.activeFilter }, set: { model.filter = $0 })
                )
                .padding(.vertical, 12)
                .padding(.trailing, Theme.Layout.margin)
            }
            .scrollClipDisabled()
            .padding(.vertical, -12)
            // Themes that run past the screen's edge fade out instead of being cut.
            .mask(alignment: .leading) {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                    .padding(.vertical, -40)
                    .padding(.leading, -Theme.Layout.margin)
                    .padding(.trailing, -Theme.Layout.margin)
            }
        }
        .padding(.top, 24)
    }
}

/// A small glass pill (icon and a short label) for a secondary action in a header.
struct QuietPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietPillBody(configuration: configuration)
    }
}

private struct QuietPillBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(Theme.Typography.segment)
            .lineLimit(1)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label2)
            .padding(.horizontal, 30)
            .frame(minHeight: 72)
            .glassSurface(in: Capsule(), highlighted: isFocused)
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? Theme.Motion.focusScale : 1))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 16, y: 8)
            .animation(Theme.Motion.easeOut, value: isFocused)
    }
}

// MARK: - Channel list

/// The one numbered list: a row per channel with what is on now and next. Select tunes
/// in; long-press offers the star.
private struct ChannelListView: View {
    let model: TVModel
    var focused: FocusState<Int?>.Binding
    let initial: Int?
    let watch: (Channel) -> Void

    var body: some View {
        let channels = model.channels
        if channels.isEmpty {
            EmptyStateView(
                systemImage: model.activeFilter == .favorites ? "star" : "tv",
                title: model.activeFilter == .favorites ? "No favourite channels" : "No channels here",
                message: model.activeFilter == .favorites
                    ? "Press and hold a channel, or use the star in the player, to add it to Favourites."
                    : "Choose another filter."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 56) {
                list(channels)
                    .frame(width: Self.listWidth)
                // What the focused row is showing, at full size (the list keeps to a line).
                if let shown = channels.first(where: { $0.id == focused.wrappedValue }) ?? channels.first(where: { $0.id == initial }) {
                    ChannelPreview(channel: shown)
                        .padding(.trailing, Theme.Layout.margin)
                        .padding(.top, 20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    /// The rows' column: the margin, then the rows.
    static let listWidth: CGFloat = 1040

    private func list(_ channels: [Channel]) -> some View {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(channels) { channel in
                            Button {
                                watch(channel)
                            } label: {
                                ChannelRow(channel: channel)
                            }
                            .buttonStyle(ChannelRowButtonStyle())
                            .focused(focused, equals: channel.id)
                            .id(channel.id)
                            .contextMenu {
                                Button {
                                    watch(channel)
                                } label: {
                                    Label("Watch", systemImage: "play.fill")
                                }
                                Button {
                                    Task { await model.toggleFavorite(channel.id) }
                                } label: {
                                    if channel.favorite {
                                        Label("Remove from Favourites", systemImage: "star.slash")
                                    } else {
                                        Label("Add to Favourites", systemImage: "star")
                                    }
                                }
                            }
                            .onPlayPauseCommand { watch(channel) }
                        }
                    }
                    .padding(.leading, Theme.Layout.margin)
                    // Room for the focused row's plate and lift.
                    .padding(.trailing, 44)
                    .padding(.vertical, 20)
                }
                // Rows scroll under the header's edge (softly), not over the filters.
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                        .padding(.horizontal, -Theme.Layout.margin)
                        .padding(.bottom, -120)
                }
                .focusSection()
                .onAppear {
                    if let initial { proxy.scrollTo(initial, anchor: .center) }
                }
            }
    }
}

/// A channel row, as a television's channel list: the number in tabular digits, the
/// programme's still, the channel's name and what is on in one line, and a thin
/// progress bar. Times and what is next are in the preview beside the list, the
/// programme page and the player's banner. Focus lifts the row on a light plate.
struct ChannelRow: View {
    let channel: Channel

    @Environment(\.isCardFocused) private var isFocused

    static let stillWidth: CGFloat = 176

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let program = channel.program(at: context.date)
            HStack(alignment: .center, spacing: 28) {
                Text(verbatim: String(channel.number))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    // external channels start at 100: room for three digits, a fourth fits by shrinking
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 84, alignment: .trailing)
                ProgrammeStill(program: program, maxPixelSize: Self.stillWidth * 2, cornerRadius: Theme.Radius.smallCard)
                    .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        ChannelLogo(path: channel.logoUrl, height: 34)
                            .padding(.trailing, 4)
                        Text(verbatim: channel.name)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(primary)
                            .lineLimit(1)
                        if channel.favorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(secondary)
                                .accessibilityLabel(Text("Favourite"))
                        }
                    }
                    Text(verbatim: program?.fullTitle ?? String(localized: "Nothing on now", bundle: .localized))
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    LiveProgressBar(value: program.map { $0.isOnAir(at: context.date) ? $0.progress(at: context.date) : 0 } ?? 0, onLight: isFocused, height: 4)
                        .opacity(program?.isOnAir(at: context.date) == true ? 1 : 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 14)
        }
        .accessibilityElement(children: .combine)
    }

    private var primary: Color {
        isFocused ? Theme.Colors.labelInverse : Theme.Colors.label
    }

    private var secondary: Color {
        isFocused ? Theme.Colors.labelInverse.opacity(0.55) : Theme.Colors.label3
    }
}

/// The focused channel beside the list: the programme's still, the channel, what is on
/// with its time and progress, what is next, and the overview.
private struct ChannelPreview: View {
    let channel: Channel

    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let program = channel.program(at: context.date)
            VStack(alignment: .leading, spacing: 18) {
                ProgrammeStill(program: program, maxPixelSize: 1400)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 16) {
                    ChannelLogo(path: channel.logoUrl, height: 40)
                    Text(verbatim: channel.label)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                    if program?.isOnAir(at: context.date) == true { LiveBadge() }
                }
                .padding(.top, 8)
                if let program {
                    Text(verbatim: program.fullTitle)
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(2)
                    HStack(spacing: 18) {
                        Text(verbatim: program.timeRange(locale))
                            .monospacedDigit()
                        if program.isOnAir(at: context.date) {
                            LiveProgressBar(value: program.progress(at: context.date))
                                .frame(width: 200)
                            Text(verbatim: program.untilLine(locale))
                                .monospacedDigit()
                        }
                    }
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
                    if let next = channel.upNext(at: context.date) {
                        Text(verbatim: next.nextLine(locale))
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label3)
                            .lineLimit(1)
                    }
                    if !program.overview.isEmpty {
                        Text(verbatim: program.overview)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label2)
                            .lineLimit(3)
                            .padding(.top, 4)
                    }
                } else {
                    Text("Nothing on now")
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.label)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin live progress bar that reads on the dark page and on a focused light plate.
struct LiveProgressBar: View {
    let value: Double
    var onLight = false
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(onLight ? Color.black.opacity(0.15) : Color.white.opacity(0.22))
                Capsule()
                    .fill(onLight ? Color.black.opacity(0.75) : Color.white)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((min(max(value, 0), 1) * 100).rounded()))%"))
    }
}

/// The list row's focus: a light glass plate behind the whole row, a gentle lift.
struct ChannelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChannelRowBody(configuration: configuration)
    }
}

private struct ChannelRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .environment(\.isCardFocused, isFocused)
            .padding(.horizontal, Theme.Layout.listRowInset)
            .background {
                if isFocused {
                    Color.clear.glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous), highlighted: true)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.015 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 24, y: 12)
            .animation(Theme.Motion.easeOut, value: isFocused)
            .padding(.horizontal, -Theme.Layout.listRowInset)
    }
}

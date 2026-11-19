import AntresolKit
import SwiftUI
import UIKit

/// The TV tab: the server's live channels («ТВ») as a television has them. One numbered
/// list (Channels) or the programme guide (Guide), switched at the top; the category
/// button narrows either view without reordering it (Favourites, All, then the server's
/// categories: AI topics, sources, playlist groups). Focus starts on
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
    /// The row that is to take focus as soon as it exists: the last channel may be far
    /// down the lazy list, where there is no row to focus until the list scrolled to it.
    @State private var focusRequest: Int?
    /// Where focus was when that row was asked for (`FocusPlace`).
    @State private var focusPlaceAtRequest: CGRect?
    /// The category list is up.
    @State private var showsCategories = false
    /// A category was chosen in the list now closing: focus goes to the channels.
    @State private var choseCategory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVHeader(model: model, watchLast: watchLast, openCategories: { showsCategories = true })
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
        // A cover, not an overlay: it keeps focus inside while it is up (the sidebar and the
        // list behind cannot take it) and Menu closes it, back on the button.
        .fullScreenCover(isPresented: $showsCategories, onDismiss: focusChosenCategory) {
            CategoriesPanel(model: model) { filter in
                model.filter = filter
                choseCategory = true
                showsCategories = false
            }
            .presentationBackground(.clear)
        }
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
                // Under a full-screen player nobody sees the list (the live player
                // fetches it itself, and its closing refreshes this one).
                if !playback.isPresenting { await model.refresh() }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .onChange(of: model.phase) { _, phase in
            // The list arrives after the page took focus (on the header): move it to the
            // last channel once, as a TV does.
            guard phase == .loaded, !placedFocus, model.mode == .channels, let initialRow else { return }
            placedFocus = true
            focusPlaceAtRequest = FocusPlace.current()
            focusRequest = initialRow
        }
        .task(id: focusRequest) {
            // The list scrolls to the row and the row takes focus as it appears
            // (`ChannelListView`). Should that not have happened, the assignment is
            // repeated after a pause, as it used to be made, a few times at most.
            guard let target = focusRequest else { return }
            for pause in [150, 350, 700] {
                try? await Task.sleep(for: .milliseconds(pause))
                guard !Task.isCancelled else {
                    // The page went away (another tab, a programme's page): the request
                    // ends with it, or it would take focus when the page comes back.
                    if focusRequest == target { focusRequest = nil }
                    return
                }
                guard focusRequest == target else { return }
                // On the row, or the viewer is on another one, or moved focus elsewhere
                // (the header, the sidebar): it is not pulled back.
                guard FocusFallback.mayAssign(
                    rowHasFocus: focusedRow != nil, placeAtRequest: focusPlaceAtRequest, placeNow: FocusPlace.current()
                ) else { break }
                focusedRow = target
            }
            focusRequest = nil
        }
        .onChange(of: playback.liveSessions) {
            // The player may have changed favourites and the last channel.
            Task { await model.refresh() }
        }
        .onChange(of: appState.channelPrefsRevision) {
            // «Избранные каналы первыми» changed in Settings: the server orders the list.
            Task {
                await model.refresh()
                if model.grid.loadedFrom != nil { await model.reloadGuide() }
            }
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
                    ChannelListView(model: model, focused: $focusedRow, initial: initialRow, focusRequest: focusRequest, watch: watch)
                case .guide:
                    GuideView(model: model, open: { details = $0 }, watch: watch)
                }
            }
        }
    }

    /// After a category was chosen: its channels take focus (the last channel when it is
    /// among them), as on a TV, not the button the list was opened from.
    private func focusChosenCategory() {
        guard choseCategory else { return }
        choseCategory = false
        guard model.mode == .channels else { return }
        Task {
            // The system hands focus back to the button as the cover goes: ask after that,
            // or the request sees focus move and gives way to it.
            try? await Task.sleep(for: .milliseconds(400))
            guard let initialRow else { return }
            focusPlaceAtRequest = FocusPlace.current()
            focusRequest = initialRow
        }
    }

    /// The last channel when the list shows it, else the first channel.
    private var initialRow: Int? {
        let channels = model.channels
        return channels.first { $0.id == model.list.lastChannel }?.id ?? channels.first?.id
    }

    private func watch(_ channel: Channel) {
        playback.watch(channel, channels: model.list.channels, filter: model.activeFilter, categories: model.list.categories ?? [])
    }

    private func watchLast() {
        guard let last = model.list.last else { return }
        playback.watch(last, channels: model.list.channels, filter: model.activeFilter, categories: model.list.categories ?? [])
    }
}

/// Where the focus is on the screen: the focused item's frame in the window, nil when
/// nothing has focus. Tells "focus has not moved" from "the viewer moved it" for places
/// SwiftUI's focus state of this page does not cover (the header, the sidebar).
@MainActor
enum FocusPlace {
    static func current() -> CGRect? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let item = UIFocusSystem.focusSystem(for: window)?.focusedItem
        else { return nil }
        // An item's frame is in its container's coordinates.
        guard let space = item.parentFocusEnvironment?.focusItemContainer?.coordinateSpace else { return item.frame }
        return space.convert(item.frame, to: window.coordinateSpace)
    }
}

/// What the guide opens: a programme of a channel.
struct ProgramDetails: Hashable {
    let channelId: Int
    let program: ChannelProgram
}

// MARK: - Header

/// The page title with the category button and the view switch («Каналы | Телегид»).
/// A playlist can bring dozens of categories: a button that opens the list, not a row of
/// pills.
private struct TVHeader: View {
    let model: TVModel
    let watchLast: () -> Void
    let openCategories: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            Text("TV")
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 24)
            // (no «Back to …» pill: the list opens on the last channel, tinted)
            CategoryButton(
                title: model.activeFilter.title(in: model.list.categories ?? []),
                count: model.channels.count,
                action: openCategories
            )
            SegmentedPill(
                options: [
                    .init(value: TVModel.Mode.channels, title: String(localized: "Channels", bundle: .localized)),
                    .init(value: TVModel.Mode.guide, title: String(localized: "Guide", bundle: .localized)),
                ],
                selection: Binding(get: { model.mode }, set: { model.mode = $0 })
            )
        }
        .focusSection()
        .padding(.top, 24)
    }
}

/// The current category and how many channels it shows, with a chevron: Select opens the
/// category list. Glass at rest, white with black text when focused, like the pills.
private struct CategoryButton: View {
    let title: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 24, weight: .semibold))
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: String(count))
                    .monospacedDigit()
                    .opacity(0.6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .bold))
            }
            .frame(maxWidth: 560)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(CategoryButtonStyle())
        .accessibilityLabel(Text(verbatim: String(localized: "\(title), \(count) channels. Choose a category", bundle: .localized)))
        .accessibilityIdentifier("tv.categories")
    }
}

private struct CategoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CategoryButtonBody(configuration: configuration)
    }
}

private struct CategoryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(Theme.Typography.segment)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label)
            .padding(.horizontal, 30)
            .frame(minHeight: 72)
            .glassSurface(in: Capsule(), highlighted: isFocused)
            .scaleEffect(isFocused ? Theme.Motion.focusScale : (configuration.isPressed ? 0.97 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 16, y: 8)
            .animation(Theme.Motion.easeOut, value: isFocused)
    }
}

// MARK: - Categories

/// The category list on the left, as the web's first level: «Избранное», «Все каналы»,
/// then the categories as the server orders them (its AI topics, the sources, the
/// playlists' groups), each with its channel count; with more than one kind they have headings. The current one is checked
/// and has focus when the list opens. Select chooses; Menu closes it as it was.
private struct CategoriesPanel: View {
    let model: TVModel
    let choose: (ChannelFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: ChannelFilter?

    /// A row, or the heading above the first row of a kind.
    private enum Entry: Identifiable {
        case heading(String)
        case option(ChannelFilterOption)

        var id: String {
            switch self {
            case .heading(let title): return "heading:" + title
            case .option(let option): return option.filter.storageKey
            }
        }
    }

    private var entries: [Entry] {
        let options = model.filterOptions
        let headings = Set(options.compactMap(\.kind)).count > 1
        var shown: String?
        var out: [Entry] = []
        for option in options {
            if headings, let kind = option.kind, kind != shown, let title = ChannelCategory.kindTitle(kind) {
                out.append(.heading(title))
            }
            if option.kind != nil { shown = option.kind }
            out.append(.option(option))
        }
        return out
    }

    var body: some View {
        let current = model.activeFilter
        let categories = model.list.categories ?? []
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Categories")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .padding(.horizontal, Theme.Layout.listRowInset)
                    .accessibilityAddTraits(.isHeader)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .heading(let title):
                                    Text(verbatim: title)
                                        .font(Theme.Typography.eyebrow)
                                        .foregroundStyle(Theme.Colors.label3)
                                        .textCase(.uppercase)
                                        .padding(.horizontal, Theme.Layout.listRowInset)
                                        .padding(.top, 22)
                                        .padding(.bottom, 4)
                                case .option(let option):
                                    row(option, title: title(of: option, categories: categories), isOn: option.filter == current)
                                        .id(option.filter.storageKey)
                                }
                            }
                        }
                        // room for the focused row's lift
                        .padding(.vertical, 12)
                    }
                    .onAppear { proxy.scrollTo(current.storageKey, anchor: .center) }
                }
            }
            .padding(.vertical, 60)
            .padding(.horizontal, 32)
            .frame(width: 720)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.black.opacity(0.35))
            .glassSurface(in: Rectangle(), highlighted: false, interactive: false)
            .focusSection()
            .defaultFocus($focused, current)
            Spacer(minLength: 0)
        }
        .background {
            // The page stays visible behind, dimmed.
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onAppear { focused = current }
        .onExitCommand { dismiss() }
    }

    private func title(of option: ChannelFilterOption, categories: [ChannelCategory]) -> String {
        if case .category = option.filter, let label = option.label, !label.isEmpty { return label }
        return option.filter.title(in: categories)
    }

    private func row(_ option: ChannelFilterOption, title: String, isOn: Bool) -> some View {
        Button {
            choose(option.filter)
        } label: {
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
                Text(verbatim: String(option.count))
                    .font(Theme.Typography.meta)
                    .monospacedDigit()
                    .opacity(0.6)
            }
        }
        .buttonStyle(ListRowButtonStyle())
        .focused($focused, equals: option.filter)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("tv.category.\(option.filter.storageKey)")
    }
}

// MARK: - Channel list

/// The one list, in the server's order: a row per channel with what is on now and next. Select tunes
/// in; long-press offers the star.
private struct ChannelListView: View {
    let model: TVModel
    var focused: FocusState<Int?>.Binding
    let initial: Int?
    /// The row to put focus on once it exists (see `TVView.focusRequest`).
    let focusRequest: Int?
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
                            .onAppear {
                                // The requested row came into being (the list scrolled to it).
                                if focusRequest == channel.id { focused.wrappedValue = channel.id }
                            }
                        }
                    }
                    .padding(.leading, Theme.Layout.margin)
                    // Room for the focused row's plate and lift.
                    .padding(.trailing, 44)
                    .padding(.vertical, 20)
                }
                // Rows scroll under the header's edge (softly), not over it.
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                        .padding(.horizontal, -Theme.Layout.margin)
                        .padding(.bottom, -120)
                }
                .focusSection()
                .onAppear {
                    if let initial { proxy.scrollTo(initial, anchor: .center) }
                }
                .onChange(of: focusRequest, initial: true) { _, target in
                    // Scroll first: a row far down the lazy stack exists only after it.
                    // A row that is already there takes focus now, the others in `onAppear`.
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .center)
                    focused.wrappedValue = target
                }
            }
    }
}

/// A channel row, as a television's channel list (and the web's): the number in tabular
/// digits, the logo (or the guide's icon, or the initials), the channel's name and what is
/// on in one line with a thin progress bar, and the programme's still only when it has one
/// (no empty grey box). Times and what is next are in the preview beside the list, the
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
                ChannelLogo(channel, height: 56, initials: true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
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
                if let still = program?.still, !still.isEmpty {
                    ProgrammeStill(program: program, maxPixelSize: Self.stillWidth * 2, cornerRadius: Theme.Radius.smallCard)
                        .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
                }
            }
            .frame(minHeight: Self.stillWidth * 9 / 16)
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
                // About 745 points wide beside the list.
                ProgrammeStill(program: program, maxPixelSize: 1500)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 16) {
                    ChannelLogo(channel, height: 40)
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

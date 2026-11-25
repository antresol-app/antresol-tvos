import AntresolKit
import SwiftUI
import UIKit

/// The TV tab: the server's live channels («ТВ») as a television has them (TiviMate is the
/// reference). The header holds the title, the view switch («Channels | Guide»), the category
/// button and the number pad. Channels: the numbered channel list on a panel (the left ~46%,
/// the page's full height), beside a card of what the focused channel has on now: its still
/// across the card, the title, episode, time and progress, overview and what is next. A few
/// channels make tall rows with the programme's still, many make compact rows. Guide: the
/// programme guide. The category button (Favourites, All, the server's categories, the adult
/// one last) opens the list of them and narrows both views. Focus starts on the channel the
/// profile watched last. Select tunes in, a long press offers the star; digits (a remote or
/// keyboard that has them, or the number pad of the header's «123») tune to a channel by its
/// number.
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
    /// The number being typed.
    @State private var numberInput = ChannelNumberInput()
    /// The on-screen number pad is up.
    @State private var showsNumberPad = false
    /// A typed number's player, opened once the pad has gone (a cover cannot present the
    /// player while it is still leaving).
    @State private var tuneAfterPad: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVHeader(model: model, openCategories: { showsCategories = true }, openNumberPad: { showsNumberPad = true })
                .padding(.horizontal, Theme.Layout.margin)
                .padding(.bottom, 28)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .horizontal)
        .overlay { ChannelNumberOverlay(input: numberInput) }
        // Digits of a remote or keyboard that has them: a channel by its number.
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let digit = ChannelNumberEntry.digit(in: press.characters), !model.list.channels.isEmpty else { return .ignored }
            numberInput.type(digit, channels: model.list.channels)
            return .handled
        }
        .fullScreenCover(isPresented: $showsNumberPad, onDismiss: {
            tuneAfterPad?()
            tuneAfterPad = nil
        }) {
            NumberPad(input: numberInput, channels: model.list.channels) { showsNumberPad = false }
                .presentationBackground(.clear)
        }
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
            numberInput.tune = { number in tune(number) }
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
                        .padding(.horizontal, Theme.Layout.margin)
                        .padding(.bottom, 24)
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

    /// A typed number: its channel's player (the pad closes first), zapping on through the
    /// list shown when the channel is in it, else through All. false: no such channel.
    private func tune(_ number: Int) -> Bool {
        guard let channel = model.activeFilter.channel(number: number, in: model.list.channels) else { return false }
        let filter = model.activeFilter.matches(channel) ? model.activeFilter : ChannelFilter.all
        let open = {
            playback.watch(channel, channels: model.list.channels, filter: filter, categories: model.list.categories ?? [])
        }
        if showsNumberPad {
            tuneAfterPad = open
            showsNumberPad = false
        } else {
            open()
        }
        return true
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

/// The page title, the view switch («Каналы | Телегид»), the category button and the number
/// pad, together on the left. A playlist can bring dozens of categories: a button that opens
/// the list, not a row of pills.
private struct TVHeader: View {
    let model: TVModel
    let openCategories: () -> Void
    let openNumberPad: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            Text("TV")
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .accessibilityAddTraits(.isHeader)
                .padding(.trailing, 8)
            // (no «Back to …» pill: the list opens on the last channel, tinted)
            SegmentedPill(
                options: [
                    .init(value: TVModel.Mode.channels, title: String(localized: "Channels", bundle: .localized)),
                    .init(value: TVModel.Mode.guide, title: String(localized: "Guide", bundle: .localized)),
                ],
                selection: Binding(get: { model.mode }, set: { model.mode = $0 })
            )
            CategoryButton(
                title: model.activeFilter.title(in: model.list.categories ?? []),
                count: model.channels.count,
                action: openCategories
            )
            Button(action: openNumberPad) {
                RoundGlyph("Channel Number", systemImage: "number")
            }
            .buttonStyle(CircleButtonStyle(diameter: 72))
            .accessibilityIdentifier("tv.numberpad")
            Spacer(minLength: 0)
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
            .scaleEffect(isFocused ? Theme.Motion.Focus.pill : (configuration.isPressed ? Theme.Motion.Press.control : 1))
            .focusShadow(Theme.Shadow.chip, isFocused: isFocused)
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

    private var entries: [CategoryEntry] { CategoryEntry.entries(model.filterOptions) }

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
            .background(Theme.Colors.scrim)
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
        option.title(in: categories)
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

/// A row of a category list, or the heading above the first row of a kind (only when the
/// list has more than one kind).
enum CategoryEntry: Identifiable {
    case heading(String)
    case option(ChannelFilterOption)

    var id: String {
        switch self {
        case .heading(let title): return "heading:" + title
        case .option(let option): return option.filter.storageKey
        }
    }

    static func entries(_ options: [ChannelFilterOption]) -> [CategoryEntry] {
        let headings = Set(options.compactMap(\.kind)).count > 1
        var shown: String?
        var out: [CategoryEntry] = []
        for option in options {
            // an exclusive category (the adult one) is last, without a heading of its own
            if headings, !option.exclusive, let kind = option.kind, kind != shown, let title = ChannelCategory.kindTitle(kind) {
                out.append(.heading(title))
            }
            if option.kind != nil { shown = option.kind }
            out.append(.option(option))
        }
        return out
    }
}

extension ChannelFilterOption {
    /// What the row says: a category's own label, else the filter's name.
    func title(in categories: [ChannelCategory]) -> String {
        if case .category = filter, let label, !label.isEmpty { return label }
        return filter.title(in: categories)
    }
}

// MARK: - Channel list

/// The one list, in the server's order, on a panel beside the card of the focused programme.
/// A row per channel with what is on now; select tunes in, a long press offers the star. With
/// few channels the rows are tall and carry the programme's still, with many they are compact.
private struct ChannelListView: View {
    let model: TVModel
    var focused: FocusState<Int?>.Binding
    let initial: Int?
    /// The row to put focus on once it exists (see `TVView.focusRequest`).
    let focusRequest: Int?
    let watch: (Channel) -> Void

    /// The channel last focused: the card keeps showing it while focus is elsewhere (the header, a long press's menu).
    @State private var shownId: Int?

    /// The panel's share of the width left after the gap; the card has the rest.
    static let listShare: CGFloat = 0.46
    static let gap: CGFloat = 48
    /// The panel's and the card's corner radius.
    static let panelRadius: CGFloat = 36
    /// The panel's inner margin and the rows' spacing.
    static let panelPadding: CGFloat = 24
    static let rowSpacing: CGFloat = 6
    /// A compact row; a tall row (at most `tallRow`) grows with the panel's room and gets the still from `stillRow` up.
    static let compactRow: CGFloat = 124
    static let tallRow: CGFloat = 208
    static let stillRow: CGFloat = 168

    /// The rows' height for `count` channels on a panel `height` tall: they fill it when they are few.
    static func rowHeight(panelHeight height: CGFloat, count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let room = (height - panelPadding * 2 - rowSpacing * (n - 1)) / n
        return min(max(room, compactRow), tallRow).rounded(.down)
    }

    var body: some View {
        let channels = model.channels
        if channels.isEmpty {
            EmptyStateView(
                systemImage: model.activeFilter == .favorites ? "star" : "tv",
                title: model.activeFilter == .favorites ? "No favorite channels" : "No channels here",
                message: model.activeFilter == .favorites
                    ? "Press and hold a channel, or use the star in the player, to add it to Favorites."
                    : "Choose another filter."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let rowHeight = Self.rowHeight(panelHeight: proxy.size.height, count: channels.count)
                HStack(alignment: .top, spacing: Self.gap) {
                    list(channels, rowHeight: rowHeight)
                        .frame(width: ((proxy.size.width - Self.gap) * Self.listShare).rounded(), height: proxy.size.height)
                        .background(Theme.Colors.fillSecondary, in: RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
                    // What the focused row is showing, at full size (the list keeps to a few lines).
                    if let shown = channels.first(where: { $0.id == (focused.wrappedValue ?? shownId) }) ?? channels.first(where: { $0.id == initial }) {
                        ProgrammeCard(channel: shown)
                            .frame(maxWidth: .infinity)
                            .frame(height: proxy.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
                    }
                }
            }
            .onChange(of: focused.wrappedValue) { _, id in
                if let id { shownId = id }
            }
        }
    }

    private func list(_ channels: [Channel], rowHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(channels) { channel in
                        Button {
                            watch(channel)
                        } label: {
                            ChannelRow(channel: channel, height: rowHeight, showsStill: rowHeight >= Self.stillRow)
                        }
                        .buttonStyle(ChannelRowButtonStyle())
                        .focused(focused, equals: channel.id)
                        .id(channel.id)
                        // A long press: the star first, as a TV's channel list has it.
                        .contextMenu {
                            Button {
                                Task { await model.toggleFavorite(channel.id) }
                            } label: {
                                if channel.favorite {
                                    Label("Remove from Favorites", systemImage: "star.slash")
                                } else {
                                    Label("Add to Favorites", systemImage: "star")
                                }
                            }
                            Button {
                                watch(channel)
                            } label: {
                                Label("Watch", systemImage: "play.fill")
                            }
                        }
                        .onPlayPauseCommand { watch(channel) }
                        .onAppear {
                            // The requested row came into being (the list scrolled to it).
                            if focusRequest == channel.id { focused.wrappedValue = channel.id }
                        }
                    }
                }
                // Room for the focused row's plate and lift.
                .padding(.horizontal, Self.panelPadding + Theme.Layout.listRowInset - 8)
                .padding(.vertical, Self.panelPadding)
            }
            .focusSection()
            .onAppear {
                if let initial { proxy.scrollTo(initial, anchor: .center) }
            }
            // Another category: its list from the last channel (else its first).
            .onChange(of: model.activeFilter) {
                if let target = initial ?? channels.first?.id { proxy.scrollTo(target, anchor: .center) }
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

/// A channel row, as a television's channel list (TiviMate's, the web's): the number in
/// tabular digits, the logo (or the guide's icon, or the generated tile), the channel's name
/// and what is on with a thin progress bar; a tall row (few channels) has the programme's
/// still at its end. Focus lifts the row on a light plate.
struct ChannelRow: View {
    let channel: Channel
    var height: CGFloat = 124
    var showsStill = false

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let program = channel.program(at: context.date)
            HStack(alignment: .center, spacing: 22) {
                Text(verbatim: String(channel.number))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    // external channels start at 100: room for three digits, a fourth fits by shrinking
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 84, alignment: .trailing)
                ChannelLogo(channel, height: 56)
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
                                .accessibilityLabel(Text("Favorite"))
                        }
                    }
                    Text(verbatim: program?.fullTitle ?? String(localized: "Nothing on now", bundle: .localized))
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(primary.opacity(0.8))
                        .lineLimit(showsStill ? 2 : 1)
                        .truncationMode(.tail)
                    LiveProgressBar(value: program.map { $0.isOnAir(at: context.date) ? $0.progress(at: context.date) : 0 } ?? 0, onLight: isFocused, height: 4)
                        .opacity(program?.isOnAir(at: context.date) == true ? 1 : 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The programme's picture only when it has one: no empty box.
                if showsStill, let program, !program.still.isEmpty {
                    ProgrammeStill(program: program, maxPixelSize: 500, cornerRadius: 10)
                        .frame(width: 228, height: 128)
                }
            }
            .frame(height: height)
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

/// The focused channel's programme as a card: its still across the whole card, «N · name» and
/// LIVE on top, and over a scrim on the lower part the facts, title, episode, time and
/// progress, overview, what is next and the keys.
private struct ProgrammeCard: View {
    let channel: Channel

    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let program = channel.program(at: context.date)
            ZStack(alignment: .bottomLeading) {
                Theme.Colors.elevated
                ProgrammeStill(program: program, maxPixelSize: 1500, cornerRadius: 0)
                // Clear over the picture's upper part, dark under the text.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.05), location: 0.3),
                        .init(color: .black.opacity(0.82), location: 0.62),
                        .init(color: .black.opacity(0.97), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 12) {
                    if let program {
                        if !program.metaLine.isEmpty {
                            Text(verbatim: program.metaLine)
                                .font(Theme.Typography.eyebrow)
                                .tracking(1.5)
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.Colors.label2)
                                .lineLimit(1)
                        }
                        Text(verbatim: program.title)
                            .font(Theme.Typography.pageTitle)
                            .foregroundStyle(Theme.Colors.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if !program.subtitle.isEmpty {
                            Text(verbatim: program.subtitle)
                                .font(Theme.Typography.sectionTitle)
                                .foregroundStyle(Theme.Colors.label2)
                                .lineLimit(1)
                        }
                        HStack(spacing: 24) {
                            Text(verbatim: program.timeRange(locale))
                                .monospacedDigit()
                                .foregroundStyle(Theme.Colors.label)
                            if program.isOnAir(at: context.date) {
                                LiveProgressBar(value: program.progress(at: context.date))
                                    .frame(maxWidth: .infinity)
                                Text(verbatim: program.untilLine(locale))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Colors.label2)
                            }
                        }
                        .font(Theme.Typography.meta)
                        .padding(.top, 4)
                        if !program.overview.isEmpty {
                            Text(verbatim: program.overview)
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.label2)
                                .lineLimit(2)
                        }
                    } else {
                        Text("Nothing on now")
                            .font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Colors.label)
                    }
                    if let next = channel.upNext(at: context.date) {
                        Text(verbatim: next.nextLine(locale))
                            .font(Theme.Typography.cardMeta)
                            .foregroundStyle(Theme.Colors.label3)
                            .lineLimit(1)
                    }
                    HStack(spacing: 40) {
                        KeyHint(key: "Press", label: "Watch")
                        KeyHint(key: "Hold", label: channel.favorite ? "Remove from Favorites" : "Add to Favorites")
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 20) {
                    HStack(spacing: 16) {
                        ChannelLogo(channel, height: 44)
                        Text(verbatim: channel.label)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label)
                            .lineLimit(1)
                        if channel.favorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.Colors.label2)
                        }
                    }
                    if program?.isOnAir(at: context.date) == true { LiveBadge() }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Theme.Colors.scrimStrong, in: Capsule())
                .padding(32)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// «Select  Watch»: a remote key in a small outline, and what it does.
private struct KeyHint: View {
    let key: LocalizedStringKey
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Text(key)
                .font(Theme.Typography.badge)
                .foregroundStyle(Theme.Colors.label)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge * 2, style: .continuous).stroke(Theme.Colors.label3, lineWidth: 2))
            Text(label)
                .font(Theme.Typography.cardMeta)
                .foregroundStyle(Theme.Colors.label2)
                .lineLimit(1)
        }
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
            .focusPlate(
                isFocused: isFocused, isPressed: configuration.isPressed,
                radius: Theme.Radius.sheet, scale: Theme.Motion.Focus.channelRow, shadow: Theme.Shadow.channelRow
            )
            .padding(.horizontal, -Theme.Layout.listRowInset)
    }
}

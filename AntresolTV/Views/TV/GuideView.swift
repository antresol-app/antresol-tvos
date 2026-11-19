import AntresolKit
import SwiftUI


/// «Телегид»: channels × time. A channel column (number, name, star), a time ruler, a
/// block per programme as wide as it is long, the now line; past programmes are dimmed,
/// the ones on air lighter with their progress. Every block is a focusable button: Left /
/// Right go along a row, Up / Down go to the programme of the next row that is on at the
/// same time (each row is a focus section whose default focus is the programme at the
/// guide's time anchor, so a long film above short episodes does not drag focus to its own
/// start). Moving towards the edges scrolls the grid and loads the next window. Select
/// opens the programme; Play/Pause tunes in to a programme on air; Up from the first row
/// goes back to the filters.
struct GuideView: View {
    let model: TVModel
    let open: (ProgramDetails) -> Void
    let watch: (Channel) -> Void

    @Environment(\.locale) private var locale
    @FocusState private var focused: String?
    /// The time vertical moves keep.
    @State private var anchor = Date()
    @State private var viewStart = Date()
    @State private var firstRow = 0
    @State private var placed = false

    static let channelColumn: CGFloat = 330
    static let rulerHeight: CGFloat = 60
    static let rowHeight: CGFloat = 104
    static let rowSpacing: CGFloat = 8
    static let blockGap: CGFloat = 6
    /// Between the channel column and the time area.
    static let columnGap: CGFloat = 24
    private static var rowPitch: CGFloat { rowHeight + rowSpacing }
    /// The time area runs from after the channel column to the screen's right edge.
    private static var timeAreaWidth: CGFloat { 1920 - Theme.Layout.margin - channelColumn - columnGap }

    var body: some View {
        switch model.guidePhase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await model.loadGuide() }
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await model.reloadGuide() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            grid
        }
    }

    private var rows: [ChannelEPG] {
        model.guideRows
    }

    private var scale: GuideScale {
        model.guideScale
    }

    private var viewEnd: Date {
        viewStart.addingTimeInterval(scale.interval(Self.timeAreaWidth))
    }

    private static func emptyKey(_ channelId: Int) -> String {
        "empty-\(channelId)"
    }

    /// A block's focus identity: its row and its programme. A programme's key is unique
    /// in its row only: two external channels of one guide source have the same key for
    /// programmes that start at the same instant, and focus moving between two such
    /// blocks must be a change of the focused value.
    private static func focusKey(_ channelId: Int, _ program: ChannelProgram) -> String {
        "\(channelId)|\(program.key)"
    }

    @ViewBuilder
    private var grid: some View {
        let rows = rows
        if rows.isEmpty {
            EmptyStateView(
                systemImage: model.activeFilter == .favorites ? "star" : "tv",
                title: model.activeFilter == .favorites ? "No favourite channels" : "No channels here",
                message: model.activeFilter == .favorites
                    ? "Press and hold a channel in the list, or use the star in the player, to add it to Favourites."
                    : "Choose another filter."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let visibleRows = max(1, Int((proxy.size.height - Self.rulerHeight) / Self.rowPitch))
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let now = context.date
                    VStack(alignment: .leading, spacing: 0) {
                        ruler(now: now)
                            .frame(height: Self.rulerHeight)
                        rowsView(rows, visibleRows: visibleRows, now: now)
                            .frame(height: proxy.size.height - Self.rulerHeight, alignment: .topLeading)
                            .clipped()
                    }
                    // The now line in the same column layout as the ruler and the rows.
                    .overlay(alignment: .topLeading) {
                        timeColumn {
                            nowLine(now: now)
                        } label: {
                            Color.clear
                        }
                        .padding(.top, 30)
                        .allowsHitTesting(false)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                .onAppear { place(rows, visibleRows: visibleRows) }
                .onChange(of: rows.map(\.id)) { place(rows, visibleRows: visibleRows, keep: true) }
                .onChange(of: focused) { old, new in focusMoved(from: old, to: new, visibleRows: visibleRows) }
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(Theme.Motion.easeOut, value: viewStart)
            .animation(Theme.Motion.easeOut, value: firstRow)
        }
    }

    // MARK: - Drawing

    /// The guide's columns, the same for the ruler, every row and the now line: the
    /// channel column, then the time area starting at `viewStart` (x = 0). Keeping one
    /// layout is what keeps ticks, blocks and the now line on one axis.
    private func timeColumn<Area: View, Label: View>(@ViewBuilder _ area: () -> Area, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: Self.columnGap) {
            label()
                .frame(width: Self.channelColumn, alignment: .leading)
            ZStack(alignment: .topLeading) {
                Color.clear
                area()
            }
            .frame(width: Self.timeAreaWidth, alignment: .topLeading)
        }
        .padding(.leading, Theme.Layout.margin)
    }

    /// x of `date` in the time area (GuideScale.x, the one function for all three).
    private func x(_ date: Date) -> CGFloat {
        CGFloat(scale.x(date, from: viewStart))
    }

    private func ruler(now: Date) -> some View {
        let scale = scale
        let tick = TimeInterval(scale.tickMinutes * 60)
        let first = scale.tick(atOrBefore: viewStart)
        let ticks = stride(from: first.timeIntervalSince1970, through: viewEnd.timeIntervalSince1970, by: tick).map { Date(timeIntervalSince1970: $0) }
        return timeColumn {
            ForEach(ticks, id: \.self) { date in
                let x = self.x(date)
                if x >= -1 {
                    // The tick mark sits exactly at x; its label follows it.
                    Rectangle()
                        .fill(Theme.Colors.hairline)
                        .frame(width: 2, height: 20)
                        .offset(x: x - 1, y: 14)
                    Text(verbatim: date.clock(locale))
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.label3)
                        .fixedSize()
                        .offset(x: x + 10, y: 10)
                }
            }
        } label: {
            Text(verbatim: viewStart.addingTimeInterval(scale.interval(Self.timeAreaWidth / 3)).dayName(locale, now: now))
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Colors.label2)
                .padding(.top, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// The rows on screen plus one either side, so Up / Down always have a row to go to.
    private func rowsView(_ rows: [ChannelEPG], visibleRows: Int, now: Date) -> some View {
        let lower = max(0, firstRow - 1)
        let upper = min(rows.count, firstRow + visibleRows + 1)
        let shown = lower < upper ? Array(rows[lower..<upper]) : []
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(shown) { row in
                timeColumn {
                    programmes(row, now: now)
                } label: {
                    channelCell(row)
                }
                .frame(height: Self.rowHeight)
                .focusSection()
                // Moving into a row lands on its programme at the guide's time.
                .defaultFocus($focused, target(in: row), priority: .userInitiated)
            }
        }
        .offset(y: -CGFloat(firstRow - lower) * Self.rowPitch)
    }

    private func channelCell(_ row: ChannelEPG) -> some View {
        let isCurrent = row.programs.contains { Self.focusKey(row.id, $0) == focused } || focused == Self.emptyKey(row.id)
        return HStack(spacing: 18) {
            Text(verbatim: String(row.number))
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.label3)
                // external channels start at 100: room for three digits, a fourth fits by shrinking
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 76, alignment: .trailing)
            ChannelLogo(row.channel, height: 36)
            Text(verbatim: row.name)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isCurrent ? Theme.Colors.label : Theme.Colors.label2)
                // One clean line: a long name ends in an ellipsis, never hyphenated.
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if row.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.label3)
                    .accessibilityLabel(Text("Favourite"))
            }
        }
        .padding(.trailing, 18)
        .frame(width: Self.channelColumn, height: Self.rowHeight, alignment: .leading)
        .background(isCurrent ? Theme.Colors.fill : Theme.Colors.fillSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    /// A row's blocks: every programme loaded from a little before the view to a little
    /// after it (the neighbours off screen must exist for focus to move to them).
    private func programmes(_ row: ChannelEPG, now: Date) -> some View {
        let scale = scale
        let margin = scale.interval(Self.timeAreaWidth)
        let from = viewStart.addingTimeInterval(-margin)
        let to = viewEnd.addingTimeInterval(margin)
        let shown = row.programs.filter { $0.end > from && $0.start < to }
        return ZStack(alignment: .topLeading) {
            if row.programs.isEmpty {
                Button {} label: {
                    Text("No programmes")
                        .font(Theme.Typography.cardMeta)
                        .padding(.horizontal, 22)
                        .frame(width: Self.timeAreaWidth - Self.blockGap, height: Self.rowHeight, alignment: .leading)
                }
                .buttonStyle(GuideBlockStyle(fill: Color.white.opacity(0.04)))
                .focused($focused, equals: Self.emptyKey(row.id))
            }
            ForEach(shown, id: \.key) { program in
                let x = self.x(program.start)
                let right = self.x(program.end)
                // A block cut by the left edge starts at the edge (its text stays readable);
                // one wholly before the view stays where it is, off screen (focus can reach
                // it, and the view then scrolls to it).
                let left = right > 0 ? max(x, -2) : x
                Button {
                    open(ProgramDetails(channelId: row.id, program: program))
                } label: {
                    // A sliver left of the view shows no text (a lone chevron reads as noise).
                    GuideBlock(program: program, now: now, continuesBefore: x < left, showsText: right - left - Self.blockGap >= 110)
                        .frame(width: max(8, right - left - Self.blockGap), height: Self.rowHeight)
                }
                .buttonStyle(GuideBlockStyle(fill: fill(program, now: now)))
                .focused($focused, equals: Self.focusKey(row.id, program))
                .onPlayPauseCommand {
                    if program.isOnAir(at: Date()) { watch(model.channel(row.id) ?? row.channel) }
                }
                .offset(x: left)
                .accessibilityLabel(Text(verbatim: "\(row.number) · \(row.name), \(program.fullTitle), \(program.timeRange(locale))"))
            }
        }
        .frame(width: Self.timeAreaWidth, height: Self.rowHeight, alignment: .topLeading)
        // Room for the focused block's lift, then the screen's edge.
        .padding(.vertical, 12)
        .clipped()
        .padding(.vertical, -12)
    }

    private func fill(_ program: ChannelProgram, now: Date) -> Color {
        if program.isOnAir(at: now) { return Color.white.opacity(0.16) }
        return Color.white.opacity(program.end <= now ? 0.04 : 0.08)
    }

    @ViewBuilder
    private func nowLine(now: Date) -> some View {
        let x = self.x(now)
        if x >= 0, x <= Self.timeAreaWidth {
            VStack(spacing: 0) {
                Circle()
                    .fill(Theme.Colors.red)
                    .frame(width: 14, height: 14)
                Rectangle()
                    .fill(Theme.Colors.red)
                    .frame(width: 3)
            }
            .frame(maxHeight: .infinity)
            // Centred on x: the circle is 14 pt wide.
            .offset(x: x - 7)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Focus

    /// The programme of `row` on at the anchor (the row's focus target).
    private func target(in row: ChannelEPG) -> String {
        row.program(near: anchor).map { Self.focusKey(row.id, $0) } ?? Self.emptyKey(row.id)
    }

    /// Where a focus key is: its row and programme.
    private func locate(_ key: String?, in rows: [ChannelEPG]) -> (row: Int, program: ChannelProgram?)? {
        guard let key else { return nil }
        for (index, row) in rows.enumerated() {
            if key == Self.emptyKey(row.id) { return (index, nil) }
            if let program = row.programs.first(where: { Self.focusKey(row.id, $0) == key }) { return (index, program) }
        }
        return nil
    }

    /// First look (and a new filter): the view from a little before now, the last channel
    /// at the top, the anchor at now.
    private func place(_ rows: [ChannelEPG], visibleRows: Int, keep: Bool = false) {
        let now = Date()
        if !placed || !keep {
            let tick = TimeInterval(scale.tickMinutes * 60)
            viewStart = max(earliest(now), scale.tick(atOrBefore: now).addingTimeInterval(-tick))
            anchor = now
        }
        let wanted = locate(focused, in: rows)?.row ?? rows.firstIndex { $0.id == model.list.lastChannel } ?? 0
        firstRow = max(0, min(wanted, max(0, rows.count - visibleRows)))
        placed = true
    }

    /// Focus moved (by the remote, or into the grid): keep the time on vertical moves (and
    /// put focus right if the engine chose another block), follow it horizontally, scroll
    /// rows and time to keep it on screen, and load more of the guide near the ends.
    private func focusMoved(from old: String?, to new: String?, visibleRows: Int) {
        let rows = rows
        guard let now = locate(new, in: rows) else { return }
        let before = locate(old, in: rows)
        if let before, before.row != now.row {
            // A vertical move: the programme at the anchor, whatever the engine picked.
            let wanted = target(in: rows[now.row])
            if wanted != new {
                // Not inside this focus update: SwiftUI ignores a change made there.
                Task { @MainActor in focused = wanted }
                return
            }
        } else if before != nil, let program = now.program {
            // Along the row: the anchor follows.
            anchor = min(max(program.start, viewStart), program.end.addingTimeInterval(-1))
        } else if before == nil {
            // Into the grid from the header: the row's programme at the anchor, which is
            // never left in the past (the page may have been open for a while).
            if anchor < Date() { anchor = Date() }
            let wanted = target(in: rows[now.row])
            if wanted != new {
                // Not inside this focus update: SwiftUI ignores a change made there.
                Task { @MainActor in focused = wanted }
                return
            }
        }
        // Rows: keep the focused one on screen.
        if now.row < firstRow {
            firstRow = now.row
        } else if now.row >= firstRow + visibleRows {
            firstRow = now.row - visibleRows + 1
        }
        // Time: keep the focused programme's start (or the anchor) on screen.
        let tick = TimeInterval(scale.tickMinutes * 60)
        let point = now.program.map { max($0.start, min(anchor, $0.end)) } ?? anchor
        if point < viewStart {
            viewStart = max(earliest(Date()), scale.tick(atOrBefore: point))
        } else if point > viewEnd.addingTimeInterval(-2 * tick) {
            viewStart = scale.tick(atOrBefore: point).addingTimeInterval(-tick)
        }
        prefetch()
    }

    private func earliest(_ now: Date) -> Date {
        scale.tick(atOrBefore: now.addingTimeInterval(-TVModel.guidePast))
    }

    /// Loads the next window before the view reaches the end of what is loaded.
    private func prefetch() {
        if let loadedTo = model.grid.loadedTo, viewEnd.addingTimeInterval(scale.interval(Self.timeAreaWidth)) > loadedTo {
            Task { await model.loadWindow(forward: true) }
        }
        if let loadedFrom = model.grid.loadedFrom, viewStart.addingTimeInterval(-scale.interval(Self.timeAreaWidth)) < loadedFrom, model.canLoadEarlier() {
            Task { await model.loadWindow(forward: false) }
        }
    }
}

/// A block's focus: a light plate with dark text and a small lift, like the system's
/// focused list rows; at rest its own fill.
private struct GuideBlockStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        GuideBlockBody(configuration: configuration, fill: fill)
    }
}

private struct GuideBlockBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .environment(\.isCardFocused, isFocused)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label3)
            .background(isFocused ? Color.white : fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.04 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: 18, y: 10)
            .zIndex(isFocused ? 1 : 0)
            .animation(Theme.Motion.easeOut, value: isFocused)
    }
}

/// A programme in the guide: title and time (the episode after it), dimmed when over, its
/// progress while on air; dark text on the light plate under focus.
private struct GuideBlock: View {
    let program: ChannelProgram
    let now: Date
    /// Began before the visible part: a chevron says it goes on to the left.
    let continuesBefore: Bool
    var showsText = true

    @Environment(\.isCardFocused) private var isFocused
    @Environment(\.locale) private var locale

    var body: some View {
        let isPast = program.end <= now
        ZStack(alignment: .bottomLeading) {
            if showsText || isFocused {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if continuesBefore {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .bold))
                        }
                        Text(verbatim: program.title)
                            .font(.system(size: 24, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isFocused ? Theme.Colors.labelInverse : (isPast ? Theme.Colors.label3 : Theme.Colors.label))
                    Text(verbatim: program.subtitle.isEmpty ? program.timeRange(locale) : "\(program.timeRange(locale)) · \(program.subtitle)")
                        .font(.system(size: 20, weight: .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(isFocused ? Theme.Colors.labelInverse.opacity(0.6) : Theme.Colors.label3)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            // no progress bar per programme: the red now line says where now is
        }
    }
}

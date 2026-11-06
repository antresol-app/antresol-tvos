import AntresolKit
import SwiftUI

/// The full-bleed feature carousel at the top of Home, laid out like the TV app's: the
/// artwork fills the screen, then a huge title, a metadata line (kind, genres, rating
/// badge), a one-line description, the light Play pill and round glass buttons for the
/// watchlist, the details page and the next featured item. Page dots show the position.
/// The first shelf below overlaps the hero's bottom edge (`HeroView.overlap`).
///
/// With several featured items it advances every 8 seconds while its buttons are not
/// focused; Left on Play goes back by hand. The backgrounds cross-fade.
struct HeroView: View {
    let features: [HomeContent.Feature]

    /// How far the next row on the page rises into the hero.
    static let overlap: CGFloat = 300

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var index = 0
    /// Each featured item's page (genres, rating, description, watchlist state), loaded
    /// once per item: the carousel comes back to the same few items every 8 seconds.
    @State private var details: [String: ItemDetail] = [:]
    @FocusState private var focusedButton: Control?

    private enum Control: Hashable {
        case play, watchlist, details, next
    }

    private static let interval: Duration = .seconds(8)

    private var feature: HomeContent.Feature {
        features[min(index, features.count - 1)]
    }

    private var card: Card { feature.card }

    private var detail: ItemDetail? { details[card.uniqueKey] }

    private var inWatchlist: Bool { detail?.inWatchlist ?? false }

    /// For a series: the episode Play starts, so the button can name it.
    private var seriesEpisode: EpisodeCard? {
        guard card.kind == .series, let detail else { return nil }
        return detail.next ?? detail.seasons.first?.episodes.first
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: card)
                .id(card.uniqueKey)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: card.title)
                    .font(Theme.Typography.heroTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 12)
                metaRow
                    .padding(.top, 18)
                if let summary {
                    Text(verbatim: summary)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                        .padding(.top, 10)
                }
                if progress > 0 {
                    ProgressBar(value: progress, height: 6)
                        .frame(width: 320)
                        .padding(.top, 18)
                }
                buttons
                    .padding(.top, 30)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, Self.overlap + 70)
            .animation(Theme.Motion.easeOut, value: index)

            if features.count > 1 {
                pageDots
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Self.overlap + 24)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.heroHeight, maxHeight: Theme.Layout.heroHeight, alignment: .bottomLeading)
        .task(id: focusedButton == nil) {
            // Auto-advance only while the user is not on the hero's buttons.
            guard focusedButton == nil, features.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                withAnimation(Theme.Motion.slowEaseOut) { index = (index + 1) % features.count }
            }
        }
        .task(id: "\(card.uniqueKey) \(appState.libraryRevision)") { await loadDetail() }
        .onChange(of: appState.libraryRevision) {
            // A watchlist change (here or on a page) makes the cached pages stale.
            details = [:]
        }
        .onChange(of: features) {
            if index >= features.count { index = 0 }
        }
    }

    private var buttons: some View {
        GlassGroup(spacing: 20) {
            HStack(spacing: 20) {
                Button {
                    playback.play(seriesEpisode?.card ?? card, from: .resume)
                } label: {
                    Label {
                        Text(verbatim: playTitle)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .focused($focusedButton, equals: .play)
                .onMoveCommand { if $0 == .left { page(by: -1) } }

                // Only films and shows have a watchlist.
                if card.kind.isVideo {
                    Button {
                        Task { await toggleWatchlist() }
                    } label: {
                        Label("Watchlist", systemImage: inWatchlist ? "checkmark" : "plus")
                    }
                    .buttonStyle(CircleButtonStyle(diameter: 76))
                    .focused($focusedButton, equals: .watchlist)
                    .disabled(detail == nil)
                    .accessibilityValue(Text(inWatchlist ? LocalizedStringKey("In Watchlist") : LocalizedStringKey("Not in Watchlist")))
                }

                NavigationLink(value: Route.item(card)) {
                    Label("Details", systemImage: "info.circle")
                }
                .buttonStyle(CircleButtonStyle(diameter: 76))
                .focused($focusedButton, equals: .details)

                if features.count > 1 {
                    Button {
                        page(by: 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .buttonStyle(CircleButtonStyle(diameter: 76))
                    .focused($focusedButton, equals: .next)
                }
            }
        }
        // As wide as the text column, so Down from anywhere above lands on the buttons;
        // the buttons alone would let the focus engine skip past them to the first shelf.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// Kind · genres, then the age rating as an outlined badge.
    private var metaRow: some View {
        HStack(spacing: 14) {
            Text(verbatim: metaLine)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.label)
                .lineLimit(1)
            if let rating = detail?.rating, !rating.isEmpty {
                Text(verbatim: rating)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.Colors.label)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Colors.label, lineWidth: 1.5))
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(features.indices, id: \.self) { dot in
                Capsule()
                    .fill(.white.opacity(dot == index ? 0.95 : 0.35))
                    .frame(width: dot == index ? 26 : 10, height: 10)
            }
        }
        .animation(Theme.Motion.easeOut, value: index)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: String(localized: "Featured \(index + 1) of \(features.count)", bundle: .localized)))
    }

    private func page(by step: Int) {
        guard features.count > 1 else { return }
        withAnimation(Theme.Motion.slowEaseOut) {
            index = (index + step + features.count) % features.count
        }
    }

    /// A film's or show's page (genres, rating, description, watchlist), unless loaded.
    private func loadDetail() async {
        let key = card.uniqueKey
        // `GET /api/items/{id}` serves films and shows only.
        guard card.kind.isVideo, details[key] == nil, let client = appState.client,
              let loaded = try? await client.item(id: card.id), !Task.isCancelled
        else { return }
        details[key] = loaded
    }

    private func toggleWatchlist() async {
        guard var updated = detail, let client = appState.client else { return }
        let key = card.uniqueKey
        let target = !updated.inWatchlist
        updated.inWatchlist = target
        details[key] = updated
        do {
            try await client.setInWatchlist(itemId: updated.id, target)
            appState.libraryChanged()
        } catch {
            updated.inWatchlist = !target
            details[key] = updated
            if let message = appState.message(for: error) {
                appState.showNotice(message)
            }
        }
    }

    private var playTitle: String {
        if card.kind == .series {
            return VideoDetailView.playTitle(for: seriesEpisode)
        }
        return card.progress > 0 ? String(localized: "Resume", bundle: .localized) : String(localized: "Play", bundle: .localized)
    }

    private var progress: Double {
        seriesEpisode?.progress ?? card.progress
    }

    /// The description: the item's overview, else the card's context line.
    private var summary: String? {
        if let overview = detail?.overview, !overview.isEmpty {
            return overview.components(separatedBy: .newlines).first
        }
        return card.subtitle.isEmpty ? nil : card.subtitle
    }

    /// Kind, genres (or the year when there are none), joined with middots.
    private var metaLine: String {
        var parts: [String] = []
        let kind = card.kind.displayName
        if !kind.isEmpty { parts.append(kind) }
        let genres = detail?.genres.prefix(2) ?? []
        if genres.isEmpty {
            if let year = card.year { parts.append(String(year)) }
        } else {
            parts.append(contentsOf: genres)
        }
        return parts.joined(separator: " · ")
    }
}

/// The hero backdrop: a glow tinted with the artwork's average colour, the backdrop image
/// when there is one, and gradients that fade it into the black page and keep the text
/// on the left legible.
struct HeroBackground: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @State private var tint: Color?

    var body: some View {
        ZStack {
            Theme.Colors.background
            RadialGradient(
                colors: [glow.opacity(0.95), glow.opacity(0.4), .clear],
                center: UnitPoint(x: 0.7, y: 0.15),
                startRadius: 0,
                endRadius: 1300
            )
            if !card.backdrop.isEmpty {
                RemoteImage(path: card.backdrop, maxPixelSize: 1920)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            LinearGradient(
                colors: [.black.opacity(0.8), .black.opacity(0.25), .clear],
                startPoint: .leading,
                endPoint: UnitPoint(x: 0.75, y: 0.5)
            )
            LinearGradient(
                stops: [.init(color: .clear, location: 0.5), .init(color: .black, location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(Theme.Motion.slowEaseOut, value: tint)
        .task(id: tintSource) { await loadTint() }
        .accessibilityHidden(true)
    }

    private var glow: Color {
        tint ?? Theme.tint(for: card.title)
    }

    /// Backdrop when there is one, otherwise the poster.
    private var tintSource: String {
        card.backdrop.isEmpty ? card.poster : card.backdrop
    }

    private func loadTint() async {
        guard let client = appState.client, let url = client.urls.image(tintSource) else {
            tint = nil
            return
        }
        let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders(for: url), maxPixelSize: 96)
        guard !Task.isCancelled else { return }
        tint = image.flatMap(ImagePipeline.tintColor(of:))
    }
}

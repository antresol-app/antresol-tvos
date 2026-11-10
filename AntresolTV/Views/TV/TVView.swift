import AntresolKit
import SwiftUI

/// The TV tab: the server's live channels («ТВ»). A section pill picks All (every section
/// as a row of channel cards) or one section (its channels in a grid); a card opens the
/// live player. What is on is refreshed every 30 s while the tab shows.
struct TVView: View {
    /// The All option of the section pill.
    static let allSections = ""
    /// How often the list (what is on now and next) is fetched again.
    static let refreshInterval: Duration = .seconds(30)

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @AppStorage("tv.section") private var storedSection = TVView.allSections
    @State private var loader = ContentLoader<[Channel]>()

    private let columns = Array(
        repeating: GridItem(.fixed(Self.gridCardWidth), spacing: Theme.Layout.cardSpacing, alignment: .top),
        count: 3
    )

    /// Three cards across the content width.
    private static let gridCardWidth = (Theme.Layout.contentWidth - 2 * Theme.Layout.cardSpacing) / 3

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                header
                    .padding(.horizontal, Theme.Layout.margin)
                content
            }
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task {
            while !Task.isCancelled {
                await loader.load(using: appState) { try await $0.channels().channels }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private var sections: [ChannelSection] {
        ChannelSection.group(loader.value ?? [])
    }

    /// The chosen section, or All when it is gone from the list.
    private var section: Binding<String> {
        Binding(
            get: { sections.contains { $0.category == storedSection } ? storedSection : Self.allSections },
            set: { storedSection = $0 }
        )
    }

    @ViewBuilder
    private var header: some View {
        let sections = sections
        if sections.count > 1 {
            // The pill sits next to the title while it fits, else on its own line.
            ViewThatFits(in: .horizontal) {
                PageHeader(title: "TV") { pill(sections) }
                VStack(alignment: .leading, spacing: 32) {
                    PageHeader(title: "TV") { EmptyView() }
                    ScrollView(.horizontal, showsIndicators: false) {
                        pill(sections)
                            .padding(.vertical, 12)
                    }
                    .scrollClipDisabled()
                    .padding(.vertical, -12)
                }
            }
        } else {
            PageHeader(title: "TV") { EmptyView() }
        }
    }

    private func pill(_ sections: [ChannelSection]) -> some View {
        SegmentedPill(
            options: [SegmentedPill<String>.Option(value: Self.allSections, title: String(localized: "All", bundle: .localized))]
                + sections.map { SegmentedPill<String>.Option(value: $0.category, title: $0.category) },
            selection: section
        )
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 600)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await loader.load(using: appState) { try await $0.channels().channels } }
            }
            .frame(minHeight: 700)
        case .loaded(let channels):
            if channels.isEmpty {
                EmptyStateView(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: "No channels yet",
                    message: "Channels appear by themselves once the library has at least six movies of a genre or a series with eight episodes."
                )
                .frame(minHeight: 700)
            } else if let shown = sections.first(where: { $0.category == section.wrappedValue }) {
                grid(shown, all: channels)
            } else {
                rows(all: channels)
            }
        }
    }

    /// All: a row of channel cards per section.
    private func rows(all channels: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing) {
            ForEach(sections) { section in
                ShelfRow(title: section.category, items: section.channels, id: \.id) { channel in
                    cardButton(channel, all: channels, width: Theme.Layout.wideWidth)
                }
            }
        }
    }

    /// One section: its channels in a grid.
    private func grid(_ section: ChannelSection, all channels: [Channel]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Layout.gridRowSpacing) {
            ForEach(section.channels) { channel in
                cardButton(channel, all: channels, width: Self.gridCardWidth)
            }
        }
        .padding(.horizontal, Theme.Layout.margin)
        .padding(.top, 24)
        .focusSection()
    }

    private func cardButton(_ channel: Channel, all channels: [Channel], width: CGFloat) -> some View {
        Button {
            playback.watch(channel, channels: channels)
        } label: {
            ChannelCard(channel: channel, width: width)
        }
        .buttonStyle(CardButtonStyle())
        .onPlayPauseCommand { playback.watch(channel, channels: channels) }
    }
}

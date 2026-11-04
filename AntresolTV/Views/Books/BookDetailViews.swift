import AntresolKit
import SwiftUI

// MARK: - Audiobook

/// An audiobook: tinted header with Play/Resume, Restart and Want to Read, the saved
/// position, and the chapters on the whole-book timeline (selecting one plays from it).
struct AudiobookDetailView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var loader = ContentLoader<BookDetail>()
    @State private var actionError: String?

    var body: some View {
        DetailScroll {
            let book = loader.value
            CollectionHeader(
                card: book?.card ?? card,
                eyebrow: ItemKind.audiobook.displayName,
                subtitle: book.map { $0.authors.joined(separator: ", ") } ?? card.subtitle,
                meta: book.map(Self.meta) ?? "",
                description: book?.description ?? "",
                progress: book.flatMap(Self.progressFraction),
                progressLabel: book.map(Self.progressLabel) ?? "",
                error: actionError
            ) {
                let resumeMs = book.map(ResumePolicy.audiobookStartMs) ?? 0
                Button {
                    play(book, fromBookMs: nil)
                } label: {
                    Label(isPlayingThis ? LocalizedStringKey("Now Playing") : (resumeMs > 0 ? "Resume" : "Play"), systemImage: isPlayingThis ? "waveform" : "play.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(book?.files.isEmpty ?? true)

                if resumeMs > 0, !isPlayingThis {
                    Button {
                        play(book, fromBookMs: 0)
                    } label: {
                        Label("Restart", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }

                if let book {
                    WantToReadButton(isOn: book.want) { await setWant(!book.want) }
                }
            }

            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 500)
            case .loaded(let book):
                if book.chapters.count > 1 {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionTitle("Chapters")
                        ChapterList(book: book, currentChapter: isPlayingThis ? audio.currentChapter : nil) { chapter in
                            if isPlayingThis {
                                audio.seek(toBookMs: chapter.startMs)
                                audio.resume()
                            } else {
                                play(book, fromBookMs: chapter.startMs)
                            }
                        }
                    }
                }
            }
        }
        .task(id: card.id) { await load() }
        .onChange(of: audio.progressRevision) { Task { await load() } }
    }

    private var isPlayingThis: Bool {
        audio.book?.id == card.id
    }

    private func play(_ book: BookDetail?, fromBookMs bookMs: Int?) {
        guard let book else { return }
        if isPlayingThis, bookMs == nil {
            audio.requestPresentation()
            audio.resume()
        } else {
            audio.play(book: book, fromBookMs: bookMs)
        }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.book(id: card.id) }
    }

    private func setWant(_ want: Bool) async {
        guard let client = appState.client else { return }
        actionError = nil
        loader.update { $0.want = want }
        do {
            try await client.setInWatchlist(itemId: card.id, want)
        } catch {
            loader.update { $0.want = !want }
            actionError = appState.message(for: error)
        }
    }

    private static func meta(_ book: BookDetail) -> String {
        metaLine([
            book.narrator.isEmpty ? "" : String(localized: "Narrated by \(book.narrator)"),
            durationText(ms: book.durationMs),
            book.series.map { $0.index > 0 ? "\($0.name) #\(BookFormat.number($0.index))" : $0.name } ?? "",
            book.year > 0 ? String(book.year) : "",
        ])
    }

    private static func progressFraction(_ book: BookDetail) -> Double? {
        guard let progress = book.progress else { return nil }
        if progress.finished { return 1 }
        guard book.durationMs > 0 else { return progress.fraction }
        return Double(progress.positionMs) / Double(book.durationMs)
    }

    private static func progressLabel(_ book: BookDetail) -> String {
        guard let progress = book.progress else { return "" }
        if progress.finished { return String(localized: "Finished") }
        let remaining = max(0, book.durationMs - progress.positionMs)
        return remaining > 0 ? PlaybackTime.remaining(Double(remaining) / 1000) : ""
    }
}

/// The chapters of an audiobook with their start time and length.
struct ChapterList: View {
    let book: BookDetail
    let currentChapter: Chapter?
    let select: (Chapter) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(book.chapters) { chapter in
                Button {
                    select(chapter)
                } label: {
                    ChapterRowLabel(chapter: chapter, number: (book.chapters.firstIndex(of: chapter) ?? 0) + 1, isCurrent: chapter == currentChapter)
                }
                .buttonStyle(ListRowButtonStyle())
            }
        }
        .padding(.horizontal, Theme.Layout.margin)
        .focusSection()
    }
}

struct ChapterRowLabel: View {
    let chapter: Chapter
    let number: Int
    let isCurrent: Bool

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.accent)
                } else {
                    Text(verbatim: String(number))
                        .font(Theme.Typography.meta.monospacedDigit())
                        .foregroundStyle(secondaryColor)
                }
            }
            .frame(width: 52, alignment: .trailing)
            Text(verbatim: chapter.title.isEmpty ? String(localized: "Chapter \(number)") : chapter.title)
                .font(Theme.Typography.headline)
                .lineLimit(1)
            Spacer(minLength: 20)
            Text(verbatim: PlaybackTime.clock(Double(chapter.startMs) / 1000))
                .font(Theme.Typography.meta.monospacedDigit())
                .foregroundStyle(secondaryColor)
            if chapter.endMs > chapter.startMs {
                Text(verbatim: durationText(ms: chapter.endMs - chapter.startMs))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(secondaryColor)
                    .frame(width: 160, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
    }

    private var secondaryColor: Color {
        isFocused ? Theme.Colors.labelInverse.opacity(0.65) : Theme.Colors.label2
    }
}

/// The watchlist toggle of books, audiobooks and comic series ("want" on the server).
struct WantToReadButton: View {
    let isOn: Bool
    let toggle: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task {
                await toggle()
                busy = false
            }
        } label: {
            Label("Want to Read", systemImage: isOn ? "checkmark" : "plus")
        }
        .buttonStyle(PillButtonStyle(kind: .glass))
        .disabled(busy)
        .accessibilityValue(Text(isOn ? LocalizedStringKey("In Watchlist") : LocalizedStringKey("Not in Watchlist")))
    }
}

enum BookFormat {
    /// "2" for 2.0, "2.5" for 2.5 (series positions).
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

// MARK: - Comic series

/// A comic series: header with Read / Continue and Want to Read, then its volumes.
/// Selecting a volume opens the reader.
struct ComicSeriesView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @State private var loader = ContentLoader<BookDetail>()
    @State private var reading: ComicReaderRequest?
    @State private var actionError: String?

    var body: some View {
        DetailScroll {
            let series = loader.value
            CollectionHeader(
                card: series?.card ?? card,
                eyebrow: String(localized: "Manga & Comics"),
                subtitle: series.map { $0.authors.joined(separator: ", ") } ?? "",
                meta: series.map { metaLine([$0.card.subtitle, $0.year > 0 ? String($0.year) : "", Self.directionLabel($0.readingDirection)]) } ?? card.subtitle,
                description: series?.description ?? "",
                error: actionError
            ) {
                let next = series.flatMap(Self.volumeToRead)
                Button {
                    if let next { reading = ComicReaderRequest(volume: next) }
                } label: {
                    Label(next.map { $0.progress > 0 && $0.progress < 1 } == true ? LocalizedStringKey("Continue Reading") : "Read", systemImage: "book")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(next == nil)

                if let series {
                    WantToReadButton(isOn: series.want) { await setWant(!series.want) }
                }
            }

            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 500)
            case .loaded(let series):
                if !series.volumes.isEmpty {
                    ShelfRow(title: String(localized: "Volumes"), items: series.volumes, id: \.id) { volume in
                        Button {
                            reading = ComicReaderRequest(volume: volume)
                        } label: {
                            PosterCard(card: volume.card)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
        }
        .task(id: card.id) { await load() }
        .fullScreenCover(item: $reading, onDismiss: { Task { await load() } }) { request in
            ComicReaderView(request: request)
                .environment(appState)
        }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.book(id: card.id) }
    }

    private func setWant(_ want: Bool) async {
        guard let client = appState.client else { return }
        actionError = nil
        loader.update { $0.want = want }
        do {
            try await client.setInWatchlist(itemId: card.id, want)
        } catch {
            loader.update { $0.want = !want }
            actionError = appState.message(for: error)
        }
    }

    /// The first volume started but not finished, else the first unread one, else the first.
    static func volumeToRead(_ series: BookDetail) -> VolumeCard? {
        series.volumes.first { $0.progress > 0 && $0.progress < 1 }
            ?? series.volumes.first { $0.progress == 0 }
            ?? series.volumes.first
    }

    static func directionLabel(_ direction: ReadingDirection) -> String {
        direction == .rightToLeft ? String(localized: "Right to left") : ""
    }
}

// MARK: - Comic volume

/// A comic volume (from the Reading Now shelf or search): Read / Continue from the saved
/// page, Start Over, the next volume and the series.
struct ComicVolumeView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @State private var loader = ContentLoader<BookDetail>()
    @State private var reading: ComicReaderRequest?

    var body: some View {
        DetailScroll {
            let volume = loader.value
            let savedPage = volume?.progress.flatMap { ComicProgress.pageIndex(locator: $0.locator) }
            CollectionHeader(
                card: volume?.card ?? card,
                eyebrow: volume?.series?.name ?? String(localized: "Manga & Comics"),
                subtitle: volume?.card.subtitle ?? card.subtitle,
                meta: volume.map { metaLine([$0.authors.joined(separator: ", "), ComicSeriesView.directionLabel($0.readingDirection)]) } ?? "",
                description: volume?.description ?? "",
                progress: volume?.progress?.fraction ?? card.progress,
                progressLabel: savedPage.map { String(localized: "Page \($0 + 1)") } ?? ""
            ) {
                let canResume = savedPage.map { $0 > 0 } ?? false
                Button {
                    if let volume { reading = ComicReaderRequest(volume: volume, startPage: nil) }
                } label: {
                    Label(canResume ? LocalizedStringKey("Continue Reading") : "Read", systemImage: "book")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(volume == nil || volume?.readFileId == 0)

                if canResume, let volume {
                    Button {
                        reading = ComicReaderRequest(volume: volume, startPage: 0)
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }

                if let volume, volume.nextId > 0 {
                    NavigationLink(value: Route.item(Card(id: volume.nextId, kind: .comicVolume, title: volume.card.title, poster: volume.card.poster, seriesId: volume.seriesId))) {
                        Label("Next Volume", systemImage: "forward.end")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }

                if let volume, volume.seriesId > 0 {
                    NavigationLink(value: Route.item(Card(id: volume.seriesId, kind: .comic, title: volume.series?.name ?? volume.card.title, poster: volume.card.poster))) {
                        Label("Go to Series", systemImage: "books.vertical")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }
            }

            if case .failed(let message) = loader.state {
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 500)
            }
        }
        .task(id: card.id) { await load() }
        .fullScreenCover(item: $reading, onDismiss: { Task { await load() } }) { request in
            ComicReaderView(request: request)
                .environment(appState)
        }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.book(id: card.id) }
    }
}

// MARK: - E-book

/// E-books cannot be read on the TV: the page shows the book and says where to read it.
struct EbookDetailView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @State private var loader = ContentLoader<BookDetail>()
    @State private var actionError: String?

    var body: some View {
        DetailScroll {
            let book = loader.value
            CollectionHeader(
                card: book?.card ?? card,
                eyebrow: ItemKind.book.displayName,
                subtitle: book.map { $0.authors.joined(separator: ", ") } ?? card.subtitle,
                meta: book.map { metaLine([$0.files.first?.format ?? "", $0.year > 0 ? String($0.year) : "", $0.series?.name ?? ""]) } ?? "",
                description: book?.description ?? "",
                progress: book?.progress?.fraction,
                error: actionError
            ) {
                if let book {
                    WantToReadButton(isOn: book.want) { await setWant(!book.want) }
                }
            }

            HStack(alignment: .top, spacing: 24) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Colors.label2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reading books isn’t available on Apple TV")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.label)
                    Text("Open this book in Antresol on your phone, tablet or computer. Your place is saved on the server.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label2)
                }
            }
            .padding(36)
            .frame(maxWidth: 1300, alignment: .leading)
            .background(Theme.Colors.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .padding(.horizontal, Theme.Layout.margin)
            .focusable()
        }
        .task(id: card.id) {
            await loader.load(using: appState) { try await $0.book(id: card.id) }
        }
    }

    private func setWant(_ want: Bool) async {
        guard let client = appState.client else { return }
        actionError = nil
        loader.update { $0.want = want }
        do {
            try await client.setInWatchlist(itemId: card.id, want)
        } catch {
            loader.update { $0.want = !want }
            actionError = appState.message(for: error)
        }
    }
}

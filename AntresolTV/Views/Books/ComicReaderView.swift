import AntresolKit
import Observation
import SwiftUI
import UIKit

/// What the comic reader opens.
struct ComicReaderRequest: Identifiable, Hashable {
    let volumeId: Int
    let title: String
    let subtitle: String
    /// File id for `/api/comics/{fileId}/...`.
    let fileId: Int
    /// 0-based page to open at; nil resumes from the saved page.
    let startPage: Int?

    var id: Int { volumeId }

    init(volume: VolumeCard) {
        volumeId = volume.id
        title = volume.title
        subtitle = volume.subtitle
        fileId = volume.fileId
        startPage = nil
    }

    init(volume: BookDetail, startPage: Int?) {
        volumeId = volume.id
        title = volume.card.title
        subtitle = volume.card.subtitle
        fileId = volume.readFileId
        self.startPage = startPage
    }
}

/// Pages, spreads, image loading and progress of one comic volume.
@MainActor
@Observable
final class ComicReaderModel {
    enum State: Equatable {
        case loading
        case reading
        case failed(String)
    }

    let request: ComicReaderRequest
    private(set) var state: State = .loading
    private(set) var direction: ReadingDirection = .leftToRight
    private(set) var pageCount = 0
    private(set) var spreads: [[Int]] = []
    private(set) var spreadIndex = 0
    /// Past the last page: the end card shows.
    private(set) var isAtEnd = false
    private(set) var images: [Int: UIImage] = [:]
    private(set) var failedPages: Set<Int> = []
    private(set) var twoPages: Bool

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var sizes: [ComicPages.PageSize] = []
    @ObservationIgnored private var loading: Set<Int> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedPage: Int?

    private static let twoPagesKey = "comics.twoPages"

    init(request: ComicReaderRequest) {
        self.request = request
        twoPages = UserDefaults.standard.object(forKey: Self.twoPagesKey) as? Bool ?? true
    }

    var currentPages: [Int] {
        spreads.indices.contains(spreadIndex) ? spreads[spreadIndex] : []
    }

    /// The pages of the current spread in screen order (right to left books put the
    /// earlier page on the right).
    var pagesOnScreen: [Int] {
        direction == .rightToLeft ? currentPages.reversed() : currentPages
    }

    /// The last page showing, 0-based.
    var lastVisiblePage: Int {
        isAtEnd ? max(0, pageCount - 1) : (currentPages.last ?? 0)
    }

    func start(appState: AppState) async {
        self.appState = appState
        guard let client = appState.client else { return }
        state = .loading
        do {
            let pages = try await client.comicPages(fileId: request.fileId)
            let progress = request.startPage == nil ? try? await client.progress(itemId: request.volumeId) : nil
            guard pages.count > 0 else {
                state = .failed(String(localized: "This volume has no pages."))
                return
            }
            direction = pages.readingDirection
            pageCount = pages.count
            sizes = pages.sizes
            var start = request.startPage ?? progress.flatMap { ComicProgress.pageIndex(locator: $0.locator) } ?? 0
            if progress?.finished == true, request.startPage == nil { start = 0 }
            if start >= pages.count { start = 0 }
            layout(keeping: start)
            lastSavedPage = request.startPage == nil ? progress.flatMap { ComicProgress.pageIndex(locator: $0.locator) } : nil
            state = .reading
            loadImagesAround()
        } catch {
            guard let message = appState.message(for: error) else { return }
            state = .failed(message)
        }
    }

    // MARK: Navigation

    /// A left or right press: the reading direction decides which way is forward.
    func move(_ edge: HorizontalEdge) {
        let forward = (edge == .trailing) == (direction == .leftToRight)
        forward ? next() : previous()
    }

    func next() {
        guard state == .reading else { return }
        if spreadIndex + 1 < spreads.count {
            spreadIndex += 1
            pageChanged()
        } else if !isAtEnd {
            isAtEnd = true
            pageChanged()
        }
    }

    func previous() {
        guard state == .reading else { return }
        if isAtEnd {
            isAtEnd = false
        } else if spreadIndex > 0 {
            spreadIndex -= 1
            pageChanged()
        }
    }

    func toggleTwoPages() {
        twoPages.toggle()
        UserDefaults.standard.set(twoPages, forKey: Self.twoPagesKey)
        layout(keeping: currentPages.first ?? 0)
        loadImagesAround()
    }

    /// Writes the reading position now (closing the reader).
    func close() async {
        saveTask?.cancel()
        await save()
    }

    // MARK: Private

    private func layout(keeping page: Int) {
        spreads = ComicSpreads.layout(sizes: sizes, count: pageCount, twoPages: twoPages)
        spreadIndex = ComicSpreads.spreadIndex(containing: page, in: spreads)
    }

    private func pageChanged() {
        loadImagesAround()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        guard state == .reading, let client = appState?.client else { return }
        let page = lastVisiblePage
        guard page != lastSavedPage else { return }
        do {
            try await client.updateProgress(itemId: request.volumeId, ComicProgress.update(pageIndex: page, count: pageCount))
            lastSavedPage = page
        } catch {
            _ = appState?.message(for: error)
        }
    }

    /// Loads the current spread first, then the neighbours (one back, two ahead).
    private func loadImagesAround() {
        let wanted = [spreadIndex, spreadIndex + 1, spreadIndex - 1, spreadIndex + 2]
            .filter { spreads.indices.contains($0) }
            .flatMap { spreads[$0] }
        for page in wanted where images[page] == nil && !loading.contains(page) {
            loadImage(page)
        }
        // Keep memory bounded: drop pages far from the current spread.
        let keep = Set(wanted)
        for page in images.keys where !keep.contains(page) && abs(page - (currentPages.first ?? 0)) > 8 {
            images[page] = nil
        }
    }

    private func loadImage(_ page: Int) {
        guard let client = appState?.client, let url = client.urls.comicPage(fileId: request.fileId, index: page) else { return }
        loading.insert(page)
        failedPages.remove(page)
        Task {
            let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders, maxPixelSize: 2200)
            loading.remove(page)
            if let image {
                images[page] = image
            } else {
                failedPages.insert(page)
            }
        }
    }
}

/// Full-screen comic reader: one page or a two-page spread, turned with left/right
/// presses or swipes (respecting right-to-left manga). Select shows the page bar, Play/Pause
/// switches between one and two pages, Menu closes. The page is saved as you read.
struct ComicReaderView: View {
    let request: ComicReaderRequest

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: ComicReaderModel
    @State private var showsChrome = true
    @State private var chromeTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(request: ComicReaderRequest) {
        self.request = request
        _model = State(initialValue: ComicReaderModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.state {
            case .loading:
                ProgressView()
            case .failed(let message):
                ErrorStateView(message: message) { Task { await model.start(appState: appState) } }
            case .reading:
                reader
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            Task {
                await model.close()
                dismiss()
            }
        }
        .task {
            await model.start(appState: appState)
            focused = true
            flashChrome()
        }
    }

    private var reader: some View {
        ZStack {
            pages
            if model.isAtEnd {
                endCard
            }
            chrome
                .opacity(showsChrome ? 1 : 0)
                .animation(Theme.Motion.easeOut, value: showsChrome)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left: model.move(.leading)
            case .right: model.move(.trailing)
            default: break
            }
        }
        .onTapGesture { flashChrome(toggle: true) }
        .onPlayPauseCommand {
            model.toggleTwoPages()
            flashChrome()
        }
        .defaultFocus($focused, true)
    }

    private var pages: some View {
        HStack(spacing: 0) {
            ForEach(model.pagesOnScreen, id: \.self) { page in
                pageView(page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(nil, value: model.spreadIndex)
    }

    @ViewBuilder
    private func pageView(_ page: Int) -> some View {
        if let image = model.images[page] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: .infinity)
                .accessibilityLabel(Text(verbatim: String(localized: "Page \(page + 1)")))
        } else if model.failedPages.contains(page) {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 60))
                Text(verbatim: String(localized: "Page \(page + 1) couldn’t be loaded."))
                    .font(Theme.Typography.body)
            }
            .foregroundStyle(Theme.Colors.label2)
            .frame(width: 700)
        } else {
            ProgressView()
                .frame(width: 700)
        }
    }

    private var endCard: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 80))
                .foregroundStyle(Theme.Colors.green)
            Text("End of Volume")
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
            Text("Press Menu to close, or go back to the last page.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
        }
        .padding(60)
        .background(Theme.Colors.glassFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
    }

    private var chrome: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: request.title)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.label)
                if !request.subtitle.isEmpty {
                    Text(verbatim: request.subtitle)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                }
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.top, 60)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(verbatim: pageLabel)
                        .font(Theme.Typography.meta.monospacedDigit())
                        .foregroundStyle(Theme.Colors.label)
                    Spacer()
                    Text(model.twoPages ? "Play/Pause: show one page" : "Play/Pause: show two pages")
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(Theme.Colors.label2)
                }
                ProgressBar(value: Double(model.lastVisiblePage + 1) / Double(max(1, model.pageCount)), height: 6)
                    .scaleEffect(x: model.direction == .rightToLeft ? -1 : 1)
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.top, 80)
            .padding(.bottom, 60)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
    }

    private var pageLabel: String {
        let pages = model.currentPages.map { $0 + 1 }
        let shown = pages.count > 1 ? "\(pages[0])–\(pages[1])" : String(pages.first ?? model.pageCount)
        return String(localized: "Page \(shown) of \(model.pageCount)")
    }

    /// Shows the page bar for a few seconds (or toggles it on select).
    private func flashChrome(toggle: Bool = false) {
        chromeTask?.cancel()
        if toggle, showsChrome {
            showsChrome = false
            return
        }
        showsChrome = true
        chromeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            showsChrome = false
        }
    }
}

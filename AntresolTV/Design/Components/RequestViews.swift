import AntresolKit
import SwiftUI

// «Попросить»: what a kid profile has where an adult has «Play» — a search result's card, the
// title page's pill and the state of what was asked.

extension KidRequest.Status {
    /// The words of a request's state.
    var title: String {
        switch self {
        case .pending: String(localized: "Waiting for an answer", bundle: .localized)
        case .approved: String(localized: "Approved — coming soon", bundle: .localized)
        case .declined: String(localized: "A parent said no", bundle: .localized)
        case .inLibrary: String(localized: "Already in the library", bundle: .localized)
        }
    }

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .approved, .inLibrary: "checkmark.circle"
        case .declined: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending: Theme.Colors.label2
        case .approved, .inLibrary: Theme.Colors.green
        case .declined: Theme.Colors.orange
        }
    }
}

extension TitleRef {
    /// A search result of the kid's request search, as the page of a title off the library opens it.
    init(_ candidate: KidCandidate) {
        kind = candidate.kind
        tmdbId = candidate.tmdbId
        title = candidate.title
        year = candidate.year
        poster = candidate.poster
    }

    /// A request of a movie or series, as the page of the title opens it.
    init(_ request: KidRequest) {
        kind = request.kind
        tmdbId = request.tmdbId
        title = request.title
        year = request.year
        poster = request.poster
    }
}

/// A parent's reason for saying no, in the language's quotes.
func requestReasonText(_ reason: String) -> String {
    String(localized: "“\(reason)”", bundle: .localized)
}

/// What a kind of title is called under its name.
func requestKindName(_ kind: String) -> String {
    switch kind {
    case "movie": String(localized: "Movie", bundle: .localized)
    case "series": String(localized: "Show", bundle: .localized)
    case "music": String(localized: "Album", bundle: .localized)
    default: ""
    }
}

/// A title the kid may ask for, as a card: its artwork, name, kind and year, and where its request
/// stands. Use it as the label of a button with `CardButtonStyle`.
struct RequestCandidateCard: View {
    let candidate: KidCandidate

    @Environment(KidRequests.self) private var requests
    @Environment(\.isCardFocused) private var isFocused

    private var shape: ArtworkShape { candidate.isVideo ? .poster : .square }
    private var width: CGFloat { shape.defaultWidth }
    private var request: KidRequest? { requests.book.request(kind: candidate.kind, state: candidate.kidRequest) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardArtwork(
                title: candidate.title, paths: [candidate.isVideo ? candidate.poster : ""],
                maxPixelSize: width * shape.aspectRatio * 2, placeholderAlignment: .bottomLeading
            )
            .overlay(alignment: .topTrailing) {
                if let request {
                    Image(systemName: request.status.symbol)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(12)
                }
            }
            .frame(width: width, height: width * shape.aspectRatio)
            .cardLift(isFocused: isFocused, cornerRadius: Theme.Radius.card)
            // the placeholder's own title is not read twice
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: candidate.title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(1)
                Text(verbatim: [requestKindName(candidate.kind), candidate.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
                if let request {
                    // two lines: «Одобрено — скоро появится» is wider than the card
                    Text(verbatim: request.status.title)
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(request.status.tint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 20)
            .offset(y: isFocused ? 12 : 0)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The pills of a title's page for a kid, in place of Play: «Ask a Parent», or where the request
/// stands (a pill that does nothing but keeps focus on the page, or opens the library's page
/// once the title has come), and the parent's reason after a refusal.
struct RequestActions: View {
    let ask: KidRequestAsk
    let state: RequestState

    @Environment(AppState.self) private var appState
    @Environment(KidRequests.self) private var requests

    private var slot: String { RequestState.slot(kind: ask.kind, key: state.key) }

    var body: some View {
        if let request = requests.book.request(kind: ask.kind, state: state) {
            if request.status == .inLibrary, let itemId = request.libraryItemId {
                NavigationLink(value: Route.item(Card(id: itemId, kind: ItemKind(rawValue: ask.kind), title: ask.title))) {
                    Label(request.status.title, systemImage: request.status.symbol)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            } else {
                Button {} label: {
                    Label(request.status.title, systemImage: request.status.symbol)
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
                .accessibilityIdentifier("request-status")
            }
            if request.status == .declined, !request.reason.isEmpty {
                Text(verbatim: requestReasonText(request.reason))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(2)
                    .frame(maxWidth: 700, alignment: .leading)
            }
        } else if let why = requests.book.blockedReason(kind: ask.kind, state: state) {
            Button {} label: {
                Label("Ask a Parent", systemImage: "paperplane")
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .disabled(true)
            Text(verbatim: why)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.label2)
                .lineLimit(2)
                .frame(maxWidth: 700, alignment: .leading)
        } else {
            Button {
                Task { await requests.ask(ask, slot: slot, using: appState) }
            } label: {
                Label("Ask a Parent", systemImage: "paperplane")
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(requests.asking.contains(slot))
            .accessibilityIdentifier("request-ask")
            if requests.failed.contains(slot) {
                Text("Couldn't send the request. Try again.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
            }
        }
    }
}

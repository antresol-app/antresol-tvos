import AntresolKit
import SwiftUI

/// «My Requests» (a kid profile's settings): what the profile asked a parent for, newest first,
/// and what the parents answered. A request opens the title's page (a movie or show), or the
/// library's own once the title has come.
struct MyRequestsView: View {
    @Environment(AppState.self) private var appState
    @Environment(KidRequests.self) private var requests

    var body: some View {
        let list = requests.book.list
        Group {
            if list.isEmpty, requests.loaded {
                EmptyStateView(
                    systemImage: "paperplane", title: "No requests yet",
                    message: "Find a movie or show in Search and ask for it."
                )
            } else if list.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("My Requests")
                            .font(Theme.Typography.pageTitle)
                            .foregroundStyle(Theme.Colors.label)
                            .padding(.bottom, 24)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(list) { request in
                            RequestRow(request: request)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.margin + Theme.Layout.listRowInset)
                    .padding(.vertical, 80)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { await requests.refresh(using: appState) }
    }
}

/// One request: its artwork, name and kind, and where it stands.
private struct RequestRow: View {
    let request: KidRequest

    var body: some View {
        if let route {
            NavigationLink(value: route) { content }
                .buttonStyle(ListRowButtonStyle())
        } else {
            Button {} label: { content }
                .buttonStyle(ListRowButtonStyle())
        }
    }

    /// The library's page once the title is there, else a movie's or show's own page.
    private var route: Route? {
        if request.hidden { return nil }
        if request.status == .inLibrary, let id = request.libraryItemId {
            return .item(Card(id: id, kind: ItemKind(rawValue: request.kind == "music" ? "album" : request.kind), title: request.title))
        }
        return request.isVideo && request.tmdbId > 0 ? .title(TitleRef(request)) : nil
    }

    private var content: some View {
        RequestRowContent(request: request)
    }
}

private struct RequestRowContent: View {
    let request: KidRequest
    @Environment(\.isCardFocused) private var isFocused

    private var title: String {
        request.hidden ? String(localized: "Not available for this profile", bundle: .localized) : request.title
    }

    var body: some View {
        HStack(spacing: 32) {
            CardArtwork(
                title: title, paths: [request.isVideo && !request.hidden ? request.poster : ""],
                cornerRadius: Theme.Radius.control, maxPixelSize: 300, showsPlaceholderTitle: false
            )
            .frame(width: request.isVideo ? 72 : 108, height: 108)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
                let meta = [requestKindName(request.kind), request.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty, !request.hidden {
                    Text(verbatim: meta)
                        .font(Theme.Typography.cardMeta)
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                Label(request.status.title, systemImage: request.status.symbol)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(isFocused ? Theme.Colors.labelInverse : request.status.tint)
                    .lineLimit(1)
                if request.status == .declined, !request.reason.isEmpty {
                    Text(verbatim: requestReasonText(request.reason))
                        .font(Theme.Typography.cardMeta)
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

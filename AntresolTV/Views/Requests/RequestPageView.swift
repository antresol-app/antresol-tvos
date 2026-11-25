import AntresolKit
import SwiftUI

/// The page of an album a kid found and may ask for: artwork, name, artist, and «Ask a Parent»
/// or where the request stands. (A movie or show opens the title's own page.)
struct RequestPageView: View {
    let candidate: KidCandidate

    @Environment(AppState.self) private var appState
    @Environment(KidRequests.self) private var requests

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            CardArtwork(title: candidate.title, paths: [], maxPixelSize: 800)
                .frame(width: 520, height: 520)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: requestKindName(candidate.kind))
                    .font(Theme.Typography.eyebrow)
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.label2)
                Text(verbatim: candidate.title)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                let line = [candidate.subtitle, candidate.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(verbatim: line)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                if let state = candidate.kidRequest {
                    ActionRow {
                        RequestActions(ask: candidate.ask, state: state)
                    }
                    .padding(.top, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { await requests.load(using: appState) }
    }
}

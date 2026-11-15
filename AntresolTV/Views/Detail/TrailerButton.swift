import AntresolKit
import SwiftUI
import UIKit

/// «Трейлер» on a movie or series page. One trailer opens at once; several open a chooser.
/// A trailer the server can play (`play`) opens in the app's trailer player. On an older
/// server, or with trailers off there, it plays in the YouTube app when it is installed;
/// otherwise a sheet shows the trailer's QR code, to watch it on a phone.
struct TrailerButton: View {
    let trailers: [Trailer]
    /// The movie or series the trailers belong to (the player's backdrop).
    let card: Card

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.openURL) private var openURL
    @State private var choosing = false
    @State private var qrTrailer: Trailer?

    var body: some View {
        Button {
            if trailers.count == 1 {
                open(trailers[0])
            } else {
                choosing = true
            }
        } label: {
            Label("Trailer", systemImage: "play.rectangle")
        }
        .buttonStyle(PillButtonStyle(kind: .glass))
        .confirmationDialog("Trailers", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(trailers) { trailer in
                Button(Self.title(of: trailer)) { open(trailer) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $qrTrailer) { trailer in
            TrailerQRView(trailer: trailer) { qrTrailer = nil }
        }
    }

    private func open(_ trailer: Trailer) {
        if trailer.playsInApp {
            playback.playTrailer(trailer, of: card)
            return
        }
        guard let app = trailer.appURL, UIApplication.shared.canOpenURL(app) else {
            qrTrailer = trailer
            return
        }
        openURL(app) { accepted in
            if !accepted { qrTrailer = trailer }
        }
    }

    /// The trailer's name, else "Trailer" or "Teaser".
    static func name(of trailer: Trailer) -> String {
        guard trailer.name.isEmpty else { return trailer.name }
        return trailer.isTeaser
            ? String(localized: "Teaser", bundle: .localized)
            : String(localized: "Trailer", bundle: .localized)
    }

    /// The trailer's name, else "Trailer" or "Teaser", with its language when known.
    static func title(of trailer: Trailer) -> String {
        let name = name(of: trailer)
        guard !trailer.lang.isEmpty else { return name }
        return "\(name) · \(trailer.lang.uppercased())"
    }
}

/// The trailer as a QR code of its YouTube page, for a phone's camera, with the trailer's
/// name and a Done button (Menu closes it too).
private struct TrailerQRView: View {
    let trailer: Trailer
    let onDone: () -> Void

    /// Smaller than the sign-in code: a phone's camera reads it from the couch all the same.
    private static let qrSize: CGFloat = 440

    var body: some View {
        HStack(alignment: .center, spacing: 96) {
            VStack(alignment: .leading, spacing: 32) {
                Text("Open on Your Phone")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("YouTube isn't installed on this Apple TV. Point your phone's camera at the code to watch the trailer there.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: TrailerButton.title(of: trailer))
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(2)
                Button("Done", action: onDone)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .padding(.top, 12)
            }
            .frame(width: 760, alignment: .leading)

            if let url = trailer.webURL {
                QRCodeView(text: url.absoluteString, size: Self.qrSize)
            }
        }
        // The system sheet sizes its card to this content: keep the code clear of its edges.
        .padding(.horizontal, Theme.Layout.margin)
        .padding(.vertical, 64)
    }
}

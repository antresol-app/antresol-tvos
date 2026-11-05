import AntresolKit
import SwiftUI

/// A song in a track list. Select plays it (the list decides what plays with it); long
/// press offers Play Next, Add to Queue, favourites and the album and artist pages.
struct TrackRow: View {
    enum Leading {
        /// The track number (album pages).
        case number
        /// The cover (artist, playlist and song lists).
        case cover
    }

    let track: Track
    var leading: Leading = .number
    var showsArtist = false
    var showsAlbumLink = true
    let action: () -> Void

    @Environment(AudioPlayer.self) private var audio
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        let starred = audio.isStarred(track)
        Button(action: action) {
            TrackRowLabel(
                track: track,
                leading: leading,
                showsArtist: showsArtist,
                isStarred: starred,
                isCurrent: audio.currentTrack?.id == track.id
            )
        }
        .buttonStyle(ListRowButtonStyle())
        .contextMenu {
            Button {
                audio.playNext([track])
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                audio.addToQueue([track])
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            Button {
                audio.toggleStar(track)
            } label: {
                Label(starred ? "Remove from Favorites" : "Add to Favorites", systemImage: starred ? "star.slash" : "star")
            }
            if showsAlbumLink, track.albumId > 0 {
                Button {
                    openRoute(.item(Card(id: track.albumId, kind: .album, title: track.album, subtitle: track.artist, poster: track.cover)))
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            if track.artistId > 0 {
                Button {
                    openRoute(.item(Card(id: track.artistId, kind: .artist, title: track.artist, poster: track.cover)))
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
        }
    }
}

private struct TrackRowLabel: View {
    let track: Track
    let leading: TrackRow.Leading
    let showsArtist: Bool
    let isStarred: Bool
    let isCurrent: Bool

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        HStack(spacing: 28) {
            leadingView
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: track.title)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
                if showsArtist, !secondary.isEmpty {
                    Text(verbatim: secondary)
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 20)
            if isStarred {
                Image(systemName: "star.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.orange)
                    .accessibilityLabel(Text("Favorite"))
            }
            if track.durationMs > 0 {
                Text(verbatim: PlaybackTime.clock(Double(track.durationMs) / 1000))
                    .font(Theme.Typography.meta.monospacedDigit())
                    .foregroundStyle(secondaryColor)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .number:
            ZStack {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.accent)
                        .symbolEffect(.variableColor.iterative, isActive: !isFocused)
                        .accessibilityLabel(Text("Now Playing"))
                } else {
                    Text(verbatim: track.trackNo > 0 ? String(track.trackNo) : "")
                        .font(Theme.Typography.meta.monospacedDigit())
                        .foregroundStyle(secondaryColor)
                }
            }
            .frame(width: 52, alignment: .trailing)
        case .cover:
            CardArtwork(title: track.album.isEmpty ? track.title : track.album, paths: [track.cover], cornerRadius: 8, maxPixelSize: 140, showsPlaceholderTitle: false)
                .frame(width: 64, height: 64)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.5))
                        Image(systemName: "waveform")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .accessibilityLabel(Text("Now Playing"))
                    }
                }
        }
    }

    private var secondary: String {
        metaLine([track.artist, leading == .cover ? track.album : ""])
    }

    private var secondaryColor: Color {
        isFocused ? Theme.Colors.labelInverse.opacity(0.65) : Theme.Colors.label2
    }
}

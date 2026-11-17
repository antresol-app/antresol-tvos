import AntresolKit
import SwiftUI

/// A programme opened from the guide: its still behind the page, the channel, when it is
/// on, the title, episode, overview, genres and rating; «Смотреть» while it is on air, and
/// the channel's star.
struct ProgramDetailView: View {
    let details: ProgramDetails
    let model: TVModel

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.locale) private var locale

    private var program: ChannelProgram { details.program }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let now = context.date
            let onAir = program.isOnAir(at: now)
            ZStack(alignment: .bottomLeading) {
                ProgramBackdrop(program: program)
                VStack(alignment: .leading, spacing: 22) {
                    if let channel = model.channel(details.channelId) {
                        HStack(spacing: 20) {
                            ChannelLogo(path: channel.logoUrl, height: 48)
                            Text(verbatim: channel.label)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.label2)
                            if onAir { LiveBadge() }
                        }
                    }
                    Text(verbatim: program.title)
                        .font(Theme.Typography.heroTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if !program.subtitle.isEmpty {
                        Text(verbatim: program.subtitle)
                            .font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Colors.label)
                            .lineLimit(1)
                    }
                    HStack(spacing: 20) {
                        Text(verbatim: "\(program.start.dayName(locale, now: now)), \(program.timeRange(locale))")
                            .monospacedDigit()
                        if !program.metaLine.isEmpty {
                            Text(verbatim: "·")
                            Text(verbatim: program.metaLine)
                        }
                    }
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
                    if onAir {
                        HStack(spacing: 18) {
                            LiveProgressBar(value: program.progress(at: now), height: 6)
                                .frame(width: 420)
                            Text(verbatim: program.untilLine(locale))
                                .font(Theme.Typography.meta)
                                .monospacedDigit()
                                .foregroundStyle(Theme.Colors.label3)
                        }
                    }
                    if !program.overview.isEmpty {
                        Text(verbatim: program.overview)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.label2)
                            .lineLimit(4)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                    actions(onAir: onAir, now: now)
                        .padding(.top, 18)
                }
                .padding(.horizontal, Theme.Layout.margin)
                .padding(.bottom, 110)
            }
        }
        .ignoresSafeArea()
    }

    private func actions(onAir: Bool, now: Date) -> some View {
        GlassGroup(spacing: 28) {
            HStack(spacing: 28) {
                if onAir, let channel = model.channel(details.channelId) {
                    Button {
                        playback.watch(channel, channels: model.list.channels, filter: model.activeFilter)
                    } label: {
                        Label("Watch", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                } else if program.end <= now {
                    Label {
                        Text(verbatim: String(localized: "Ended at \(program.end.clock(locale))", bundle: .localized))
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(Theme.Typography.button)
                    .foregroundStyle(Theme.Colors.label3)
                    .padding(.trailing, 12)
                } else if program.start > now {
                    Label {
                        Text(verbatim: String(localized: "Starts at \(program.start.clock(locale))", bundle: .localized))
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(Theme.Typography.button)
                    .foregroundStyle(Theme.Colors.label2)
                    .padding(.trailing, 12)
                }
                let favorite = model.isFavorite(details.channelId)
                Button {
                    Task { await model.toggleFavorite(details.channelId) }
                } label: {
                    Label(favorite ? "In Favourites" : "Add to Favourites", systemImage: favorite ? "star.fill" : "star")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
            }
        }
        .focusSection()
    }
}

/// The programme's still across the top of the page, fading into black, with a darker
/// left side under the text (the detail pages' look).
private struct ProgramBackdrop: View {
    let program: ChannelProgram

    var body: some View {
        ZStack {
            Theme.Colors.background
            if !program.still.isEmpty {
                RemoteImage(path: program.still, maxPixelSize: ArtworkPixels.screenWidth, minPixelSize: ArtworkPixels.screenWidth)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 260, weight: .ultraLight))
                    .foregroundStyle(Theme.Colors.fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 140)
                    .padding(.trailing, 220)
            }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.8, y: 0.5))
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

import AntresolKit
import SwiftUI

/// The TV tab's "Continue" card: the channel the profile watched last, as wide as the
/// page, with the programme's backdrop, the logo, "10 · Comedies" and Live, what is on with
/// its progress and what is next. Selecting it resumes the channel live. Use it as the label
/// of a button with `CardButtonStyle`.
struct ContinueChannelCard: View {
    let channel: Channel
    var width: CGFloat = Theme.Layout.contentWidth

    static let height: CGFloat = 500

    @Environment(\.isCardFocused) private var isFocused
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let program = channel.program(at: context.date)
            ZStack(alignment: .bottomLeading) {
                Theme.Gradients.avatar(channel.logoPreset)
                if let backdrop = program?.backdrop, !backdrop.isEmpty {
                    RemoteImage(path: backdrop, maxPixelSize: width * 1.5)
                }
                // The text sits on the left; the picture stays clear on the right.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.85), location: 0),
                        .init(color: .black.opacity(0.55), location: 0.45),
                        .init(color: .clear, location: 0.8),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                Theme.Gradients.scrim

                details(program, at: context.date)
                    .padding(.horizontal, 60)
                    .padding(.vertical, 52)
            }
            .frame(width: width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .cardLift(isFocused: isFocused)
        }
        .accessibilityElement(children: .combine)
    }

    private func details(_ program: ChannelProgram?, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ChannelLogo(channel, cornerRadius: Theme.Radius.control)
                .frame(width: 208, height: 117)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                .padding(.bottom, 16)
            HStack(spacing: 18) {
                Text(verbatim: channel.label)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(1)
                LiveBadge()
            }
            Text(verbatim: program?.title ?? String(localized: "Nothing on now", bundle: .localized))
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let program {
                if !program.subtitle.isEmpty {
                    Text(verbatim: program.subtitle)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                HStack(spacing: 24) {
                    ProgressBar(value: program.progress(at: date), height: 8)
                        .frame(width: 420)
                    Text(verbatim: program.timeRange(locale))
                        .font(Theme.Typography.meta)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.label2)
                }
                .padding(.top, 6)
            }
            if let next = channel.upNext(at: date) {
                Text(verbatim: next.nextLine(locale))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 1040, alignment: .leading)
    }
}

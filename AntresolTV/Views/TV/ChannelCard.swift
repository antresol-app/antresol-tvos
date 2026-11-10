import AntresolKit
import SwiftUI

/// A channel's logo: its name in bold white on the channel's gradient (the avatar
/// gradients, 145°). The server has no logo images; this is drawn the same everywhere.
struct ChannelLogo: View {
    let channel: Channel
    var cornerRadius: CGFloat = Theme.Radius.card

    var body: some View {
        GeometryReader { proxy in
            Text(verbatim: channel.name)
                .font(.system(size: max(14, proxy.size.height * 0.2), weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.25), radius: 4)
                .padding(.horizontal, proxy.size.width * 0.08)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Theme.Gradients.avatar(channel.logoPreset))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A 16:9 channel lockup: the programme's backdrop (else the logo filling the card) with
/// the logo in the corner and a live progress bar, then "10 · Comedies" and what is on.
/// Use it as the label of a button with `CardButtonStyle`, like `WideCard`.
struct ChannelCard: View {
    let channel: Channel
    var width: CGFloat = Theme.Layout.wideWidth

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        // The progress and the programme itself move on between list refreshes.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let program = channel.program(at: context.date)
            VStack(alignment: .leading, spacing: 0) {
                artwork(program, at: context.date)
                    .frame(width: width, height: width * 9 / 16)
                    .cardLift(isFocused: isFocused)

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: channel.label)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(1)
                    Text(verbatim: program?.fullTitle ?? String(localized: "Nothing on now", bundle: .localized))
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                .padding(.top, 20)
                .offset(y: isFocused ? 12 : 0)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func artwork(_ program: ChannelProgram?, at date: Date) -> some View {
        let backdrop = program?.backdrop ?? ""
        return ZStack(alignment: .topLeading) {
            ChannelLogo(channel, cornerRadius: 0)
            if !backdrop.isEmpty {
                RemoteImage(path: backdrop, maxPixelSize: width * 2)
                ChannelLogo(channel, cornerRadius: Theme.Radius.badge)
                    .frame(width: width * 0.26, height: width * 0.26 * 9 / 16)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    .padding(18)
            }
        }
        .overlay {
            if let program {
                ZStack(alignment: .bottom) {
                    Theme.Gradients.scrim
                    ProgressBar(value: program.progress(at: date))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

extension ChannelLogo {
    init(_ channel: Channel, cornerRadius: CGFloat = Theme.Radius.card) {
        self.init(channel: channel, cornerRadius: cornerRadius)
    }
}

extension Channel {
    /// "10 · Comedies".
    var label: String {
        "\(number) · \(name)"
    }
}

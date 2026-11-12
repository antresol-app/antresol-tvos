import AntresolKit
import SwiftUI

/// A programme's picture: its backdrop, else its poster, else a neutral fill with the
/// `tv` glyph. This is what stands for a channel everywhere; an uploaded logo
/// (`ChannelLogo`) only sits beside its number and name.
struct ProgrammeStill: View {
    let program: ChannelProgram?
    var maxPixelSize: CGFloat = 600
    var cornerRadius: CGFloat = Theme.Radius.card

    var body: some View {
        let still = program?.still ?? ""
        ZStack {
            StillPlaceholder()
            if !still.isEmpty {
                RemoteImage(path: still, maxPixelSize: maxPixelSize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A channel's uploaded logo, small, in a neutral rounded 3:2 box beside its number and
/// name. Nothing at all for a channel without one (no generated tile). Decorative for
/// VoiceOver: the name is read.
struct ChannelLogo: View {
    let path: String
    var height: CGFloat = 40

    var body: some View {
        if !path.isEmpty {
            let shape = RoundedRectangle(cornerRadius: height / 5, style: .continuous)
            RemoteImage(path: path, maxPixelSize: height * 3, fit: true)
                .padding(height / 8)
                .frame(width: height * 1.5, height: height)
                .background(Theme.Colors.elevated, in: shape)
                .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

/// The neutral picture of a programme without artwork (system fill, `tv` glyph).
struct StillPlaceholder: View {
    var body: some View {
        GeometryReader { proxy in
            Theme.Colors.elevated
                .overlay {
                    Image(systemName: "tv")
                        .font(.system(size: max(18, proxy.size.height * 0.28), weight: .regular))
                        .foregroundStyle(Theme.Colors.label3)
                }
        }
    }
}

/// "LIVE" with a red dot, quiet: no capsule, it sits beside the channel's name.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.Colors.red)
                .frame(width: 12, height: 12)
            Text("Live")
                .font(Theme.Typography.eyebrow)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.label2)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Channel {
    /// "10 · Comedies".
    var label: String {
        "\(number) · \(name)"
    }
}

extension ChannelProgram {
    /// "23:00–23:30".
    func timeRange(_ locale: Locale) -> String {
        "\(start.clock(locale))–\(end.clock(locale))"
    }

    /// «до 21:40» / "until 9:40 PM".
    func untilLine(_ locale: Locale) -> String {
        String(localized: "until \(end.clock(locale))", bundle: .localized)
    }

    /// «Далее 21:40 Название» / "Next 9:40 PM Title".
    func nextLine(_ locale: Locale) -> String {
        String(localized: "Next \(start.clock(locale)) \(fullTitle)", bundle: .localized)
    }

    /// "1993 · comedy, adventure · 12+".
    var metaLine: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        if !rating.isEmpty { parts.append(rating) }
        return parts.joined(separator: " · ")
    }
}

extension Date {
    /// The time of day in the app's locale ("23:30", "11:30 PM"), rounded to the nearest
    /// minute: programme times carry seconds (23:50:38 is «23:51», where its block sits),
    /// and truncating would label a block up to a minute before where it is drawn.
    func clock(_ locale: Locale) -> String {
        roundedToMinute.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    /// The nearest whole minute.
    var roundedToMinute: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// «Сегодня», «Завтра», «Вчера» or the date, in the app's locale.
    func dayName(_ locale: Locale, now: Date = Date()) -> String {
        var calendar = Calendar.current
        calendar.locale = locale
        if calendar.isDate(self, inSameDayAs: now) { return String(localized: "Today", bundle: .localized) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(self, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow", bundle: .localized)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", bundle: .localized)
        }
        return formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }
}

extension ChannelFilter {
    /// The filter's name in the pill.
    var title: String {
        switch self {
        case .all: return String(localized: "All", bundle: .localized)
        case .favorites: return String(localized: "Favourites", bundle: .localized)
        case .category(let name): return name
        }
    }
}

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

/// A channel's logo, small, in a neutral rounded 3:2 box beside its number and name: the
/// uploaded or found logo (`logoUrl`), else the guide's icon (`logoAlt`, also when the first
/// does not load), else the channel's initials. With `initials` off (the banner, a card
/// beside the name) a channel without any logo has no box at all; in a list row it has its
/// initials, so the rows' names stay in one column. Decorative for VoiceOver: the name is read.
struct ChannelLogo: View {
    let paths: [String]
    let monogram: String
    var height: CGFloat = 40
    var initials = false

    @State private var loaded = false

    init(_ channel: Channel, height: CGFloat = 40, initials: Bool = false) {
        paths = channel.logoCandidates
        monogram = channel.initials
        self.height = height
        self.initials = initials
    }

    var body: some View {
        if !paths.isEmpty || initials {
            let shape = RoundedRectangle(cornerRadius: height / 5, style: .continuous)
            ZStack {
                if !loaded {
                    Text(verbatim: monogram)
                        .font(.system(size: height * 0.42, weight: .bold))
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, height / 8)
                }
                if let first = paths.first {
                    RemoteImage(path: first, fallbacks: Array(paths.dropFirst()), maxPixelSize: height * 3, fit: true, onLoad: { _ in loaded = true })
                    .padding(height / 8)
                }
            }
            .frame(width: height * 1.5, height: height)
            .background(Theme.Colors.elevated, in: shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .accessibilityHidden(true)
            .onChange(of: paths) { loaded = false }
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

/// Behind the live edge (a pause): «В эфир», the way back (the options row's first
/// button and Play/Pause take it).
struct GoLiveBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 18, weight: .semibold))
            Text("Go Live")
                .font(Theme.Typography.eyebrow)
                .tracking(1.5)
                .textCase(.uppercase)
        }
        .foregroundStyle(Theme.Colors.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.Colors.label.opacity(0.18), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live.behind")
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
    /// What the filter is called: «Все каналы», «Избранное», a category by its name (the
    /// server's `categories`, else a group's own name) or «Без категории».
    func title(in categories: [ChannelCategory]) -> String {
        switch self {
        case .all: return String(localized: "All Channels", bundle: .localized)
        case .favorites: return String(localized: "Favourites", bundle: .localized)
        case .category: return categoryName(in: categories) ?? String(localized: "No category", bundle: .localized)
        }
    }
}

extension ChannelCategory {
    /// The heading of a kind of category in the list: «Темы», «Источники», «Группы».
    static func kindTitle(_ kind: String?) -> String? {
        switch kind {
        case kindAI: return String(localized: "Topics", bundle: .localized)
        case kindSource: return String(localized: "Sources", bundle: .localized)
        case kindGroup: return String(localized: "Groups", bundle: .localized)
        default: return nil
        }
    }
}

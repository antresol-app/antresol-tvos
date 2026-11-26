import AntresolKit
import SwiftUI

// «Family»: where the other profiles are in a title. The kit says what each place is made of
// (`FamilyPlace`, `FamilyJump`, `FamilyWhen`); the words are here, from the catalogs.

enum FamilyText {
    /// «S1 E2» / «С1 Э2», «Special 3».
    static func code(_ code: FamilyCode) -> String {
        code.isSpecial
            ? String(localized: "Special \(code.episode)", bundle: .localized)
            : String(localized: "S\(code.season) E\(code.episode)", bundle: .localized)
    }

    /// «34 min», «1 h 50 min».
    static func minutes(_ minutes: Int) -> String {
        VideoDetailView.duration(minutes: minutes)
    }

    /// «S1 E2 · 17 min», «34 min of 1 h 50 min», «Up next: S1 E2», «Watched».
    static func place(_ place: FamilyPlace) -> String {
        switch place {
        case .watched:
            return String(localized: "Watched", bundle: .localized)
        case .allWatched:
            return String(localized: "All watched", bundle: .localized)
        case .upNext(let next):
            return String(localized: "Up next: \(code(next))", bundle: .localized)
        case .episode(let at, let inMinutes):
            return inMinutes > 0 ? "\(code(at)) · \(minutes(inMinutes))" : code(at)
        case .time(let positionMinutes, let clock, let durationMinutes):
            let time = positionMinutes > 0 ? minutes(positionMinutes) : clock
            return durationMinutes > 0 ? String(localized: "\(time) of \(minutes(durationMinutes))", bundle: .localized) : time
        }
    }

    /// The jump's words: «Continue from Their Place» (the place itself is on the row's line), «Play S1 E3» for an
    /// episode nobody has started; "" for none.
    static func jump(_ jump: FamilyJump) -> String {
        switch jump {
        case .none: return ""
        case .watchEpisode(let at): return String(localized: "Play \(code(at))", bundle: .localized)
        case .watchEpisodeAt, .watchAt: return String(localized: "Continue from Their Place", bundle: .localized)
        }
    }

    /// «just now», «2 hr ago», «yesterday», «12 November».
    static func when(_ when: FamilyWhen) -> String {
        switch when {
        case .now: return String(localized: "just now", bundle: .localized)
        case .minutes(let n): return String(localized: "\(n) min ago", bundle: .localized)
        case .hours(let n): return String(localized: "\(n) hr ago", bundle: .localized)
        case .yesterday: return String(localized: "yesterday", bundle: .localized)
        case .date(let date):
            let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.stored.locale
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "d MMMM" : "d MMMM y")
            return formatter.string(from: date)
        }
    }

    /// «ещё 2», «2 more».
    static func more(_ count: Int) -> String {
        String(localized: "\(count) more", bundle: .localized)
    }

    /// «Alex · S1 E2 · 17 min».
    static func summary(_ line: FamilyLine) -> String {
        let at = FamilyText.place(line.place)
        return at.isEmpty ? line.first.name : "\(line.first.name) · \(at)"
    }

    /// A row of the resume prompt: «Alex · 1:12:40», and in another episode than the one about to play
    /// «Alex · S1 E5 · 12:40» (its title when the server did not number it).
    static func promptRow(_ member: FamilyMember, playing itemId: Int) -> String {
        var parts = [member.listName]
        if member.itemId != itemId {
            if member.season != nil || member.episode != nil {
                parts.append(code(member.code))
            } else if !member.title.isEmpty {
                parts.append(member.title)
            }
        }
        parts.append(PlaybackTime.clock(Double(member.positionMs) / 1000))
        return parts.joined(separator: " · ")
    }

    /// «34 min of 1 h 50 min · 2 hr ago».
    static func placeAndWhen(_ member: FamilyMember, kind: FamilyKind) -> String {
        var parts = [place(member.place(kind))]
        if let when = FamilyWhen.since(member.updatedAt) { parts.append(Self.when(when)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A profile's avatar inside its progress ring: a series' share done (the item's own for a film),
/// green with a check when it is done.
struct FamilyAvatar: View {
    let member: FamilyMember
    var size: CGFloat = 56

    @Environment(\.isCardFocused) private var isFocused

    private var stroke: CGFloat { size >= 64 ? 4.5 : 3.5 }
    private var box: CGFloat { size + 2 * (stroke + 4) }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: stroke / 2)
                .stroke(isFocused ? Color.black.opacity(0.15) : Theme.Colors.fill, lineWidth: stroke)
            if member.ring > 0 {
                Circle()
                    .inset(by: stroke / 2)
                    .trim(from: 0, to: member.ring)
                    .stroke(arc, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            AvatarView(name: member.name, preset: member.avatarPreset, photo: member.photo, size: size)
        }
        .frame(width: box, height: box)
        .overlay(alignment: .bottomTrailing) {
            if member.finished {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.2, weight: .heavy))
                    .foregroundStyle(Theme.Colors.labelInverse)
                    .frame(width: size * 0.4, height: size * 0.4)
                    .background(Theme.Colors.green, in: Circle())
                    .overlay(Circle().strokeBorder(isFocused ? Color.white : Theme.Colors.background, lineWidth: 2.5))
            }
        }
        .accessibilityHidden(true)
    }

    private var arc: Color {
        if member.finished { return Theme.Colors.green }
        return isFocused ? Theme.Colors.labelInverse : Theme.Colors.label
    }
}

/// The folded line under a title's actions: the faces in their rings, «Family» and who is where.
/// The label of a button with `FamilyLineButtonStyle`.
struct FamilyLineLabel: View {
    let line: FamilyLine

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        HStack(spacing: 24) {
            HStack(spacing: -18) {
                ForEach(line.shown) { member in
                    FamilyAvatar(member: member, size: 56)
                }
            }
            if line.hiddenFaces > 0 {
                Text(verbatim: "+\(line.hiddenFaces)")
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label2)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(isFocused ? Color.black.opacity(0.1) : Theme.Colors.fill, in: Capsule())
                    .padding(.leading, 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Family")
                    .font(Theme.Typography.eyebrow)
                    .tracking(2)
                    .textCase(.uppercase)
                    .opacity(0.6)
                HStack(spacing: 10) {
                    Text(verbatim: FamilyText.summary(line))
                        .lineLimit(1)
                    if line.more > 0 {
                        Text(verbatim: "· \(FamilyText.more(line.more))")
                            .opacity(0.6)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(Theme.Typography.meta)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .bold))
                .opacity(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Family"))
        .accessibilityValue(Text(verbatim: FamilyText.summary(line) + (line.more > 0 ? ", " + FamilyText.more(line.more) : "")))
    }
}

/// The folded line's button: quiet at rest, a lit glass capsule when focused.
struct FamilyLineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FamilyLineButtonBody(configuration: configuration)
    }
}

private struct FamilyLineButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .environment(\.isCardFocused, isFocused)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label2)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background {
                if isFocused { Color.clear.glassSurface(in: Capsule(), highlighted: true) }
            }
            .scaleEffect(configuration.isPressed ? Theme.Motion.Press.control : (isFocused ? Theme.Motion.Focus.card : 1))
            .focusShadow(Theme.Shadow.pill, isFocused: isFocused)
            .animation(Theme.Motion.easeOut, value: isFocused)
            .animation(Theme.Motion.easeOut, value: configuration.isPressed)
            // the faces start at the page's edge; only the focus plate reaches beyond it
            .padding(.horizontal, -22)
    }
}

/// Who of the family is on an episode: small faces on its tile.
struct FamilyFaces: View {
    let members: [FamilyMember]

    var body: some View {
        if !members.isEmpty {
            HStack(spacing: -10) {
                ForEach(members.prefix(3)) { member in
                    AvatarView(name: member.name, preset: member.avatarPreset, photo: member.photo, size: 40)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 2))
                }
            }
            .padding(12)
            .accessibilityHidden(true)
        }
    }
}

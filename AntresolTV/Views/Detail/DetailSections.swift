import AntresolKit
import SwiftUI

/// The cast as a row of initials avatars (the API has no portraits) with the name and
/// character. Cells are focusable so the row can be scrolled with the remote.
struct CastRow: View {
    let cast: [CastMember]

    var body: some View {
        ShelfRow(title: String(localized: "Cast"), items: entries, id: \.index) { entry in
            CastCell(member: entry.member)
                .focusable()
        }
    }

    /// Names can repeat (one actor, two roles), so cells are keyed by position.
    private struct Entry {
        let index: Int
        let member: CastMember
    }

    private var entries: [Entry] {
        cast.enumerated().map { Entry(index: $0.offset, member: $0.element) }
    }
}

private struct CastCell: View {
    let member: CastMember
    @Environment(\.isFocused) private var isFocused

    private let size: CGFloat = 150

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.Gradients.placeholder(seed: member.name))
                Text(verbatim: initials)
                    .font(Theme.Typography.avatarInitial(size: size * 0.8))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .cardLift(isFocused: isFocused, cornerRadius: size / 2)
            .animation(Theme.Motion.easeOut, value: isFocused)
            VStack(spacing: 4) {
                Text(verbatim: member.name)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.label)
                if let character = member.character, !character.isEmpty {
                    Text(verbatim: character)
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(Theme.Colors.label2)
                }
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
        }
        .frame(width: 210)
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        let letters = member.name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// The About panel at the bottom of a detail page: full overview and facts about the
/// item and its files (versions, audio and subtitle tracks). It takes focus as one block
/// so the page can scroll down to it.
struct AboutPanel: View {
    let detail: ItemDetail
    @FocusState private var isFocused: Bool

    var body: some View {
        if !facts.isEmpty || !detail.overview.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                Text("About")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .top, spacing: 64) {
                    if !detail.overview.isEmpty {
                        Text(verbatim: detail.overview)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.label)
                            .frame(maxWidth: 820, alignment: .leading)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 32, verticalSpacing: 16) {
                        ForEach(facts, id: \.label) { fact in
                            GridRow {
                                Text(verbatim: fact.label)
                                    .font(Theme.Typography.cardMeta.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.label3)
                                    .textCase(.uppercase)
                                Text(verbatim: fact.value)
                                    .font(Theme.Typography.cardMeta)
                                    .foregroundStyle(Theme.Colors.label2)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                        .fill(isFocused ? Theme.Colors.elevated : Theme.Colors.raised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                        .strokeBorder(.white.opacity(isFocused ? 0.35 : 0.06), lineWidth: isFocused ? 2 : 1)
                )
                .focusable()
                .focused($isFocused)
                .animation(Theme.Motion.easeOut, value: isFocused)
            }
            .padding(.horizontal, Theme.Layout.margin)
        }
    }

    private struct Fact {
        let label: String
        let value: String
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let original = detail.originalTitle, !original.isEmpty, original != detail.title {
            facts.append(Fact(label: String(localized: "Original Title"), value: original))
        }
        if !detail.genres.isEmpty {
            facts.append(Fact(label: String(localized: "Genres"), value: detail.genres.joined(separator: ", ")))
        }
        if let rating = detail.rating, !rating.isEmpty {
            facts.append(Fact(label: String(localized: "Rating"), value: rating))
        }
        if detail.files.count > 1 {
            let versions = detail.files.map { file in
                [file.resolution, file.name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            }
            facts.append(Fact(label: String(localized: "Versions"), value: versions.joined(separator: "\n")))
        }
        if let file = detail.primaryFile {
            if let resolution = file.resolution, !resolution.isEmpty, detail.files.count == 1 {
                facts.append(Fact(label: String(localized: "Video"), value: resolution))
            }
            let audio = file.audio.map(Self.describe)
            if !audio.isEmpty {
                facts.append(Fact(label: String(localized: "Audio"), value: audio.joined(separator: ", ")))
            }
            let subtitles = file.subs.map(Self.describe)
            if !subtitles.isEmpty {
                facts.append(Fact(label: String(localized: "Subtitles"), value: subtitles.joined(separator: ", ")))
            }
            if detail.files.count == 1 {
                let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
                facts.append(Fact(label: String(localized: "File"), value: file.size > 0 ? "\(file.name) · \(size)" : file.name))
            }
        }
        return facts
    }

    private static func describe(_ track: AudioTrack) -> String {
        if !track.title.isEmpty { return track.title }
        return [languageName(track.language), track.codec.uppercased()]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func describe(_ track: SubtitleTrack) -> String {
        var text = track.title.isEmpty ? (languageName(track.language) ?? track.codec.uppercased()) : track.title
        if track.forced { text += " (" + String(localized: "Forced") + ")" }
        return text
    }

    /// "English" for "eng" or "en", in the interface language.
    private static func languageName(_ code: String?) -> String? {
        guard let code else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

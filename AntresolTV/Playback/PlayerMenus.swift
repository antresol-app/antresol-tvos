import AntresolKit
import SwiftUI
import UIKit

/// The Audio, Subtitles, Quality and «Пропускать сам» menus of the player's transport bar.
@MainActor
enum PlayerMenus {
    static func make(_ state: PlayerMenuState, model: VideoPlayerModel) -> [UIMenuElement] {
        var menus: [UIMenuElement] = []
        let cleaned = CleanedSwitch(audio: state.audio, audioIndex: state.audioIndex)
        if cleaned.rows.count > 1 || cleaned.toggle != nil {
            menus.append(audioMenu(cleaned, model: model))
        }
        if !state.subtitles.isEmpty {
            menus.append(subtitleMenu(state, model: model))
        }
        menus.append(qualityMenu(state, model: model))
        if let autoSkip = state.autoSkip {
            menus.append(autoSkipMenu(autoSkip, model: model))
        }
        if !state.family.isEmpty {
            menus.append(familyMenu(state, model: model))
        }
        return menus
    }

    /// «Family»: where the other profiles are in what plays; a row takes the player there, and
    /// «Back to 12:40» (while the place before it is the one saved) returns.
    private static func familyMenu(_ state: PlayerMenuState, model: VideoPlayerModel) -> UIMenu {
        var children: [UIMenuElement] = []
        if let back = state.familyReturn {
            let action = UIAction(title: String(localized: "Back to \(back)", bundle: .localized), image: UIImage(systemName: "arrow.uturn.backward")) { [weak model] _ in
                MainActor.assumeIsolated { model?.returnFromFamily() }
            }
            children.append(UIMenu(options: .displayInline, children: [action]))
        }
        let rows: [UIMenuElement] = state.family.map { member in
            let clock = PlaybackTime.clock(Double(member.positionMs) / 1000)
            let action = UIAction(title: member.listName, image: avatar(of: member)) { [weak model] _ in
                MainActor.assumeIsolated { model?.peek(at: member) }
            }
            action.subtitle = [clock, FamilyWhen.since(member.updatedAt).map(FamilyText.when)].compactMap { $0 }.joined(separator: " · ")
            return action
        }
        children.append(UIMenu(options: .displayInline, children: rows))
        return UIMenu(title: String(localized: "Family", bundle: .localized), image: UIImage(systemName: "person.2"), children: children)
    }

    /// The profile's avatar (its gradient and initial) for a menu row.
    private static func avatar(of member: FamilyMember) -> UIImage? {
        let renderer = ImageRenderer(content: AvatarView(name: member.name, preset: member.avatarPreset, size: 44))
        renderer.scale = 2
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }

    /// «Пропускать сам»: each row turns its kind on or off (the profile's, on every device).
    private static func autoSkipMenu(_ autoSkip: AutoSkip, model: VideoPlayerModel) -> UIMenu {
        let rows: [(String, String)] = [
            (SkipSegments.recap, String(localized: "Recap", bundle: .localized)),
            (SkipSegments.intro, String(localized: "Intro", bundle: .localized)),
            (SkipSegments.credits, String(localized: "Credits", bundle: .localized)),
        ]
        let actions = rows.map { kind, title in
            let on = autoSkip.isOn(kind)
            return UIAction(title: title, state: on ? .on : .off) { [weak model] _ in
                model?.setAutoSkip(kind, !on)
            }
        }
        return UIMenu(
            title: String(localized: "Skip Automatically", bundle: .localized),
            image: UIImage(systemName: "forward.end"),
            children: actions
        )
    }

    /// The voices, a cleaned one not a row of its own: «Clean voice-over»
    /// under them turns it on for the chosen voice (CleanedSwitch).
    private static func audioMenu(_ cleaned: CleanedSwitch, model: VideoPlayerModel) -> UIMenu {
        let actions: [UIMenuElement] = cleaned.rows.map { row in
            let label = TrackLabels.menuLabel(row.track)
            let action = UIAction(title: label.title, state: row.checked ? .on : .off) { [weak model] _ in
                model?.selectAudio(row.plays)
            }
            if !label.detail.isEmpty { action.subtitle = label.detail }
            return action
        }
        var children: [UIMenuElement] = [UIMenu(options: [.displayInline, .singleSelection], children: actions)]
        if let toggle = cleaned.toggle {
            let sw = UIAction(title: String(localized: "Clean voice-over", bundle: .localized), state: toggle.on ? .on : .off) { [weak model] _ in
                model?.selectAudio(toggle.target)
            }
            sw.subtitle = String(localized: "Without the original speech under it", bundle: .localized)
            children.append(UIMenu(options: .displayInline, children: [sw]))
        }
        return UIMenu(
            title: String(localized: "Audio", bundle: .localized),
            image: UIImage(systemName: "speaker.wave.2"),
            children: children
        )
    }

    private static func subtitleMenu(_ state: PlayerMenuState, model: VideoPlayerModel) -> UIMenu {
        var actions = [
            UIAction(title: String(localized: "Off", bundle: .localized), state: state.subtitleIndex == nil ? .on : .off) { [weak model] _ in
                model?.selectSubtitle(nil)
            },
        ]
        for track in state.subtitles {
            var title = TrackLabels.describe(track)
            if track.burnIn { title += " · " + String(localized: "Burned In", bundle: .localized) }
            actions.append(UIAction(title: title, state: track.index == state.subtitleIndex ? .on : .off) { [weak model] _ in
                model?.selectSubtitle(track.index)
            })
        }
        return UIMenu(
            title: String(localized: "Subtitles", bundle: .localized),
            image: UIImage(systemName: "captions.bubble"),
            options: .singleSelection,
            children: actions
        )
    }

    private static func qualityMenu(_ state: PlayerMenuState, model: VideoPlayerModel) -> UIMenu {
        let actions = VideoQuality.allCases.map { quality in
            var title = quality.displayName
            if quality == .auto, state.quality == .auto, let applied = appliedName(state.appliedQuality) {
                title += " (\(applied))"
            }
            return UIAction(title: title, state: quality == state.quality ? .on : .off) { [weak model] _ in
                model?.selectQuality(quality)
            }
        }
        return UIMenu(
            title: String(localized: "Quality", bundle: .localized),
            image: UIImage(systemName: "slider.horizontal.3"),
            options: .singleSelection,
            children: actions
        )
    }

    /// "720p" for "720", "Original" for "original".
    static func appliedName(_ applied: String) -> String? {
        if let quality = VideoQuality(rawValue: applied), quality != .auto {
            return quality.displayName
        }
        return applied.isEmpty ? nil : applied
    }
}

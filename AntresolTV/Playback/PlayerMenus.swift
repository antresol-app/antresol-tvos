import AntresolKit
import UIKit

/// The Audio, Subtitles and Quality menus of the player's transport bar.
@MainActor
enum PlayerMenus {
    static func make(_ state: PlayerMenuState, model: VideoPlayerModel) -> [UIMenuElement] {
        var menus: [UIMenuElement] = []
        if state.audio.count > 1 {
            menus.append(audioMenu(state, model: model))
        }
        if !state.subtitles.isEmpty {
            menus.append(subtitleMenu(state, model: model))
        }
        menus.append(qualityMenu(state, model: model))
        return menus
    }

    private static func audioMenu(_ state: PlayerMenuState, model: VideoPlayerModel) -> UIMenu {
        let actions = state.audio.map { track in
            UIAction(title: TrackLabels.describe(track), state: track.index == state.audioIndex ? .on : .off) { [weak model] _ in
                model?.selectAudio(track.index)
            }
        }
        return UIMenu(
            title: String(localized: "Audio", bundle: .localized),
            image: UIImage(systemName: "speaker.wave.2"),
            options: .singleSelection,
            children: actions
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
    private static func appliedName(_ applied: String) -> String? {
        if let quality = VideoQuality(rawValue: applied), quality != .auto {
            return quality.displayName
        }
        return applied.isEmpty ? nil : applied
    }
}

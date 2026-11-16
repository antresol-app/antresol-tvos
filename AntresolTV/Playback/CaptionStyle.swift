import MediaAccessibility
import UIKit

/// The look of the subtitles the players draw themselves (the film player's side-loaded
/// cues, the live player's cues). The app's own look stands for the system's default
/// caption style; what the viewer changed in Settings > Accessibility > Subtitles and
/// Captioning (text size, text colour, background) replaces it. The font and the text
/// edge of the system style are not applied.
struct CaptionStyle: Equatable {
    var fontSize: CGFloat = 48
    var textColor = UIColor.white
    /// The rounded plate behind the cue.
    var plateColor = UIColor.black.withAlphaComponent(0.55)

    /// Posted when the viewer changes the caption settings.
    static let didChange = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)

    /// The style for the viewer's caption settings as they are now.
    static var current: CaptionStyle {
        var style = CaptionStyle()

        let size = MACaptionAppearanceGetRelativeCharacterSize(.user, nil)
        let defaultSize = MACaptionAppearanceGetRelativeCharacterSize(.default, nil)
        if size > 0, defaultSize > 0 {
            style.fontSize = (style.fontSize * size / defaultSize).rounded()
        }

        let text = Fill(
            color: MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue(),
            opacity: MACaptionAppearanceGetForegroundOpacity(.user, nil)
        )
        let defaultText = Fill(
            color: MACaptionAppearanceCopyForegroundColor(.default, nil).takeRetainedValue(),
            opacity: MACaptionAppearanceGetForegroundOpacity(.default, nil)
        )
        if text != defaultText {
            style.textColor = text.uiColor
        }

        // The plate is the system style's window or its text background, whichever the
        // viewer made more opaque.
        let plates = [Fill.window(.user), Fill.background(.user)]
        if plates != [Fill.window(.default), Fill.background(.default)] {
            style.plateColor = (plates[1].opacity > plates[0].opacity ? plates[1] : plates[0]).uiColor
        }
        return style
    }

    private struct Fill: Equatable {
        let color: CGColor
        let opacity: CGFloat

        var uiColor: UIColor {
            UIColor(cgColor: color).withAlphaComponent(opacity)
        }

        static func window(_ domain: MACaptionAppearanceDomain) -> Fill {
            Fill(
                color: MACaptionAppearanceCopyWindowColor(domain, nil).takeRetainedValue(),
                opacity: MACaptionAppearanceGetWindowOpacity(domain, nil)
            )
        }

        static func background(_ domain: MACaptionAppearanceDomain) -> Fill {
            Fill(
                color: MACaptionAppearanceCopyBackgroundColor(domain, nil).takeRetainedValue(),
                opacity: MACaptionAppearanceGetBackgroundOpacity(domain, nil)
            )
        }
    }
}

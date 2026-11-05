import AntresolKit
import Foundation

/// The app's language: the system's, or an override chosen in Settings.
///
/// An override is written to the app's `AppleLanguages`, which the system applies to
/// everything (including its own UI) from the next launch. Until then SwiftUI text follows
/// the environment locale set from it, `String(localized:bundle: .localized)` reads the
/// chosen language's strings, and the server is asked for the new language right away.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    private static let storageKey = "app.language"

    static var stored: AppLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func persist() {
        Self.stringsBundle = bundle
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.storageKey)
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// `en` or `ru`, for `Accept-Language`.
    var serverCode: String {
        APIClient.normalizeLanguage(identifier)
    }

    /// The `.lproj` bundle with this language's strings.
    var bundle: Bundle {
        Bundle.main.path(forResource: serverCode, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    /// The strings bundle of the chosen language, switched as soon as it changes.
    nonisolated(unsafe) fileprivate static var stringsBundle: Bundle = stored.bundle

    /// The locale SwiftUI renders with.
    var locale: Locale {
        Locale(identifier: identifier)
    }

    /// The language's own name, so it can be found whatever the current language is.
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    private var identifier: String {
        self == .system ? Self.systemLanguage : rawValue
    }

    /// Reads the system language before any change in Settings can affect it; call at launch.
    static func captureSystemLanguage() {
        _ = systemLanguage
    }

    /// The language the app would use without an override. Without an override at launch
    /// that is simply the preferred language; with one, the device's own list is read.
    private static let systemLanguage: String = {
        if stored == .system, let first = Locale.preferredLanguages.first {
            return first
        }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["AppleLanguages"] as? [String])?.first ?? "en"
    }()
}

extension Bundle {
    /// Strings in the app language chosen in Settings, which can differ from the launch
    /// language: pass it to every `String(localized:)` so text follows a change at once.
    static var localized: Bundle { AppLanguage.stringsBundle }
}

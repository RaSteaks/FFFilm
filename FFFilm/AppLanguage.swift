import Foundation
import Observation

/// Only these two languages are offered; language names stay readable in either UI.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "fffilm.app-language"
    var id: String { rawValue }
    var nativeName: String { self == .simplifiedChinese ? "简体中文" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
    var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    static func initial(defaults: UserDefaults = .standard,
                        preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        if let saved = defaults.string(forKey: preferenceKey), let language = Self(rawValue: saved) {
            return language
        }
        // Preserve the existing system-language default until the user makes a choice.
        for identifier in preferredLanguages {
            let language = Locale(identifier: identifier).language
            if language.languageCode?.identifier == "en" { return .english }
            if language.languageCode?.identifier == "zh", language.script?.identifier == "Hans" {
                return .simplifiedChinese
            }
        }
        return .english
    }
}

/// One observable preference refreshes eager strings and every scene without resetting view identity.
@MainActor @Observable
final class AppLanguagePreference {
    static let shared = AppLanguagePreference()
    private let defaults: UserDefaults
    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey) }
    }

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        language = AppLanguage.initial(defaults: defaults, preferredLanguages: preferredLanguages)
    }
}

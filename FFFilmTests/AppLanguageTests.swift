import Foundation
import Testing
@testable import FFFilm

@MainActor
struct AppLanguageTests {
    @Test func systemFallbackAndSavedChoice() throws {
        let suite = "AppLanguageTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppLanguage.initial(defaults: defaults, preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese)
        #expect(AppLanguage.initial(defaults: defaults, preferredLanguages: ["zh-CN"]) == .simplifiedChinese)
        #expect(AppLanguage.initial(defaults: defaults, preferredLanguages: ["en-GB"]) == .english)
        #expect(AppLanguage.initial(defaults: defaults, preferredLanguages: ["ja-JP"]) == .english)
        #expect(AppLanguage.initial(defaults: defaults, preferredLanguages: ["zh-Hant-TW"]) == .english)
        #expect(AppLanguage.initial(defaults: defaults, preferredLanguages: []) == .english)
        defaults.set("invalid", forKey: AppLanguage.preferenceKey)
        #expect(AppLanguage.initial(defaults: defaults, preferredLanguages: ["zh-Hans"]) == .simplifiedChinese)

        let preference = AppLanguagePreference(defaults: defaults, preferredLanguages: ["en"])
        preference.language = .simplifiedChinese
        // A fresh preference must restore the override even with a different system language.
        let restored = AppLanguagePreference(defaults: defaults, preferredLanguages: ["en"])
        #expect(restored.language == .simplifiedChinese)
        preference.language = .english
        #expect(AppLanguagePreference(defaults: defaults, preferredLanguages: ["zh-Hans"]).language == .english)
    }

    @Test func dynamicTextFollowsTheSelectedLanguage() {
        let preference = AppLanguagePreference.shared
        let oldLanguage = preference.language
        let oldSaved = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer {
            preference.language = oldLanguage
            if let oldSaved { UserDefaults.standard.set(oldSaved, forKey: AppLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        preference.language = .simplifiedChinese
        #expect(AppText.localized("settings.title") == "设置")
        #expect(AppText.resource(StorageUnit.decimal.title).contains("十进制"))
        #expect(AppText.imported(sensorFps: 48, projectFps: 24).contains("48"))
        #expect(ShutterInputField.sensorFps.error(for: -1)?.contains("请输入") == true)
        preference.language = .english
        #expect(AppText.localized("settings.title") == "Settings")
        #expect(AppText.resource(StorageUnit.decimal.title).contains("Decimal"))
        // The compact confirmation still names both imported values.
        #expect(AppText.imported(sensorFps: 48, projectFps: 24) == "Imported: camera 48 fps · project 24 fps")
        #expect(ShutterInputField.sensorFps.error(for: -1)?.hasPrefix("Enter") == true)
    }

    @Test func explicitBundlesContainBothTranslations() {
        // Exercise the built catalogs rather than a duplicate in-memory translation table.
        #expect(AppLanguage.simplifiedChinese.bundle.localizedString(forKey: "settings.language", value: nil, table: nil) == "应用语言")
        #expect(AppLanguage.english.bundle.localizedString(forKey: "settings.language", value: nil, table: nil) == "App language")
    }
}

import SwiftUI

#if os(iOS)
import UIKit
#endif

/// App-wide language and storage preferences are shared across windows and retained after relaunch.
struct SettingsView: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    @Bindable private var languagePreference = AppLanguagePreference.shared

    var body: some View {
        // Each native row already supplies its label; avoid duplicate headings and
        // routine persistence instructions, keeping unit explanations in the disclosure.
        Form {
            Section {
                // Native names remain recognizable even when the current language is unfamiliar.
                Picker("settings.language", selection: $languagePreference.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.nativeName).tag(language)
                    }
                }
                .accessibilityIdentifier("app-language-picker")
            }

            Section {
                Picker("settings.capacity", selection: $unit) {
                    ForEach(StorageUnit.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("storage-unit-picker")
                // Keep collapsed explanations in the same section as the capacity preference.
                DisclosureGroup("settings.details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.unitDifferenceTitle").font(.headline)
                        Text("settings.decimalExplanation")
                        Text("settings.binaryExplanation")
                        Text("settings.unitDifferenceNote")
                        Divider()
                        Text("settings.impactTitle").font(.headline)
                        Text("settings.impactExplanation")
                        Link("settings.appleLink", destination: URL(string: "https://support.apple.com/en-us/102119")!)
                        Link("settings.microsoftLink", destination: URL(string: "https://devblogs.microsoft.com/oldnewthing/20090611-00/?p=17933")!)
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("storage-unit-details")
            }

            Section {
                LabeledContent {
                    Text(verbatim: "zhuyutian041119@foxmail.com")
                        .textSelection(.enabled)
                        .accessibilityIdentifier("feedback-email")
                } label: {
                    Label("feedback.email.title", systemImage: "envelope")
                }
            } header: { Text("feedback.email.section") }
        }
        .formStyle(.grouped)
        #if os(iOS)
        // Keep explanatory text readable in a wide iPad settings tab while allowing
        // the same native form to fill an iPhone or a narrow Stage Manager window.
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 680 : .infinity)
        .frame(maxWidth: .infinity)
        #endif
        // Native navigation bars cache localized keys; change the resolved title on each switch.
        .navigationTitle(AppText.localized("settings.title"))
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 560, height: 580)
        #endif
    }
}

#if os(macOS)
/// The desktop toolbar opens the native settings scene; iOS uses its settings tab.
struct SettingsButton: View {
    var body: some View {
        SettingsLink { Label("nav.settings", systemImage: "gearshape") }
            .help(Text("settings.shortcut"))
            .accessibilityIdentifier("settings-action")
    }
}
#endif

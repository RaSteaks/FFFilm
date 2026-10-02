import SwiftUI

@main
struct FFFilmApp: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Isolate language UI regressions without changing production launch behavior.
        if ProcessInfo.processInfo.environment["FFFILM_UI_RESET_LANGUAGE"] == "1" {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
        }
        #endif
    }

    #if os(macOS)
    // Quit and window-close both protect unsaved film documents; iOS has no delegate bridge.
    @NSApplicationDelegateAdaptor(FilmAppDelegate.self) private var filmDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            // Updating the environment preserves tabs, editor drafts and active image sessions.
            ContentView().environment(\.locale, AppLanguagePreference.shared.language.locale)
        }
        #if os(macOS)
        // Each window retains its own calculator store; commands follow the focused window.
        .defaultSize(width: 1040, height: 760)
        .windowToolbarStyle(.unified)
        // The film workbench now lives as a tab inside the main window; its
        // document commands act through the focused scene's film store.
        .commands { MacWorkbenchCommands() }
        .commands { FilmCommands() }
        #endif
        #if os(macOS)
        // Preferences are app-wide, while calculator scenes retain independent selections.
        Settings {
            SettingsView().environment(\.locale, AppLanguagePreference.shared.language.locale)
        }
        #endif
    }
}

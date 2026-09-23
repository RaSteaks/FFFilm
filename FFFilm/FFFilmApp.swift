import SwiftUI

@main
struct FFFilmApp: App {
    #if os(macOS)
    // Quit and window-close both protect unsaved film documents; iOS has no delegate bridge.
    @NSApplicationDelegateAdaptor(FilmAppDelegate.self) private var filmDelegate
    #endif
    var body: some Scene {
        WindowGroup { ContentView() }
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
        Settings { SettingsView() }
        #endif
    }
}

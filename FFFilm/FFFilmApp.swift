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
        .commands { MacWorkbenchCommands() }
        #endif
        #if os(macOS)
        // The image editor has independent document state and does not alter calculator navigation.
        WindowGroup("Film", id: "film-workbench") { FilmWorkbenchView() }
            .commands { FilmCommands() }
            .defaultSize(width: 1280, height: 860)
            .windowToolbarStyle(.unified)
        // Preferences are app-wide, while calculator scenes retain independent selections.
        Settings { SettingsView() }
        #endif
    }
}

import SwiftUI

@main
struct FFFilmApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
        #if os(macOS)
        // Each window retains its own calculator store; commands follow the focused window.
        .defaultSize(width: 1040, height: 760)
        .windowToolbarStyle(.unified)
        .commands { MacWorkbenchCommands() }
        #endif
        #if os(macOS)
        // Preferences are app-wide, while calculator scenes retain independent selections.
        Settings { SettingsView() }
        #endif
    }
}

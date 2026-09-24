import SwiftUI

#if os(iOS)
import UIKit
#endif

/// AppStorage shares the preference across windows and retains it after relaunch.
struct SettingsView: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal

    var body: some View {
        Form {
            Section {
                Picker("settings.capacity", selection: $unit) {
                    ForEach(StorageUnit.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("storage-unit-picker")
                Text("settings.unitHint")
                    .foregroundStyle(.secondary)
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
            } header: { Text("settings.capacity") }
        }
        .formStyle(.grouped)
        #if os(iOS)
        // Keep explanatory text readable in a wide iPad sheet while allowing
        // the same native form to fill an iPhone or a narrow Stage Manager window.
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 680 : .infinity)
        .frame(maxWidth: .infinity)
        #endif
        .navigationTitle("settings.title")
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 560, height: 580)
        #endif
    }
}

/// Native settings window on Mac; a dismissible navigation sheet on touch platforms.
struct SettingsButton: View {
    #if !os(macOS)
    @State private var isPresented = false
    #endif
    var body: some View {
        #if os(macOS)
        SettingsLink { Label("nav.settings", systemImage: "gearshape") }
            .help(Text("settings.shortcut"))
            .accessibilityIdentifier("settings-action")
        #else
        Button { isPresented = true } label: {
            Label("nav.settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("settings-action")
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("nav.done") { isPresented = false }
                                .accessibilityIdentifier("settings-done")
                        }
                    }
            }
        }
        #endif
    }
}

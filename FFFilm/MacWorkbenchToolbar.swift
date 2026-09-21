#if os(macOS)
import SwiftUI

extension FocusedValues {
    @Entry var calculatorStore: CalculatorStore?
}

/// Native titlebar controls avoid nesting AppKit button bezels around custom capsule backgrounds.
struct MacWorkbenchToolbar: ToolbarContent {
    @Bindable var store: CalculatorStore
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Calculator", selection: $store.activeView) {
                Text("Rate").tag(CalculatorView.rate)
                Text("Shutter").tag(CalculatorView.shutter)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .help("Rate ⌘1 · Shutter ⌘2")
            .accessibilityIdentifier("calculator-view-picker")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            SettingsButton()
            if store.activeView == .rate {
                Button {
                    store.pinCurrentSetup()
                } label: {
                    Label("Pin", systemImage: "pin")
                }
                .disabled(store.pinnedSetups.count >= 4)
                .help("Pin setup for comparison (⇧⌘P)")
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("pin-action")

                Button {
                    PlatformClipboard.copy(store.configurationText)
                    copied = true
                    copyResetTask?.cancel()
                    copyResetTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy configuration (⇧⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .accessibilityIdentifier("copy-action")
                .onDisappear { copyResetTask?.cancel(); copied = false }
            }
            Button {
                store.resetActiveView()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset current calculator (⇧⌘R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityIdentifier("reset-action")
        }
    }
}

/// Scene-focused routing keeps menu shortcuts correct when several calculator windows are open.
struct MacWorkbenchCommands: Commands {
    @FocusedValue(\.calculatorStore) private var store

    var body: some Commands {
        CommandMenu("Calculator") {
            Button("Recording Rate") { store?.activeView = .rate }
                .keyboardShortcut("1")
                .disabled(store == nil)
            Button("Shutter") { store?.activeView = .shutter }
                .keyboardShortcut("2")
                .disabled(store == nil)
        }
    }
}
#endif

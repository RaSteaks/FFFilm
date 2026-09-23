#if os(macOS)
import SwiftUI

extension FocusedValues {
    @Entry var calculatorStore: CalculatorStore?
}

/// Native titlebar controls avoid nesting AppKit button bezels around custom capsule backgrounds.
struct MacWorkbenchToolbar: ToolbarContent {
    @Bindable var store: CalculatorStore
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("nav.workbench", selection: $store.activeView) {
                ForEach(CalculatorView.allCases) { view in
                    Text(view.label).tag(view)
                }
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
                    Label {
                        Text("nav.addComparison")
                        Text("\(store.pinnedSetups.count)/4").monospacedDigit().foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "pin")
                    }
                }
                .disabled(store.pinnedSetups.count >= 4)
                .help("Pin setup for comparison (⇧⌘P)")
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("pin-action")

                Button {
                    PlatformClipboard.copy(store.readableRecordingSummary(storageUnit: unit))
                    copied = true
                    copyResetTask?.cancel()
                    copyResetTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                } label: {
                    Label(copied ? "nav.copied" : "nav.copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy configuration (⇧⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .accessibilityIdentifier("copy-action")
                .onDisappear { copyResetTask?.cancel(); copied = false }
            }
            Menu {
                if store.activeView == .rate {
                    Button("nav.copyLink", systemImage: "link") {
                        PlatformClipboard.copy(store.configurationText)
                    }
                }
                Button("nav.reset", systemImage: "arrow.counterclockwise") {
                    store.resetActiveView()
                }
                .help(Text("nav.reset"))
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .accessibilityIdentifier("reset-action")
            } label: {
                Label("nav.more", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("more-action")
        }
    }
}

/// Scene-focused routing keeps menu shortcuts correct when several calculator windows are open.
struct MacWorkbenchCommands: Commands {
    @FocusedValue(\.calculatorStore) private var store

    var body: some Commands {
        CommandMenu("Calculator") {
            Button("nav.recording") { store?.setActiveView(.rate) }
                .keyboardShortcut("1")
                .disabled(store == nil)
            Button("nav.shutter") { store?.setActiveView(.shutter) }
                .keyboardShortcut("2")
                .disabled(store == nil)
        }
    }
}
#endif

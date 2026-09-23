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
            .frame(width: 260)
            .help("Rate ⌘1 · Shutter ⌘2 · Film ⌘3")
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
            }
            // Both calculator tabs expose Copy after the in-content header is removed.
            if store.activeView != .film {
                Button {
                    let summary = store.activeView == .rate
                        ? store.readableRecordingSummary(storageUnit: unit)
                        : store.readableShutterSummary()
                    PlatformClipboard.copy(summary)
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
                .help(store.activeView == .rate ? "Copy configuration (⇧⌘C)" : "Copy shutter summary (⇧⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.activeView == .shutter && store.shutterCalculation.exposure == nil)
                .accessibilityIdentifier("copy-action")
                .onDisappear { copyResetTask?.cancel(); copied = false }
            }
            // Calculator reset/copy do not apply to the film editor, whose own
            // toolbar items appear while the film tab is showing.
            if store.activeView != .film {
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
            Button("nav.film") { store?.setActiveView(.film) }
                .keyboardShortcut("3")
                .disabled(store == nil)
        }
    }
}
#endif

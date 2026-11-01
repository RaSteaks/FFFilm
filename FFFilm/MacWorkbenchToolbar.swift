#if os(macOS)
import SwiftUI

extension FocusedValues {
    @Entry var calculatorStore: CalculatorStore?
}

/// The thumb and the page share one spring so a workbench switch reads as a single movement.
enum WorkbenchMotion {
    static let travel = Animation.spring(response: 0.3, dampingFraction: 1)
    static let fade = Animation.easeInOut(duration: 0.15)
    static let pageExit = Animation.easeOut(duration: 0.12)
    static let pageTravel: CGFloat = 20
}

/// Native titlebar controls avoid nesting AppKit button bezels around custom capsule backgrounds.
struct MacWorkbenchToolbar: ToolbarContent {
    @Bindable var store: CalculatorStore
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            WorkbenchSwitcher(selection: $store.activeView)
                .help(Text("Rate ⌘1 · Shutter ⌘2 · Film ⌘3"))
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
                .help(Text("Pin setup for comparison (⇧⌘P)"))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("pin-action")
            }
            // Both calculator tabs expose Copy after the in-content header is removed.
            if store.activeView != .film {
                Button {
                    // Keyboard and toolbar copies participate in the same bounded shutter history.
                    if store.activeView == .shutter { store.rememberShutterResult() }
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
                // Keep each branch as localized Text; a computed String skips localization.
                .help(store.activeView == .rate ? Text("Copy configuration (⇧⌘C)") : Text("Copy shutter summary (⇧⌘C)"))
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

/// NSSegmentedControl swaps its selection in place, so the thumb is drawn here to travel between segments.
private struct WorkbenchSwitcher: View {
    @Binding var selection: CalculatorView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let inset: CGFloat = 2
    private static let cornerRadius: CGFloat = 7
    private static let segmentWidth = (260 - inset * 2) / CGFloat(CalculatorView.allCases.count)

    private var selectedIndex: Int {
        CalculatorView.allCases.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CalculatorView.allCases) { view in
                Button {
                    selection = view
                } label: {
                    Text(view.label)
                        .font(.system(size: 13))
                        .foregroundStyle(selection == view ? Palette.text : Palette.muted)
                        .frame(width: Self.segmentWidth, height: 24)
                }
                .buttonStyle(WorkbenchPressStyle())
            }
        }
        // One persistent thumb moves between stops; per-segment fills would cross-fade instead.
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset)
                // Matches the roughly 25% lift of the native segmented selections in the page.
                .fill(Palette.text.opacity(0.25))
                .frame(width: Self.segmentWidth)
                .offset(x: Self.segmentWidth * CGFloat(selectedIndex))
        }
        // Value-scoped, so ⌘1/2/3 slide too while the swapped workbench content stays unanimated.
        .animation(reduceMotion ? nil : WorkbenchMotion.travel, value: selection)
        .padding(Self.inset)
        .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .accessibilityRepresentation {
            Picker("nav.workbench", selection: $selection) {
                ForEach(CalculatorView.allCases) { view in
                    Text(view.label).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// Scene-focused routing keeps menu shortcuts correct when several calculator windows are open.
struct MacWorkbenchCommands: Commands {
    @FocusedValue(\.calculatorStore) private var store

    var body: some Commands {
        // Commands live outside the content locale environment; observe the shared preference.
        CommandMenu(AppText.localized("nav.calculate")) {
            Button(AppText.localized("nav.recording")) { store?.setActiveView(.rate) }
                .keyboardShortcut("1")
                .disabled(store == nil)
            Button(AppText.localized("nav.shutter")) { store?.setActiveView(.shutter) }
                .keyboardShortcut("2")
                .disabled(store == nil)
            Button(AppText.localized("nav.film")) { store?.setActiveView(.film) }
                .keyboardShortcut("3")
                .disabled(store == nil)
        }
    }
}
#endif

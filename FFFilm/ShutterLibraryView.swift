import SwiftUI

enum ShutterSheet: Identifiable {
    case library, rig, save(ShutterRecord)
    var id: String {
        switch self {
        case .library: "library"
        case .rig: "rig"
        case .save(let record): record.id.uuidString
        }
    }
}

struct ShutterLibraryView: View {
    let store: CalculatorStore
    @Environment(\.dismiss) private var dismiss
    @State private var inspected: ShutterRecord?

    var body: some View {
        NavigationStack {
            List {
                if !store.shutterWorkspace.saved.isEmpty {
                    Section("shutter.library.saved") {
                        ForEach(store.shutterWorkspace.saved) { record in row(record) }
                    }
                }
                if !store.shutterWorkspace.recent.isEmpty {
                    Section("shutter.library.recent") {
                        ForEach(store.shutterWorkspace.recent) { record in row(record) }
                    }
                }
            }
            .overlay {
                if store.shutterWorkspace.saved.isEmpty && store.shutterWorkspace.recent.isEmpty {
                    ContentUnavailableView("shutter.library.empty", systemImage: "tray",
                        description: Text("shutter.library.emptyHint"))
                }
            }
            .navigationTitle("shutter.library.title")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("shutter.library.done") { dismiss() } } }
            .navigationDestination(item: $inspected) { record in
                ShutterRecordDetail(store: store, record: record) {
                    store.restoreShutterRecord(record)
                    dismiss()
                }
            }
        }
        .frame(minWidth: 320, minHeight: 420)
        .onAppear { store.shutterWorkspace.refreshLibrary() }
    }

    private func row(_ record: ShutterRecord) -> some View {
        HStack(spacing: 12) {
            // A record restores its named source rig explicitly; an adjacent action opens notes.
            Button {
                store.restoreShutterRecord(record)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).foregroundStyle(Palette.text).lineLimit(2)
                    Text(AppText.shutterRestoreLabel(record.rig)).font(.caption).foregroundStyle(Palette.muted)
                    if !record.cameraLabel.isEmpty { Text(record.cameraLabel).font(.caption).foregroundStyle(Palette.muted).lineLimit(2) }
                    if record.fieldChecked {
                        Label("shutter.library.checked", systemImage: "checkmark.circle").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Layout.controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shutter-restore-\(record.id)")
            Button { inspected = record } label: {
                Image(systemName: "info.circle").frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("shutter.library.details"))
            .accessibilityIdentifier("shutter-record-info-\(record.id)")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ShutterRecordDetail: View {
    let store: CalculatorStore
    let record: ShutterRecord
    let restore: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    @State private var copied = false
    @State private var copyRevision = 0

    var body: some View {
        Form {
            Section {
                Text(store.summary(for: record)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                LabeledContent("shutter.library.recorded", value: record.date.formatted(date: .abbreviated, time: .shortened))
            }
            if record.fieldChecked { Section { Text("shutter.library.checkScope").font(.caption) } }
            Section {
                Button(AppText.shutterRestoreLabel(record.rig), action: restore)
                Button(copied ? "shutter.copied" : "shutter.copyResult") {
                    store.shutterWorkspace.remember(record)
                    PlatformClipboard.copy(store.summary(for: record))
                    copied = true; copyRevision += 1
                }
            }
            if store.shutterWorkspace.saved.contains(where: { $0.id == record.id }) {
                Section { Button("shutter.library.delete", role: .destructive) { confirmsDelete = true } }
            }
        }
        .navigationTitle(record.title)
        .task(id: copyRevision) {
            // Repeated copies replace the feedback timer, and leaving the detail cancels it.
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copied = false
        }
        .confirmationDialog("shutter.library.deleteQuestion", isPresented: $confirmsDelete) {
            Button("shutter.library.delete", role: .destructive) {
                store.shutterWorkspace.deleteSaved(record.id)
                dismiss()
            }
        }
    }
}

struct ShutterSaveView: View {
    let store: CalculatorStore
    let snapshot: ShutterRecord
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var checked = false
    @State private var conditions = ""

    init(store: CalculatorStore, snapshot: ShutterRecord) {
        self.store = store; self.snapshot = snapshot
        // A blank name uses the captured parameter summary, so quick saving needs no keyboard.
        _title = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("shutter.library.name", text: $title)
                        .accessibilityIdentifier("shutter-record-name")
                    Text(AppText.shutterRigContext(ShutterRig(id: snapshot.rig, cameraLabel: snapshot.cameraLabel, settings: snapshot.settings)))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section {
                    Toggle("shutter.library.fieldCheck", isOn: $checked)
                        .accessibilityIdentifier("shutter-record-checked")
                    TextField("shutter.library.conditions", text: $conditions, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("shutter-record-conditions")
                } footer: { Text("shutter.library.checkScope") }
            }
            .navigationTitle("shutter.library.save")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("shutter.library.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("shutter.library.save") {
                        var record = snapshot
                        let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        record.title = enteredTitle.isEmpty ? snapshot.title : enteredTitle
                        record.fieldChecked = checked
                        record.conditions = conditions.trimmingCharacters(in: .whitespacesAndNewlines)
                        record.date = .now
                        store.shutterWorkspace.save(record)
                        dismiss()
                    }
                    .disabled(checked && conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("shutter-record-save")
                }
            }
        }
        .frame(minWidth: 320, minHeight: 380)
    }
}

struct ShutterRigView: View {
    let store: CalculatorStore
    @Environment(\.dismiss) private var dismiss
    @State private var cameraLabel: String

    init(store: CalculatorStore) {
        self.store = store
        _cameraLabel = State(initialValue: store.shutterWorkspace.active.cameraLabel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("shutter.rig.camera", text: $cameraLabel, axis: .vertical)
                        .accessibilityIdentifier("shutter-rig-camera")
                    Button("shutter.rig.useRecording") {
                        cameraLabel = "\(store.currentCamera.name) · \(store.currentMode.label) · \(store.currentResolution.label)"
                    }
                } footer: { Text("shutter.rig.hint") }
            }
            .navigationTitle("shutter.rig.configure")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("shutter.library.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("shutter.library.done") { store.configureShutterRig(cameraLabel: cameraLabel); dismiss() }
                        .accessibilityIdentifier("shutter-rig-save")
                }
            }
        }
        .frame(minWidth: 320, minHeight: 260)
    }
}

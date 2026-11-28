import SwiftUI

struct SummaryEditSheet: View {
    let summary: RecordingSummary
    let entry: SummaryEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hours: Double?
    @State private var date = Date.now

    init(summary: RecordingSummary, entry: SummaryEntry?) {
        self.summary = summary; self.entry = entry
        _name = State(initialValue: entry.map { $0.rig ?? "" } ?? summary.activeDay.project)
        _hours = State(initialValue: entry?.settings.shootHours)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(entry == nil ? "summary.project" : "summary.rig", text: $name)
                if let entry {
                    if entry.cardAllocation != true { TextField("summary.hours", value: $hours, format: .number) }
                } else {
                    DatePicker("summary.day", selection: $date, displayedComponents: .date)
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("shutter.library.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.apply") {
                        if let entry { summary.edit(entry.id, rig: name, hours: hours ?? 0) }
                        else { summary.newDay(project: name, date: date) }
                        dismiss()
                    }.disabled(entry != nil && entry?.cardAllocation != true && !CaptureSettings.shootHoursRange.contains(hours ?? -1))
                }
            }
        }.frame(minWidth: 300, minHeight: 220)
    }
}

import SwiftUI

struct RecordingPlanDetails: View {
    @Bindable var store: CalculatorStore
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal

    var body: some View {
        let result = store.calculation
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("plan.cards", value: "\(result.requiredCards) × \(result.media.label)")
            Text("\(AppText.key("result.cardDuration")) · \(DisplayFormat.duration(result.captureRuntimeHours))")
                .font(.caption)
            DisclosureGroup("plan.backup") {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper(value: $store.backupCopies, in: 1...8) { LabeledContent("plan.copies", value: "\(store.backupCopies)") }
                    Stepper(value: $store.reservePercent, in: 0...50, step: 5) { LabeledContent("plan.reserve", value: "\(store.reservePercent)%") }
                    LabeledContent("plan.proxy") { TextField("GB", value: $store.proxyGb, format: .number) }
                    LabeledContent("plan.free") { TextField("GB", value: $store.destinationFreeGb, format: .number) }
                    LabeledContent("plan.destination", value: DisplayFormat.compactStorage(store.bytesPerDestinationGb, unit: unit))
                    LabeledContent("plan.allCopies", value: DisplayFormat.compactStorage(store.bytesPerDestinationGb * Double(store.backupCopies), unit: unit))
                    if !store.validBackupPlan { Text("plan.invalidSpace").foregroundStyle(.red) }
                    if let free = store.destinationFreeGb, free >= 0, free < store.bytesPerDestinationGb {
                        Label("plan.insufficient", systemImage: "exclamationmark.triangle")
                    }
                    if let hde = result.hdeEstimateGb {
                        LabeledContent("plan.hde", value: "≈ " + DisplayFormat.compactStorage(hde, unit: unit))
                    }
                }.padding(.vertical, 6)
            }
        }.font(.callout)
    }
}

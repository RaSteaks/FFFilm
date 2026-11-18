#if os(iOS)
import SwiftUI
import UIKit

/// Whole-second recording duration as shown on the wheel.
struct DurationComponents: Equatable {
    var hours: Int
    var minutes: Int
    var seconds: Int

    /// The wheel only reaches whole seconds, so stored hours round to the nearest second.
    init(hours value: Double) {
        let total = value.isFinite ? max(0, Int((value * 3_600).rounded())) : 0
        hours = min(total / 3_600, 24)
        minutes = total / 60 % 60
        seconds = total % 60
    }

    var totalSeconds: Int { hours * 3_600 + minutes * 60 + seconds }
    var totalHours: Double { Double(totalSeconds) / 3_600 }
}

/// Hours, minutes and seconds on one native three-component wheel, like Clock's timer.
/// A single UIPickerView keeps each column's touch region separate, which side-by-side
/// SwiftUI wheel pickers do not, and supplies native momentum, detent ticks and VoiceOver.
struct DurationWheel: UIViewRepresentable {
    @Binding var components: DurationComponents
    /// Called after the operator settles a column; programmatic updates never call it.
    let onCommit: () -> Void

    static let rows = [25, 60, 60]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> DurationPickerView {
        let picker = DurationPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.accessibilityIdentifier = "duration-wheel"
        // UIPickerView draws neighbouring rows beyond its bounds; keep them inside the field.
        picker.clipsToBounds = true
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The intrinsic 216pt height would overflow the three-row field.
        picker.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return picker
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DurationPickerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ picker: DurationPickerView, context: Context) {
        context.coordinator.parent = self
        // Unit titles follow the in-app language, which can change while the wheel is visible.
        picker.unitTitles = Coordinator.unitTitles
        let values = [components.hours, components.minutes, components.seconds]
        for (component, value) in values.enumerated() where picker.selectedRow(inComponent: component) != value {
            picker.selectRow(value, inComponent: component, animated: false)
        }
        picker.setNeedsLayout()
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewAccessibilityDelegate {
        var parent: DurationWheel

        init(parent: DurationWheel) {
            self.parent = parent
        }

        static var unitTitles: [String] {
            [AppText.resolve("duration.unit.hours", defaultValue: "hours", comment: "Unit beside the hours column of the duration wheel."),
             AppText.resolve("duration.unit.minutes", defaultValue: "min", comment: "Unit beside the minutes column of the duration wheel."),
             AppText.resolve("duration.unit.seconds", defaultValue: "sec", comment: "Unit beside the seconds column of the duration wheel.")]
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { DurationWheel.rows.count }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            DurationWheel.rows[component]
        }

        func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
            // Equal columns; UIKit adds its own spacing between components.
            max(64, (pickerView.bounds.width - 24) / 3)
        }

        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
            DurationPickerView.rowHeight
        }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int,
                        reusing view: UIView?) -> UIView {
            let rowView = (view as? DurationRowView) ?? DurationRowView()
            rowView.value = row
            return rowView
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            switch component {
            case 0: parent.components.hours = row
            case 1: parent.components.minutes = row
            default: parent.components.seconds = row
            }
            parent.onCommit()
        }

        func pickerView(_ pickerView: UIPickerView, accessibilityLabelForComponent component: Int) -> String? {
            switch component {
            case 0: AppText.resolve("duration.wheel.hours", defaultValue: "Hours", comment: "VoiceOver name of the duration wheel's hours column.")
            case 1: AppText.resolve("duration.wheel.minutes", defaultValue: "Minutes", comment: "VoiceOver name of the duration wheel's minutes column.")
            default: AppText.resolve("duration.wheel.seconds", defaultValue: "Seconds", comment: "VoiceOver name of the duration wheel's seconds column.")
            }
        }
    }
}

/// Places a fixed unit label to the right of each column's selected number.
final class DurationPickerView: UIPickerView {
    static var numberFont: UIFont {
        UIFontMetrics(forTextStyle: .title2)
            .scaledFont(for: .monospacedSystemFont(ofSize: 22, weight: .regular), maximumPointSize: 32)
    }

    static var rowHeight: CGFloat {
        min(UIFontMetrics(forTextStyle: .title2).scaledValue(for: 36), 46)
    }

    private let unitLabels: [UILabel] = (0 ..< 3).map { _ in
        let label = UILabel()
        label.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 22)
        label.textColor = UIColor(Palette.muted)
        label.adjustsFontForContentSizeCategory = true
        // Each column already announces its own name, so the units stay visual.
        label.isAccessibilityElement = false
        return label
    }

    var unitTitles: [String] = [] {
        didSet {
            guard unitTitles != oldValue else { return }
            for (label, title) in zip(unitLabels, unitTitles) { label.text = title }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        unitLabels.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let columnWidth = bounds.width / 3
        for (component, label) in unitLabels.enumerated() {
            // Prefer the column's real frame; fall back to an equal split before rows exist.
            var column = CGRect(x: CGFloat(component) * columnWidth, y: 0, width: columnWidth, height: bounds.height)
            if let row = view(forRow: selectedRow(inComponent: component), forComponent: component) {
                column = row.convert(row.bounds, to: self)
            }
            let height = label.font.lineHeight
            label.frame = CGRect(x: column.midX + DurationRowView.numberGap,
                                 y: bounds.midY - height / 2,
                                 width: max(0, column.width / 2 - DurationRowView.numberGap),
                                 height: height)
            bringSubviewToFront(label)
        }
    }
}

/// Right-aligns the number just left of the column centre, leaving room for the unit.
final class DurationRowView: UIView {
    static let numberGap: CGFloat = 8
    private let label = UILabel()

    var value = 0 {
        didSet {
            label.text = String(value)
            // XCUITest and VoiceOver read the selected row's label as the column value.
            accessibilityLabel = String(value)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = DurationPickerView.numberFont
        label.textColor = UIColor(Palette.text)
        label.textAlignment = .right
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 0, y: 0, width: bounds.width / 2 + Self.numberGap / 2, height: bounds.height)
    }
}
#endif

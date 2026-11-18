#if os(iOS)
import SwiftUI

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

/// Hours, minutes and seconds on three vertical wheels in the style of the system timer.
/// They are drawn in SwiftUI rather than UIPickerView so detents share the dials' soft click
/// and haptic (`DialFeedback`) instead of the system tick, and the wheel fits its field.
///
/// Every position the wheel can reach is a valid plan: at 24 hours the minute and second
/// columns hold only 0, so the wheel never shows a total the result does not use. A column
/// commits when it settles.
struct DurationWheel: View {
    @Binding var components: DurationComponents
    /// Called with the new duration after the operator settles a column, taps a row or adjusts
    /// with VoiceOver. The value is passed explicitly: reading the binding's owner back in the
    /// same event can still see the previous state.
    let onCommit: (DurationComponents) -> Void
    @ScaledMetric(relativeTo: .title2) private var rowHeight: CGFloat = 36

    private enum Column: Int, CaseIterable {
        case hours, minutes, seconds

        var identifier: String {
            switch self {
            case .hours: "duration-hours"
            case .minutes: "duration-minutes"
            case .seconds: "duration-seconds"
            }
        }

        var unit: String {
            switch self {
            case .hours: AppText.resolve("duration.unit.hours", defaultValue: "hours", comment: "Unit beside the hours column of the duration wheel.")
            case .minutes: AppText.resolve("duration.unit.minutes", defaultValue: "min", comment: "Unit beside the minutes column of the duration wheel.")
            case .seconds: AppText.resolve("duration.unit.seconds", defaultValue: "sec", comment: "Unit beside the seconds column of the duration wheel.")
            }
        }

        var accessibilityName: String {
            switch self {
            case .hours: AppText.resolve("duration.wheel.hours", defaultValue: "Hours", comment: "VoiceOver name of the duration wheel's hours column.")
            case .minutes: AppText.resolve("duration.wheel.minutes", defaultValue: "Minutes", comment: "VoiceOver name of the duration wheel's minutes column.")
            case .seconds: AppText.resolve("duration.wheel.seconds", defaultValue: "Seconds", comment: "VoiceOver name of the duration wheel's seconds column.")
            }
        }
    }

    var body: some View {
        let fullDay = components.hours == 24
        HStack(spacing: 0) {
            WheelColumn(values: Array(0 ... 24), selection: components.hours, rowHeight: rowHeight,
                        unit: Column.hours.unit, accessibilityName: Column.hours.accessibilityName,
                        identifier: Column.hours.identifier) { select(.hours, $0) }
            // A full day has no minutes or seconds left; those columns hold only 0.
            WheelColumn(values: fullDay ? [0] : Array(0 ... 59), selection: components.minutes, rowHeight: rowHeight,
                        unit: Column.minutes.unit, accessibilityName: Column.minutes.accessibilityName,
                        identifier: Column.minutes.identifier) { select(.minutes, $0) }
            WheelColumn(values: fullDay ? [0] : Array(0 ... 59), selection: components.seconds, rowHeight: rowHeight,
                        unit: Column.seconds.unit, accessibilityName: Column.seconds.accessibilityName,
                        identifier: Column.seconds.identifier) { select(.seconds, $0) }
        }
        .background {
            // The selection band spans all three columns, as on the system wheel.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.controlSurface)
                .frame(height: rowHeight)
                .padding(.horizontal, 8)
        }
    }

    private func select(_ column: Column, _ value: Int) {
        var next = components
        switch column {
        case .hours:
            next.hours = value
            // Reaching a full day visibly returns minutes and seconds to 0.
            if value == 24 {
                next.minutes = 0
                next.seconds = 0
            }
        case .minutes: next.minutes = value
        case .seconds: next.seconds = value
        }
        components = next
        onCommit(next)
    }
}

/// One vertical wheel column: rows snap under the centre band, each detent plays the shared
/// soft cue, and the value commits once the column comes to rest.
private struct WheelColumn: View {
    let values: [Int]
    let selection: Int
    let rowHeight: CGFloat
    let unit: String
    let accessibilityName: String
    let identifier: String
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: ScrollPosition
    @State private var centered: Int?
    @State private var userDriven = false
    private let unitWidth: CGFloat = 46

    init(values: [Int], selection: Int, rowHeight: CGFloat, unit: String, accessibilityName: String,
         identifier: String, onSelect: @escaping (Int) -> Void) {
        self.values = values
        self.selection = selection
        self.rowHeight = rowHeight
        self.unit = unit
        self.accessibilityName = accessibilityName
        self.identifier = identifier
        self.onSelect = onSelect
        let resting = values.firstIndex(of: selection)
        _position = State(initialValue: ScrollPosition(id: resting ?? 0, anchor: .center))
        _centered = State(initialValue: resting)
    }

    private var restingIndex: Int? { values.firstIndex(of: selection) }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(values.indices, id: \.self) { index in
                        row(index)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollPosition($position, anchor: .center)
            .contentMargins(.vertical, max(0, (proxy.size.height - rowHeight) / 2), for: .scrollContent)
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int(((geometry.contentOffset.y + geometry.contentInsets.top) / rowHeight).rounded())
            } action: { _, raw in
                guard !values.isEmpty else { return }
                let index = min(max(raw, 0), values.count - 1)
                guard index != centered else { return }
                centered = index
                if userDriven { DialFeedback.shared.detent() }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking:
                    DialFeedback.shared.prepare()
                case .interacting:
                    userDriven = true
                case .animating:
                    userDriven = false
                case .idle:
                    guard userDriven else { return }
                    userDriven = false
                    if let centered, values.indices.contains(centered), values[centered] != selection {
                        onSelect(values[centered])
                    }
                default:
                    break
                }
            }
            .onChange(of: proxy.size.height) { _, _ in
                guard !userDriven else { return }
                scroll(to: restingIndex, animated: false)
            }
        }
        // The unit stays beside the selected row while the numbers move.
        .overlay(alignment: .trailing) {
            Text(verbatim: unit)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: unitWidth, alignment: .leading)
                .allowsHitTesting(false)
        }
        .onAppear { scroll(to: restingIndex, animated: false) }
        .onChange(of: restingIndex) { _, index in
            guard !userDriven else { return }
            scroll(to: index, animated: true)
        }
        .onChange(of: values) { _, _ in
            guard !userDriven else { return }
            scroll(to: restingIndex, animated: false)
        }
        // The scroll content's accessibility frame is the whole column of rows; a clear overlay
        // exposes one adjustable element with the visible column's frame.
        .accessibilityHidden(true)
        .overlay {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: accessibilityName))
                .accessibilityValue(Text(verbatim: "\(selection)"))
                .accessibilityAdjustableAction { direction in
                    guard let base = restingIndex else { return }
                    let target = direction == .increment ? base + 1 : base - 1
                    guard values.indices.contains(target) else { return }
                    onSelect(values[target])
                }
                .accessibilityIdentifier(identifier)
        }
    }

    private func row(_ index: Int) -> some View {
        let value = values[index]
        let isCentered = index == centered
        return HStack(spacing: 6) {
            Text(verbatim: "\(value)")
                .font(.system(.title2, design: .monospaced))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .monospacedDigit()
                .foregroundStyle(isCentered ? Palette.text : Palette.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Color.clear.frame(width: unitWidth)
        }
        .frame(height: rowHeight)
        .contentShape(.rect)
        // Rows further from the band recede, as on the system wheel.
        .scrollTransition(.interactive.threshold(.centered), axis: .vertical) { content, phase in
            content
                .opacity(1 - min(1, abs(phase.value)) * 0.55)
                .scaleEffect(1 - min(1, abs(phase.value)) * 0.12)
        }
        .onTapGesture {
            guard value != selection else { return }
            DialFeedback.shared.detent()
            onSelect(value)
        }
    }

    private func scroll(to index: Int?, animated: Bool) {
        guard let index, values.indices.contains(index) else { return }
        if animated, !reduceMotion {
            withAnimation(.snappy(duration: 0.22)) { position.scrollTo(id: index, anchor: .center) }
        } else {
            position.scrollTo(id: index, anchor: .center)
        }
    }
}
#endif

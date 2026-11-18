#if os(iOS)
import SwiftUI

/// A horizontal ruler that snaps to discrete stops, like a camera's thumb dial.
///
/// The dial is a picker for values the operator reaches by swiping; exact values
/// that are not stops stay owned by the caller's readout (a menu or text field).
/// Only the operator's own swipes, taps and VoiceOver adjustments report selections,
/// so parking beside a typed custom value, or scrolling to reflect an external change,
/// never rewrites the model.
struct RulerDial<Value: Hashable>: View {
    let values: [Value]
    /// The model's value when it is one of the stops; nil when it holds a custom value.
    let selection: Value?
    /// Where the ruler rests while `selection` is nil, normally the nearest stop.
    let parking: Value?
    let spacing: CGFloat
    let identifier: String
    let accessibilityLabel: Text
    let label: (Value) -> String
    let accessibilityValue: (Value) -> String
    /// Read out instead of a stop when the model holds a custom value.
    let customValueDescription: String?
    /// Production-standard stops get a longer tick and a firmer detent, like a dial's click stops.
    let isNotch: (Value) -> Bool
    /// Plays the shared soft click and haptic (`DialFeedback`) for each detent the operator turns.
    let feedback: Bool
    /// Called once per detent while the user scrolls, and for taps and VoiceOver adjustments.
    let onSelect: (Value) -> Void
    /// Called when a user-driven change comes to rest.
    let onSettle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var height: CGFloat = 56
    @State private var position: ScrollPosition
    @State private var centered: Int?
    /// True only while the operator's finger moves the ruler or its fling decelerates;
    /// programmatic animations and a touch that never moves do not select.
    @State private var userDriven = false

    init(values: [Value], selection: Value?, parking: Value? = nil, spacing: CGFloat = 56,
         identifier: String, accessibilityLabel: Text, label: @escaping (Value) -> String,
         accessibilityValue: @escaping (Value) -> String, customValueDescription: String? = nil,
         isNotch: @escaping (Value) -> Bool = { _ in false }, feedback: Bool = true,
         onSelect: @escaping (Value) -> Void, onSettle: @escaping () -> Void = {}) {
        self.values = values
        self.selection = selection
        self.parking = parking
        self.spacing = spacing
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
        self.label = label
        self.accessibilityValue = accessibilityValue
        self.customValueDescription = customValueDescription
        self.isNotch = isNotch
        self.feedback = feedback
        self.onSelect = onSelect
        self.onSettle = onSettle
        let resting = Self.index(of: selection ?? parking, in: values)
        _position = State(initialValue: ScrollPosition(id: resting ?? 0, anchor: .center))
        _centered = State(initialValue: resting)
    }

    private static func index(of value: Value?, in values: [Value]) -> Int? {
        guard let value else { return nil }
        return values.firstIndex(of: value)
    }

    private var restingIndex: Int? { Self.index(of: selection ?? parking, in: values) }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(values.indices, id: \.self) { index in
                        tick(index)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollPosition($position, anchor: .center)
            // Half-width margins let the first and last stops reach the indicator.
            .contentMargins(.horizontal, max(0, (proxy.size.width - spacing) / 2), for: .scrollContent)
            .onScrollGeometryChange(for: Int.self) { geometry in
                // contentInsets includes the margins, so offset + inset is the centred cell's leading edge.
                Int(((geometry.contentOffset.x + geometry.contentInsets.leading) / spacing).rounded())
            } action: { _, raw in
                guard !values.isEmpty else { return }
                let index = min(max(raw, 0), values.count - 1)
                guard index != centered else { return }
                centered = index
                guard userDriven else { return }
                if feedback { DialFeedback.shared.detent(notch: isNotch(values[index])) }
                if values[index] != selection { onSelect(values[index]) }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking:
                    if feedback { DialFeedback.shared.prepare() }
                case .interacting:
                    userDriven = true
                case .animating:
                    userDriven = false
                case .idle:
                    guard userDriven else { return }
                    userDriven = false
                    onSettle()
                    // The model may hold a value other than the one under the indicator,
                    // for example if a stop was rejected; show what the model holds.
                    scroll(to: restingIndex, animated: true)
                default:
                    break
                }
            }
            // The first layout passes settle the width after the initial position was requested.
            .onChange(of: proxy.size.width) { _, _ in
                guard !userDriven else { return }
                scroll(to: restingIndex, animated: false)
            }
        }
        .frame(height: height)
        .mask {
            // Fade the ends so the ruler reads as continuing beyond the card.
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.14),
                                   .init(color: .black, location: 0.86),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Palette.text)
                .frame(width: 2, height: 26)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
        }
        .onAppear { scroll(to: restingIndex, animated: false) }
        .onChange(of: restingIndex) { _, index in
            // External edits (presets, reset, typing, import) only move the ruler.
            guard !userDriven else { return }
            scroll(to: index, animated: true)
        }
        .onChange(of: values) { _, _ in
            guard !userDriven else { return }
            scroll(to: restingIndex, animated: false)
        }
        // The scrolling content's accessibility frame spans the whole ruler, far wider than
        // the visible dial; a clear overlay gives VoiceOver and tests the dial's real frame.
        .accessibilityHidden(true)
        .overlay {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(Text(verbatim: selection.map(accessibilityValue) ?? customValueDescription ?? ""))
                .accessibilityAdjustableAction { direction in
                    // A custom value moves to the neighbour of the stop the ruler is parked on;
                    // with no usable value at all, increment starts at the first stop and
                    // decrement at the last.
                    let target: Int
                    if let base = restingIndex {
                        target = direction == .increment ? base + 1 : base - 1
                    } else {
                        target = direction == .increment ? 0 : values.count - 1
                    }
                    guard values.indices.contains(target) else { return }
                    onSelect(values[target])
                    onSettle()
                }
                .accessibilityIdentifier(identifier)
        }
    }

    private func tick(_ index: Int) -> some View {
        let value = values[index]
        let selected = value == selection
        let notch = isNotch(value)
        return VStack(spacing: 6) {
            Text(verbatim: label(value))
                .font(.system(.caption2, design: .monospaced).weight(selected ? .semibold : notch ? .medium : .regular))
                .monospacedDigit()
                .foregroundStyle(selected || notch ? Palette.text : Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxHeight: .infinity, alignment: .bottom)
            Canvas { context, size in
                // One major tick per stop, longer at notches, with quarter-step minor ticks.
                let majorHeight = notch ? size.height : size.height * 0.7
                let majorWidth: CGFloat = notch ? 2 : 1.5
                let major = Path(CGRect(x: size.width / 2 - majorWidth / 2, y: size.height - majorHeight,
                                        width: majorWidth, height: majorHeight))
                context.fill(major, with: .color(notch ? Palette.text : Palette.muted))
                for fraction in [0.0, 0.25, 0.75] {
                    let minor = Path(CGRect(x: size.width * fraction - 0.5, y: size.height * 0.55,
                                            width: 1, height: size.height * 0.45))
                    context.fill(minor, with: .color(Palette.mutedDeep))
                }
            }
            .frame(height: 18)
            .padding(.bottom, 6)
        }
        .frame(width: spacing)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture {
            guard value != selection else { return }
            if feedback { DialFeedback.shared.detent(notch: notch) }
            onSelect(value)
            onSettle()
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

/// A full-width surface with the field label and its readout on one row and a dial below.
/// It mirrors FieldCard's surface so dial rows sit in the same groups as menu rows.
struct DialFieldCard<Readout: View, Dial: View>: View {
    let title: LocalizedStringKey
    let readout: Readout
    let dial: Dial
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: LocalizedStringKey, @ViewBuilder readout: () -> Readout, @ViewBuilder dial: () -> Dial) {
        self.title = title
        self.readout = readout()
        self.dial = dial()
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        label
                        readout.frame(maxWidth: .infinity, minHeight: Layout.controlHeight, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 10) {
                        label
                        Spacer(minLength: 8)
                        readout
                    }
                    .frame(minHeight: Layout.controlHeight)
                }
            }
            .font(.system(.body, design: .monospaced))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            dial
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var label: some View {
        Text(title)
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

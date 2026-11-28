#if os(iOS)
import SwiftUI

/// A snapping dial with a horizontal ruler or a vertical camera thumbwheel face.
///
/// The dial is a picker for values the operator reaches by swiping; exact values
/// that are not stops stay owned by the caller's readout (a menu or text field).
/// Only the operator's own swipes, taps and VoiceOver adjustments report selections,
/// so parking beside a typed custom value, or scrolling to reflect an external change,
/// never rewrites the model.
struct RulerDial<Value: Hashable>: View {
    enum Face { case ruler, verticalWheel }
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
    let face: Face
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
         isNotch: @escaping (Value) -> Bool = { _ in false }, face: Face = .ruler, feedback: Bool = true,
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
        self.face = face
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
    private var vertical: Bool { face == .verticalWheel }

    private var scrollingStops: some View {
        let vertical = self.vertical
        return GeometryReader { proxy in
            let length = vertical ? proxy.size.height : proxy.size.width
            ScrollView(vertical ? .vertical : .horizontal) {
                if vertical {
                    LazyVStack(spacing: 0) { stops }.scrollTargetLayout()
                } else {
                    LazyHStack(spacing: 0) { stops }.scrollTargetLayout()
                }
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollPosition($position, anchor: .center)
            // Both end stops need enough inset to reach the fixed center indicator.
            .contentMargins(vertical ? .vertical : .horizontal, max(0, (length - spacing) / 2), for: .scrollContent)
            .onScrollGeometryChange(for: Int.self) { geometry in
                let offset = vertical ? geometry.contentOffset.y + geometry.contentInsets.top
                                      : geometry.contentOffset.x + geometry.contentInsets.leading
                return Int((offset / spacing).rounded())
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
            .onChange(of: length) { _, _ in
                guard !userDriven else { return }
                scroll(to: restingIndex, animated: false)
            }
        }
    }

    var body: some View {
        scrollingStops
            .frame(height: vertical ? spacing * 3 : height)
            .mask {
                // Fade the ends so the ruler reads as continuing beyond the card.
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.14),
                                       .init(color: .black, location: 0.86),
                                       .init(color: .clear, location: 1)],
                               startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
            }
            .overlay(alignment: vertical ? .center : .bottom) {
                if vertical {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.line)
                        .frame(height: spacing)
                        .padding(.horizontal, 4)
                        .allowsHitTesting(false)
                } else {
                    Capsule()
                        .fill(Palette.text)
                        .frame(width: 2, height: 26)
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if vertical {
                    let rim = RoundedRectangle(cornerRadius: 9, style: .continuous)
                    rim.fill(LinearGradient(colors: [Palette.background, Palette.controlSurface, Palette.background],
                                            startPoint: .top, endPoint: .bottom))
                        .overlay { rim.strokeBorder(Palette.line, lineWidth: 1) }
                        .allowsHitTesting(false)
                }
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
            // The content spans every stop. Expose one adjustable element inside the visible dial.
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

    private var stops: some View {
        ForEach(values.indices, id: \.self) { index in
            let value = values[index]
            Group {
                if vertical { wheelRow(value) }
                else { tick(value) }
            }
            .contentShape(.rect)
            .onTapGesture {
                guard value != selection else { return }
                if feedback { DialFeedback.shared.detent(notch: isNotch(value)) }
                onSelect(value)
                onSettle()
            }
            .id(index)
        }
    }

    private func wheelRow(_ value: Value) -> some View {
        Text(verbatim: label(value))
            .font(.subheadline.monospaced().weight(value == selection ? .semibold : .regular))
            .foregroundStyle(value == selection ? Palette.text : Palette.muted)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: spacing)
            .background {
                Canvas { context, size in
                    // Grip ridges travel with the drum on either side of the printed names.
                    for tooth in 0..<7 {
                        let y = (CGFloat(tooth) + 0.5) * size.height / 7
                        for x in [8, size.width - 20] {
                            let ridge = CGRect(x: x, y: y, width: 12, height: 1)
                            context.fill(Path(ridge), with: .color(Palette.mutedDeep))
                            context.fill(Path(ridge.offsetBy(dx: 0, dy: 1)), with: .color(.black))
                        }
                    }
                }
            }
            .scrollTransition(.interactive.threshold(.centered), axis: .vertical) { [reduceMotion] row, phase in
                row.scaleEffect(x: 1, y: reduceMotion ? 1 : 1 - 0.18 * abs(phase.value))
            }
    }

    private func tick(_ value: Value) -> some View {
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

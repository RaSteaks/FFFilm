import SwiftUI

/// Reuses the app metadata for the year and owner; the notice is identical in both app languages.
struct AppCopyrightFooter: View {
    var body: some View {
        if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
            Text(verbatim: "Copyright \(copyright)")
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("app-copyright")
        }
    }
}

// Shared primitives keep desktop density separate from touch-oriented presentation.
struct FieldCard<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var usesAccessibilityLayout: Bool {
        usesCompactLayout && dynamicTypeSize.isAccessibilitySize
    }

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Group {
            #if os(macOS)
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel
                content
                    .font(.system(size: 13))
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
            #else
            if usesAccessibilityLayout {
                // Accessibility sizes need vertical growth; a compact HStack would overlap menu labels.
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel
                    content
                        .font(.system(.body, design: .monospaced))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else if usesCompactLayout {
                // Compact rows preserve a 44-point control region without the tall desktop card stack.
                HStack(spacing: 10) {
                    fieldLabel.frame(width: 76, alignment: .leading)
                    content
                        .font(.system(.body, design: .monospaced))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel
                    content
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: Layout.controlHeight, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            #endif
        }
        #if !os(macOS)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        #endif
    }

    private var fieldLabel: some View {
        Text(title)
            // Labels use the system face; only measurements and control values
            // use monospaced figures so translated labels can wrap naturally.
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A quiet section surface replaces a border around every individual field.
/// It stays a static container so the same grouping works in the phone stack,
/// iPad split layout and compact macOS workbench.
struct ParameterGroup<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line.opacity(0.8)) }
    }
}

struct Detail: View {
    private let localizedText: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        localizedText = text
    }

    var body: some View {
        Text(localizedText)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkbenchPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.68 : 1) : 0.38)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }
}

struct PresetButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Desktop presets use compact pointer targets; touch platforms keep their 44pt controls.
    private var presetHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }
    private var presetRadius: CGFloat {
        #if os(macOS)
        7
        #else
        22
        #endif
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(selected ? Palette.background : Palette.text)
            .padding(.horizontal, 13)
            .frame(minHeight: presetHeight)
            .background(selected ? Palette.text : Palette.controlSurface, in: RoundedRectangle(cornerRadius: presetRadius))
            .overlay { RoundedRectangle(cornerRadius: presetRadius).stroke(selected ? Color.clear : Palette.line) }
            .contentShape(.rect(cornerRadius: presetRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.38)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }
}

enum Layout {
    /// Usable workbench width at which the controls and result fit side by side.
    static let wideContentThreshold: CGFloat = 900
    static let workbenchColumnSpacing: CGFloat = 16
    #if os(macOS)
    static let shutterResultMinimumHeight: CGFloat = 100
    static let controlHeight: CGFloat = 28
    static let maximumContentWidth: CGFloat = 1120
    static let pageGutter: CGFloat = 24
    static let sectionSpacing: CGFloat = 18
    #else
    static let shutterResultMinimumHeight: CGFloat = 150
    static let controlHeight: CGFloat = 44
    static let maximumContentWidth: CGFloat = 1180
    static let phoneMaximumContentWidth: CGFloat = 920
    static let pageGutter: CGFloat = 12
    static let sectionSpacing: CGFloat = 12
    #endif
}

/// Keeps both workbench children alive while a resized iPad switches between
/// two columns and a result-first stack, preserving in-progress field drafts.
struct AdaptiveWorkbenchLayout: SwiftUI.Layout {
    let wide: Bool
    let resultFirstWhenStacked: Bool
    let leadingFraction: CGFloat
    // Preserve the existing column gap and the section token for stacked panels.
    private var spacing: CGFloat { wide ? Layout.workbenchColumnSpacing : Layout.sectionSpacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        guard subviews.count == 2 else { return .zero }
        if wide {
            let leadingWidth = max(0, (width - spacing) * leadingFraction)
            let trailingWidth = max(0, width - spacing - leadingWidth)
            let leading = subviews[0].sizeThatFits(.init(width: leadingWidth, height: nil))
            let trailing = subviews[1].sizeThatFits(.init(width: trailingWidth, height: nil))
            return CGSize(width: width, height: max(leading.height, trailing.height))
        }
        let first = subviews[0].sizeThatFits(.init(width: width, height: nil))
        let second = subviews[1].sizeThatFits(.init(width: width, height: nil))
        return CGSize(width: width, height: first.height + spacing + second.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if wide {
            let leadingWidth = max(0, (bounds.width - spacing) * leadingFraction)
            let trailingWidth = max(0, bounds.width - spacing - leadingWidth)
            subviews[0].place(at: bounds.origin, proposal: .init(width: leadingWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + leadingWidth + spacing, y: bounds.minY),
                              proposal: .init(width: trailingWidth, height: nil))
        } else {
            let firstIndex = resultFirstWhenStacked ? 1 : 0
            let secondIndex = 1 - firstIndex
            let firstHeight = subviews[firstIndex].sizeThatFits(.init(width: bounds.width, height: nil)).height
            subviews[firstIndex].place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
            subviews[secondIndex].place(at: CGPoint(x: bounds.minX, y: bounds.minY + firstHeight + spacing),
                                        proposal: .init(width: bounds.width, height: nil))
        }
    }
}

enum Palette {
    static let background = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let surface = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let controlSurface = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let text = Color(red: 242 / 255, green: 242 / 255, blue: 242 / 255)
    static let muted = Color(red: 166 / 255, green: 166 / 255, blue: 166 / 255)
    static let mutedDeep = Color(red: 118 / 255, green: 118 / 255, blue: 118 / 255)
    static let line = Color.white.opacity(0.14)
}

extension View {
    func fieldPicker(compact: Bool) -> some View {
        pickerStyle(.menu)
            .labelsHidden()
            .lineLimit(1)
            // Native iPad menus still need a full touch region in regular width.
            .frame(maxWidth: .infinity, minHeight: Layout.controlHeight, alignment: compact ? .trailing : .leading)
    }

    @ViewBuilder
    func workbenchSurface(cornerRadius: CGFloat) -> some View {
        #if os(macOS)
        // Desktop content stays opaque and quiet; native window chrome owns toolbar materials.
        background(Palette.surface, in: RoundedRectangle(cornerRadius: min(cornerRadius, 12)))
            .overlay {
                RoundedRectangle(cornerRadius: min(cornerRadius, 12)).stroke(Palette.line.opacity(0.6))
            }
        #else
        // iOS uses Liquid Glass when available and keeps material surfaces on earlier releases.
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Palette.line) }
        }
        #endif
    }

    @ViewBuilder
    func workbenchNumberStyle() -> some View {
        #if os(macOS)
        textFieldStyle(.roundedBorder)
        #else
        textFieldStyle(.plain)
        #endif
    }

    @ViewBuilder
    func numericKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func shutterInputToolbar(focusedInput: FocusState<ShutterInputField?>.Binding) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("shutter.done") { focusedInput.wrappedValue = nil }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .accessibilityIdentifier("shutter-done")
            }
        }
        #else
        self
        #endif
    }

    /// The recording-duration draft commits through DONE; decimalPad on iOS
    /// has no return key, so this toolbar is the explicit submit affordance.
    @ViewBuilder
    func durationInputToolbar(commit: @escaping () -> Void, focus: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    commit()
                    focus.wrappedValue = false
                } label: {
                    Text("duration.done")
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .accessibilityIdentifier("duration-done")
            }
        }
        #else
        self
        #endif
    }
}

import SwiftUI

#if os(iOS)
import UIKit
#endif

private struct RateResultOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    // Both calculator tabs share their model, while each page retains its own editor state.
    @State private var store = CalculatorStore()
    @State private var showsCameras = false
    #if os(iOS)
    @State private var negativeStore: NegativeStore
    @State private var selectedTab: MobileTab = .rate
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @State private var filmStore = FilmStore()
    #endif

    init() {
        #if os(iOS)
        // Own the workspace before its tab appears so cold-open URLs are not lost.
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["NEGATIVE_UI_CAMERA"] == "1" {
            _negativeStore = State(initialValue: NegativeStore(camera: NegativeCameraFixture()))
            return
        }
        #endif
        _negativeStore = State(initialValue: NegativeStore())
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
            mobileTabs
                .onOpenURL { url in
                    showsCameras = false
                    selectedTab = .negative
                    negativeStore.openExternalFile(url)
                }
                .sensoryFeedback(.selection, trigger: selectedTab)
                .onChange(of: selectedTab) { _, tab in
                    switch tab {
                    case .rate: store.setActiveView(.rate)
                    case .shutter: store.setActiveView(.shutter)
                    case .negative, .settings: store.clearTransientState()
                    }
                }
            #else
            Group {
                if store.activeView == .film {
                    FilmWorkbenchView(store: filmStore)
                } else {
                    CalculatorWorkbench(store: store, view: store.activeView, showsCameras: $showsCameras)
                }
            }
            .frame(minWidth: store.activeView == .film ? FilmWorkbenchView.minimumWindowWidth : 760, minHeight: 560)
            .toolbar { MacWorkbenchToolbar(store: store) }
            .focusedSceneValue(\.calculatorStore, store)
            // Protect unsaved film documents even when another workbench is selected.
            .background(FilmWindowGuard(store: filmStore))
            .sensoryFeedback(.selection, trigger: store.activeView)
            // The desktop toolbar binds activeView directly, so clear page feedback here.
            .onChange(of: store.activeView) { _, _ in store.clearTransientState() }
            #endif
        }
        // Present outside the compact tab shell so iPad sheets retain their
        // native regular-width list/detail presentation and window adaptation.
        .sheet(isPresented: $showsCameras) { CameraLibraryView(store: store) }
        .tint(Palette.text)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: store.settings)
    }

    #if os(iOS)
    private enum MobileTab: Hashable {
        case rate, shutter, negative, settings
    }

    private var mobileTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("nav.calculate", systemImage: "plus.forwardslash.minus", value: MobileTab.rate) {
                CalculatorWorkbench(store: store, view: .rate, showsCameras: $showsCameras)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
            }
            .accessibilityIdentifier("tab-rate")

            Tab("nav.shutter", systemImage: "camera.aperture", value: MobileTab.shutter) {
                CalculatorWorkbench(store: store, view: .shutter, showsCameras: $showsCameras)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
            }
            .accessibilityIdentifier("tab-shutter")

            // Negative preview is a separate iOS workspace; calculator state stays untouched.
            Tab("negative.title", systemImage: "photo", value: MobileTab.negative) {
                NegativePreviewView(store: negativeStore)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
            }
            .accessibilityIdentifier("tab-negative")

            Tab("nav.settings", systemImage: "gearshape", value: MobileTab.settings) {
                // Settings has its own navigation bar and is a persistent tab, not a sheet.
                NavigationStack {
                    SettingsView()
                        .navigationBarTitleDisplayMode(.large)
                }
                .environment(\.horizontalSizeClass, horizontalSizeClass)
            }
            .accessibilityIdentifier("tab-settings")
        }
        .tabViewStyle(.tabBarOnly)
        // Keep navigation at the bottom on iPad too. Restore the real size class
        // inside each tab so wide forms and camera-library split navigation survive.
        .environment(\.horizontalSizeClass, .compact)
    }
    #endif
}

/// Fixed page identity preserves scroll position and drafts when switching iOS tabs.
private struct CalculatorWorkbench: View {
    let store: CalculatorStore
    let view: CalculatorView
    @Binding var showsCameras: Bool
    @State private var keyboardVisible = false
    @State private var compactSummaryVisible = false

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let maximumWidth: CGFloat = isPad ? Layout.maximumContentWidth : Layout.phoneMaximumContentWidth
            #else
            let maximumWidth = Layout.maximumContentWidth
            #endif
            let contentWidth = min(max(0, geometry.size.width - Layout.pageGutter * 2), maximumWidth)
            // A 55% form panel needs roughly 486pt for its native pickers.
            let isWide = contentWidth >= Layout.wideContentThreshold
            #if os(iOS)
            // iPad can split SHUTTER; iPhone keeps its original stacked layout.
            let shutterWide = isPad && isWide
            #else
            let shutterWide = false
            #endif
            let isCompactPhone = geometry.size.width < 600

            ZStack(alignment: .top) {
                Palette.background.ignoresSafeArea()

                calculatorWorkbench(contentWidth: contentWidth,
                                    maximumWidth: maximumWidth,
                                    isWide: isWide,
                                    shutterWide: shutterWide,
                                    isCompactPhone: isCompactPhone)
            }
            .animation(.snappy(duration: 0.18), value: compactSummaryVisible)
        }
        .onChange(of: view) { _, _ in compactSummaryVisible = false }
        .onDisappear {
            compactSummaryVisible = false
            keyboardVisible = false
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
            compactSummaryVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        #endif
    }

    /// The scrolling RATE/SHUTTER workbench; kept separate from the full-bleed film editor.
    private func calculatorWorkbench(contentWidth: CGFloat, maximumWidth: CGFloat, isWide: Bool,
                                     shutterWide: Bool, isCompactPhone: Bool) -> some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Layout.sectionSpacing) {
                        #if os(iOS)
                        // macOS keeps navigation and calculator actions in the window toolbar.
                        HeaderView(store: store, view: view, availableWidth: contentWidth)
                        #endif
                        FeedbackBanner(store: store)

                        if view == .rate {
                            RateView(store: store,
                                     showsCameras: $showsCameras,
                                     contentWidth: contentWidth,
                                     isWide: isWide,
                                     scrollProxy: proxy)
                        } else {
                            ShutterView(store: store, isWide: shutterWide, scrollProxy: proxy)
                        }

                        Text("footer.estimate")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Palette.mutedDeep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .accessibilityLabel(Text("footer.estimateAccessibility"))
                    }
                    .frame(maxWidth: maximumWidth)
                    .padding(.horizontal, Layout.pageGutter)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(.named("workbenchScroll"))
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(RateResultOffsetKey.self) { offset in
                    guard isCompactPhone, view == .rate else {
                        compactSummaryVisible = false
                        return
                    }
                    compactSummaryVisible = offset < -8 && !keyboardVisible
                }
            }

            if compactSummaryVisible && view == .rate && !keyboardVisible {
                CompactRateSummary(store: store)
                    .padding(.horizontal, Layout.pageGutter)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

#if os(iOS)
private struct HeaderView: View {
    let store: CalculatorStore
    let view: CalculatorView
    let availableWidth: CGFloat
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact || availableWidth < 640
        #else
        false
        #endif
    }

    var body: some View {
        // Page actions stay near the result; top-level navigation lives in TabView.
        HStack(spacing: 8) {
            title
            Spacer(minLength: 4)
            actions
        }
        .padding(usesCompactLayout ? 12 : 14)
        .workbenchSurface(cornerRadius: 16)
        .onDisappear {
            copyResetTask?.cancel()
            copied = false
        }
    }

    private var title: some View {
        Text("app.title")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.7)
            .lineLimit(1)
            .accessibilityIdentifier("app-title")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 7) {
            if view == .rate {
                Button {
                    store.pinCurrentSetup()
                } label: {
                    HStack(spacing: 4) {
                        // Compact headers use the symbol and count so Chinese labels do not wrap.
                        if usesCompactLayout {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                        } else {
                            Label("nav.addComparison", systemImage: "plus")
                        }
                        Text("\(store.pinnedSetups.count)/4")
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(store.pinnedSetups.count >= 4)
                .accessibilityLabel(Text("nav.addComparison"))
                .accessibilityValue("\(store.pinnedSetups.count)/4")
                .accessibilityIdentifier("pin-action")
                .accessibilityHint(Text("comparison.addHint"))

                Button(action: copyCurrent) {
                    actionLabel(copied ? "nav.copied" : "nav.copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("copy-action")
                .accessibilityHint(Text("copy.summaryHint"))
                .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }

                moreMenu
            } else if view == .shutter {
                Button(action: copyCurrent) {
                    actionLabel(copied ? "nav.copied" : "nav.copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(store.shutterCalculation.exposure == nil)
                .accessibilityIdentifier("copy-action")
                .accessibilityHint(Text("copy.shutterHint"))

                moreMenu
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    private var moreMenu: some View {
        Menu {
            if view == .rate {
                Button("nav.copyLink", systemImage: "link") {
                    PlatformClipboard.copy(store.configurationText)
                }
            }
            Button("nav.reset", systemImage: "arrow.counterclockwise") {
                store.resetActiveView()
            }
            .accessibilityIdentifier("reset-action")
        } label: {
            // IconOnly and TitleAndIcon are distinct label-style types, so the
            // compact decision branches instead of going through one ternary.
            if usesCompactLayout {
                Label("nav.more", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Label("nav.more", systemImage: "ellipsis.circle")
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: 44)
            }
        }
        .accessibilityIdentifier("more-action")
        .help(Text("nav.more"))
    }

    private func copyCurrent() {
        let summary = view == .rate
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
    }

    @ViewBuilder
    private func actionLabel(_ key: LocalizedStringKey, systemImage: String) -> some View {
        if usesCompactLayout {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Palette.controlSurface, in: Circle())
                .overlay { Circle().stroke(Palette.line) }
                .accessibilityLabel(Text(key))
        } else {
            Label(key, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(minHeight: Layout.controlHeight)
                .padding(.horizontal, 10)
                .background(Palette.controlSurface, in: Capsule())
                .overlay { Capsule().stroke(Palette.line) }
        }
    }
}
#endif

private struct FeedbackBanner: View {
    let store: CalculatorStore

    var body: some View {
        if let message = store.feedbackMessage {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: store.resetUndoAvailable ? "arrow.triangle.2.circlepath" : "info.circle")
                }
                .font(.callout)
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)

                if store.resetUndoAvailable {
                    Button("nav.undo") { store.undoReset() }
                        .buttonStyle(.bordered)
                        .frame(minHeight: Layout.controlHeight)
                        .accessibilityIdentifier("reset-undo")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.line) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("feedback-banner")
        }
    }
}

private struct RateView: View {
    let store: CalculatorStore
    @Binding var showsCameras: Bool
    let contentWidth: CGFloat
    let isWide: Bool
    let scrollProxy: ScrollViewProxy

    var body: some View {
        VStack(spacing: Layout.sectionSpacing) {
            // Favorites stay directly below the page actions on phones.
            QuickStartView(store: store, showsCameras: $showsCameras)
            AdaptiveWorkbenchLayout(wide: isWide, resultFirstWhenStacked: true, leadingFraction: 0.55) {
                CaptureControls(store: store, availableWidth: isWide ? (contentWidth - Layout.workbenchColumnSpacing) * 0.55 : contentWidth)
                RateResults(store: store, showsScrollOffset: !isWide)
                    .accessibilitySortPriority(isWide ? 0 : 1)
            }
            if !store.pinnedSetups.isEmpty {
                PinnedSetups(store: store)
            }
        }
    }
}

private struct CaptureControls: View {
    let store: CalculatorStore
    let availableWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var durationFocused: Bool
    @State private var durationDraft = ""
    @State private var durationInitialized = false
    @State private var durationError: String?
    @State private var durationPending = false

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact || availableWidth < 410 || dynamicTypeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            ParameterGroup(title: "group.format") {
                formatFields
            }
            ParameterGroup(title: "group.storagePlan") {
                storageFields
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture-controls")
        .onAppear {
            // Seed once: an empty draft must survive returning from another tab.
            guard !durationInitialized else { return }
            durationDraft = DisplayFormat.number(store.settings.shootHours, decimals: 2)
            durationInitialized = true
        }
        // Leaving a tab dismisses editing without discarding an unfinished duration.
        .onDisappear { durationFocused = false }
        .onChange(of: store.settings.shootHours) { _, value in
            durationDraft = DisplayFormat.number(value, decimals: 2)
            durationError = nil
            durationPending = false
        }
    }

    @ViewBuilder
    private var formatFields: some View {
        if usesCompactLayout {
            VStack(spacing: 4) {
                cameraField
                modeField
                resolutionField
                codecField
                cadenceField
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                cameraField
                modeField
                resolutionField
                codecField
                cadenceField
            }
        }
    }

    @ViewBuilder
    private var storageFields: some View {
        if usesCompactLayout {
            VStack(spacing: 4) {
                FieldCard("field.media") { mediaPicker }
                durationField
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                FieldCard("field.media") { mediaPicker }
                durationField
            }
        }
    }

    private var cameraField: some View {
        FieldCard(store.currentCamera.isStandaloneProRes ? "field.source" : "field.camera") {
            Picker("field.camera", selection: Binding(get: { store.settings.cameraId }, set: store.selectCamera)) {
                ForEach(CameraManufacturer.allCases, id: \.self) { manufacturer in
                    let items = store.sortedCameras.filter { $0.manufacturer == manufacturer }
                    if !items.isEmpty {
                        Section(manufacturer.rawValue) {
                            ForEach(items) { camera in
                                Text(verbatim: camera.name).tag(camera.id)
                            }
                        }
                    }
                }
            }
            .fieldPicker(compact: usesCompactLayout)
            .accessibilityIdentifier("capture-camera")
        }
    }

    private var modeField: some View {
        FieldCard(store.currentCamera.isStandaloneProRes ? "field.frame" : "field.mode") {
            Picker("field.mode", selection: Binding(get: { store.settings.modeId }, set: store.selectMode)) {
                ForEach(store.currentCamera.modes) { mode in
                    Text(verbatim: mode.label).tag(mode.id)
                }
            }
            .fieldPicker(compact: usesCompactLayout)
            .accessibilityIdentifier("capture-mode")
        }
    }

    private var resolutionField: some View {
        FieldCard(store.currentCamera.isStandaloneProRes ? "field.size" : "field.resolution") {
            Picker("field.resolution", selection: Binding(get: { store.settings.resolutionId }, set: store.selectResolution)) {
                ForEach(store.currentMode.resolutions) { resolution in
                    Text(verbatim: resolution.label).tag(resolution.id)
                }
            }
            .fieldPicker(compact: usesCompactLayout)
            .accessibilityIdentifier("capture-resolution")
        }
    }

    private var codecField: some View {
        FieldCard("field.codec") {
            Picker("field.codec", selection: Binding(get: { store.settings.codecId }, set: store.selectCodec)) {
                ForEach(store.availableCodecs) { codec in
                    Text(verbatim: codec.name).tag(codec.id)
                }
            }
            .fieldPicker(compact: usesCompactLayout)
            .accessibilityIdentifier("capture-codec")
        }
    }

    private var cadenceField: some View {
        Group {
            if store.currentCamera.isStandaloneProRes {
                FieldCard("field.projectFps") {
                    Picker("field.projectFps", selection: Binding(get: { store.settings.projectFps }, set: store.selectProjectFps)) {
                        ForEach(store.catalog.projectFrameRates, id: \.self) { fps in
                            Text(DisplayFormat.fps(fps)).tag(fps)
                        }
                    }
                    .fieldPicker(compact: usesCompactLayout)
                    .accessibilityIdentifier("capture-project-fps")
                }
            } else {
                FieldCard("field.sensorFps") {
                    Picker("field.sensorFps", selection: Binding(get: { store.settings.sensorFps }, set: store.selectSensorFps)) {
                        ForEach(store.availableSensorFrameRates, id: \.self) { fps in
                            Text(DisplayFormat.fps(fps)).tag(fps)
                        }
                    }
                    .fieldPicker(compact: usesCompactLayout)
                    .accessibilityIdentifier("capture-sensor-fps")
                }
            }
            if store.currentCamera.supportsSensorOverdrive == true {
                FieldCard("field.overdrive") {
                    Toggle("field.overdrive", isOn: Binding(get: { store.settings.sensorOverdrive }, set: store.setSensorOverdrive))
                        .accessibilityIdentifier("capture-overdrive")
                }
            }
        }
    }

    private var mediaPicker: some View {
        Picker("field.media", selection: Binding(get: { store.settings.mediaId }, set: store.selectMedia)) {
            ForEach(store.catalog.mediaOptions) { media in
                Text(verbatim: media.label).tag(media.id)
            }
        }
        .fieldPicker(compact: usesCompactLayout)
        .accessibilityIdentifier("capture-media")
    }

    private var durationField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCard("field.duration") {
                HStack(spacing: 8) {
                    TextField("duration.placeholder", text: $durationDraft)
                        .workbenchNumberStyle()
                        .numericKeyboard()
                        .focused($durationFocused)
                        .multilineTextAlignment(usesCompactLayout ? .trailing : .leading)
                        .frame(maxWidth: .infinity, minHeight: Layout.controlHeight)
                        .onChange(of: durationDraft) { _, newValue in
                            validateDuration(newValue)
                        }
                        .onSubmit {
                            commitDurationDraft()
                            durationFocused = false
                        }
                        .onChange(of: durationFocused) { _, focused in
                            // Losing focus with a valid draft commits it; iOS
                            // decimalPad offers no return key of its own.
                            if !focused { commitDurationDraft() }
                        }
                        .durationInputToolbar(commit: commitDurationDraft, focus: $durationFocused)
                        .accessibilityLabel(Text("field.duration"))
                        .accessibilityHint(Text("duration.actualHint"))
                        .accessibilityIdentifier("capture-duration")
                    Text("h")
                        .foregroundStyle(Palette.muted)
                    Stepper("duration.stepper", value: durationBinding, in: 0.25 ... 24, step: 0.25)
                        .labelsHidden()
                        .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                        .accessibilityIdentifier("duration-stepper")
                }
            }

            if let durationError {
                Label(durationError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("duration-error")
            }
            if durationPending {
                Label("duration.pending", systemImage: "clock")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("duration-pending")
            }

            HStack(spacing: 6) {
                Text("duration.quick")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                ForEach([1.0, 4.0, 8.0, 12.0], id: \.self) { hours in
                    Button {
                        durationDraft = DisplayFormat.number(hours, decimals: 2)
                        durationError = nil
                        durationPending = false
                        store.setShootHours(hours)
                    } label: {
                        Text(DisplayFormat.number(hours, decimals: 0))
                            .monospacedDigit()
                            .frame(minWidth: 38, minHeight: Layout.controlHeight)
                    }
                    .buttonStyle(PresetButtonStyle(selected: store.settings.shootHours == hours))
                    .accessibilityLabel(Text("\(DisplayFormat.number(hours, decimals: 0)) hours"))
                    .accessibilityIdentifier("duration-quick-\(Int(hours))")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .id("capture-duration-field")
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { store.settings.shootHours },
            set: { newValue in
                durationDraft = DisplayFormat.number(newValue, decimals: 2)
                durationError = nil
                durationPending = false
                store.setShootHours(newValue)
            }
        )
    }

    private func validateDuration(_ text: String) {
        // Typing only validates: intermediate drafts ("2", "2.") never touch the
        // plan, so a half-typed decimal cannot clobber the field mid-edit.
        guard let value = parsedDuration(text) else {
            durationError = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "duration.empty", defaultValue: "Enter the actual recording time.", comment: "Empty recording-duration validation.")
                : String(localized: "duration.invalid", defaultValue: "Enter a value from 0.25 to 24 hours.", comment: "Recording-duration validation range.")
            durationPending = true
            return
        }
        durationError = nil
        // A valid draft stays uncommitted until submit, DONE or focus loss.
        durationPending = value != store.settings.shootHours
    }

    private func parsedDuration(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard !normalized.isEmpty, let value = Double(normalized),
              value.isFinite, (0.25 ... 24).contains(value) else { return nil }
        return value
    }

    private func commitDurationDraft() {
        // Invalid or empty drafts stay visible with their inline error; the plan
        // keeps the last valid calculation instead of being silently corrected.
        guard let value = parsedDuration(durationDraft) else { return }
        durationDraft = DisplayFormat.number(value, decimals: 2)
        durationError = nil
        durationPending = false
        store.setShootHours(value)
    }
}

private struct RateResults: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    let store: CalculatorStore
    let showsScrollOffset: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var technicalDetailsExpanded = false
    @State private var showsComparison = false
    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        // `store.calculation` is computed, so binding it once stops this body and
        // the trailing modifiers from re-running the engine on every read.
        let result = store.calculation
        return VStack(alignment: .leading, spacing: usesCompactLayout ? 12 : 16) {
            let selectedCardLabel = String(localized: "result.selectedCard")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour)))
                    .font(.system(size: usesCompactLayout ? 38 : 46, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: result.sensorGbPerHour))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text("\(unit.symbol)/h")
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("result.bitrate")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    Text("\(DisplayFormat.number(result.sensorMbps)) Mb/s")
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour))) \(unit.symbol) per hour, \(DisplayFormat.number(result.sensorMbps)) megabits per second"))

            planningRow(title: "result.planCapacity",
                        value: DisplayFormat.compactStorage(result.dayTotalGb, unit: unit),
                        detail: String(localized: "result.planDetail",
                                       defaultValue: "\(DisplayFormat.duration(store.settings.shootHours)) actual recording",
                                       comment: "Plan total is based on the actual recording duration."))
                .accessibilityIdentifier("plan-capacity-output")
            planningRow(title: "result.actualDuration",
                        value: DisplayFormat.duration(store.settings.shootHours),
                        detail: String(localized: "result.actualDetail",
                                       defaultValue: "actual capture time",
                                       comment: "Clarifies that planned duration means real capture time."))
                .accessibilityIdentifier("record-time-output")
            planningRow(title: "result.cardDuration",
                        value: DisplayFormat.duration(result.captureRuntimeHours),
                        // Keep the capacity comparison in this row without adding
                        // a separate warning to the compact result surface.
                        detail: "\(DisplayFormat.compactStorage(result.media.capacityGb, unit: unit)) · \(selectedCardLabel) · \(result.media.label) · \(DisplayFormat.number(result.dayUsagePercent, decimals: 0))%")
                .accessibilityIdentifier("card-runtime-output")

            HStack(spacing: 8) {
                Button { store.pinCurrentSetup() } label: {
                    Label {
                        Text("nav.addComparison")
                        Text("\(store.pinnedSetups.count)/4")
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.pinnedSetups.count >= 4)
                .accessibilityIdentifier("comparison-add")

                Button("nav.viewComparison") { showsComparison = true }
                    .buttonStyle(.bordered)
                    .disabled(store.pinnedSetups.isEmpty)
                    .accessibilityIdentifier("comparison-view")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(Palette.line)
            DisclosureGroup(isExpanded: $technicalDetailsExpanded) {
                technicalDetails(result)
            } label: {
                Text("result.technicalDetails")
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: Layout.controlHeight, alignment: .leading)
            }
            .accessibilityIdentifier("rate-technical-details")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(usesCompactLayout ? 14 : 18)
        .workbenchSurface(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .textSelection(.enabled)
        .accessibilityIdentifier("rate-results")
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: result.sensorGbPerHour)
        .background {
            if showsScrollOffset {
                GeometryReader { proxy in
                    Color.clear.preference(key: RateResultOffsetKey.self,
                                           value: proxy.frame(in: .named("workbenchScroll")).minY)
                }
            }
        }
        .sheet(isPresented: $showsComparison) {
            ComparisonSheet(store: store)
        }
    }

    private func planningRow(title: LocalizedStringKey, value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.trailing)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // @ViewBuilder is required for multi-statement members outside `body`.
    // The result is passed in so this disclosure reuses the single evaluation.
    @ViewBuilder
    private func technicalDetails(_ result: Calculation) -> some View {
        let playbackLabel = String(localized: "result.playback")
        let basisLabel = String(localized: "result.basis")
        let activeAreaLabel = String(localized: "result.activeArea")
        let captureLabel = String(localized: "result.captureRateDetail")
        let basis = result.camera.isStandaloneProRes ? "PROJECT FPS" : "SENSOR FPS"
        VStack(alignment: .leading, spacing: 8) {
            Text("\(playbackLabel): \(DisplayFormat.duration(result.projectRuntimeHours)) @ \(DisplayFormat.fps(store.settings.projectFps))")
            Text("\(basisLabel): \(basis)")
            if !result.camera.isStandaloneProRes, store.settings.sensorFps != store.settings.projectFps {
                Text("\(captureLabel) @ \(DisplayFormat.fps(store.settings.sensorFps)) → \(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour))) \(unit.symbol)/h")
            }
            if !result.camera.isStandaloneProRes {
                Text("\(activeAreaLabel): \(DisplayFormat.number(result.clipWidthMm, decimals: 2)) × \(DisplayFormat.number(result.clipHeightMm, decimals: 2)) mm · Ø \(DisplayFormat.number(result.imageCircleMm)) · \(DisplayFormat.number(result.formatFactor, decimals: 2))× S35")
            }
            Detail("technical.videoEstimate")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
    }
}

private struct CompactRateSummary: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    let store: CalculatorStore

    var body: some View {
        let result = store.calculation
        let planLabel = String(localized: "result.planCapacity")
        HStack(spacing: 10) {
            Text("\(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour))) \(unit.symbol)/h")
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
            Spacer(minLength: 8)
            Text("\(planLabel) \(DisplayFormat.compactStorage(result.dayTotalGb, unit: unit))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(Palette.line) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour))) \(unit.symbol) per hour, plan \(DisplayFormat.compactStorage(result.dayTotalGb, unit: unit))"))
        .accessibilityIdentifier("rate-compact-summary")
    }
}

private struct PinnedSetups: View {
    let store: CalculatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("nav.viewComparison")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Palette.muted)
            ForEach(Array(store.pinnedSetups.enumerated()), id: \.element.id) { index, pin in
                PinnedSetupRow(index: index, pin: pin) {
                    store.removePinnedSetup(id: pin.id)
                }
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .workbenchSurface(cornerRadius: 14)
        .textSelection(.enabled)
        .accessibilityIdentifier("pinned-setups")
    }
}

private struct PinnedSetupRow: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    let index: Int
    let pin: PinnedSetup
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", index + 1)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(pin.calculation.camera.name) · \(pin.calculation.codec.name)")
                    .lineLimit(2)
                Text("\(DisplayFormat.fps(pin.calculation.camera.isStandaloneProRes ? pin.settings.projectFps : pin.settings.sensorFps)) · \(DisplayFormat.humanDuration(pin.calculation.captureRuntimeHours)) / \(pin.calculation.media.label)")
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Text("\(DisplayFormat.number(unit.converted(decimalGB: pin.calculation.sensorGbPerHour)))\n\(unit.symbol)/h")
                .multilineTextAlignment(.trailing)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(WorkbenchPressStyle())
            .accessibilityLabel(Text("comparison.remove"))
        }
        .padding(.vertical, 4)
    }
}

private struct ComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    let store: CalculatorStore

    var body: some View {
        NavigationStack {
            List {
                if store.pinnedSetups.isEmpty {
                    ContentUnavailableView("comparison.empty", systemImage: "square.stack.3d.up.slash")
                } else {
                    ForEach(store.pinnedSetups) { pin in
                        ComparisonSnapshotRow(store: store, pin: pin, unit: unit)
                    }
                }
            }
            .navigationTitle("nav.viewComparison")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("nav.done") { dismiss() }
                        .accessibilityIdentifier("comparison-done")
                }
            }
        }
        .tint(Palette.text)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 700, minHeight: 520, idealHeight: 680)
        #else
        .presentationDetents([.large])
        #endif
    }
}

private struct ComparisonSnapshotRow: View {
    let store: CalculatorStore
    let pin: PinnedSetup
    let unit: StorageUnit

    var body: some View {
        // Catalog mode names are verbatim technical terms and never localized.
        let modeLabel = pin.calculation.mode.label
        let fps = pin.calculation.camera.isStandaloneProRes ? pin.settings.projectFps : pin.settings.sensorFps
        // Standalone ProRes captures at project cadence; camera profiles use sensor cadence.
        let fpsLabel: LocalizedStringKey = pin.calculation.camera.isStandaloneProRes ? "field.projectFps" : "field.sensorFps"
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(pin.calculation.camera.name)
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    store.removePinnedSetup(id: pin.id)
                } label: {
                    Label("comparison.remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("comparison-remove-\(pin.id.uuidString)")
            }
            Text("\(modeLabel) · \(pin.calculation.resolution.label) · \(pin.calculation.codec.name)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(fpsLabel, value: "\(DisplayFormat.fps(fps)) fps")
            LabeledContent("result.perHour", value: "\(DisplayFormat.number(unit.converted(decimalGB: pin.calculation.sensorGbPerHour))) \(unit.symbol)/h · \(DisplayFormat.number(pin.calculation.sensorMbps)) Mb/s")
            LabeledContent("result.planCapacity", value: "\(DisplayFormat.number(pin.settings.shootHours, decimals: 2)) h · \(DisplayFormat.compactStorage(pin.calculation.dayTotalGb, unit: unit))")
            LabeledContent("result.cardDuration", value: "\(DisplayFormat.duration(pin.calculation.captureRuntimeHours)) · \(pin.calculation.media.label)")
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comparison-snapshot-\(pin.id.uuidString)")
    }
}

private struct ShutterView: View {
    let store: CalculatorStore
    let isWide: Bool
    let scrollProxy: ScrollViewProxy
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedInput: ShutterInputField?
    // Draft text belongs to the editor; only parsed numeric values enter the pure calculation model.
    @State private var drafts: [ShutterInputField: String] = [:]
    @State private var validatedFields: Set<ShutterInputField> = []
    @State private var resultHeight: CGFloat = 0
    @State private var editingResultHeight: CGFloat = 0
    @State private var importFeedback: String?
    private var result: ShutterCalculation { store.shutterCalculation }

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
            // A single layout keeps focused fields and draft text alive through
            // resizing. iPad and compact iPhone lead with the result; regular
            // iPhone width keeps the original controls-first stack.
            let resultFirstWhenStacked = UIDevice.current.userInterfaceIdiom == .pad || usesCompactLayout
            AdaptiveWorkbenchLayout(wide: isWide, resultFirstWhenStacked: resultFirstWhenStacked, leadingFraction: 0.55) {
                controls
                shutterResult.accessibilitySortPriority(!isWide && resultFirstWhenStacked ? 1 : 0)
            }
            #else
            VStack(spacing: Layout.sectionSpacing) {
                controls
                shutterResult
            }
            #endif
        }
        // Tab switches cancel focus-driven scrolling while preserving input drafts.
        .onDisappear { focusedInput = nil }
        .shutterInputToolbar(focusedInput: $focusedInput)
        .task(id: focusedInput) {
            #if os(iOS)
            guard let field = focusedInput else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            scrollProxy.scrollTo(field, anchor: .center)
            #endif
        }
        .onChange(of: focusedInput) { old, new in
            if let old { validatedFields.insert(old) }
            if old == nil, new != nil { editingResultHeight = resultHeight }
        }
        .onChange(of: store.shutterInputRevision) { _, _ in
            drafts.removeAll()
            validatedFields.removeAll()
            importFeedback = nil
            focusedInput = nil
        }
        .onChange(of: store.shutterSettings.mode) { _, _ in
            focusedInput = nil
            importFeedback = nil
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldCard("shutter.field.mode") {
                Picker("shutter.field.mode", selection: value(\.mode)) {
                    ForEach(ShutterMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .fieldPicker(compact: usesCompactLayout)
                .accessibilityIdentifier("shutter-mode")
            }
            Button {
                focusedInput = nil
                let imported = store.importShutterFrameRates()
                importFeedback = AppText.imported(sensorFps: imported.sensor, projectFps: imported.project)
                for field in [ShutterInputField.sensorFps, .projectFps] {
                    drafts.removeValue(forKey: field)
                    validatedFields.remove(field)
                }
            } label: {
                Label("shutter.import", systemImage: "arrow.down.doc")
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: Layout.controlHeight)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("shutter-import")
            .accessibilityHint(Text("shutter.importHint"))

            if let importFeedback {
                Label(importFeedback, systemImage: "checkmark.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shutter-import-feedback")
            }

            if usesCompactLayout {
                VStack(spacing: 8) { shutterFields }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], alignment: .leading, spacing: 8) {
                    shutterFields
                }
            }
            Detail("shutter.limitHint")
        }
        #if os(macOS)
        .padding(18)
        .workbenchSurface(cornerRadius: 12)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shutter-controls")
    }

    @ViewBuilder
    private var shutterFields: some View {
        numberField("shutter.field.cameraFPS", field: .sensorFps, suffix: "FPS", presets: true)
        if store.shutterSettings.mode == .conversion {
            FieldCard("shutter.field.input") {
                Picker("shutter.field.input", selection: value(\.direction)) {
                    ForEach(ShutterDirection.allCases) { direction in Text(direction.label).tag(direction) }
                }
                .fieldPicker(compact: usesCompactLayout)
                .accessibilityIdentifier("shutter-direction")
            }
            if store.shutterSettings.direction == .angleToTime {
                numberField("shutter.field.angle", field: .angle, suffix: "°")
            } else {
                numberField("shutter.field.time", field: .shutterDenominator, suffix: "s⁻¹")
            }
        }
        if store.shutterSettings.mode == .matching {
            numberField("shutter.field.projectFPS", field: .projectFps, suffix: "FPS", presets: true)
            FieldCard("shutter.field.match") {
                Picker("shutter.field.match", selection: value(\.match)) {
                    ForEach(ShutterMatch.allCases) { match in Text(match.label).tag(match) }
                }
                .fieldPicker(compact: usesCompactLayout)
                .accessibilityIdentifier("shutter-match")
            }
            numberField("shutter.field.baseline", field: .targetAngle, suffix: "°")
            FieldCard("shutter.field.lightCheck") {
                Toggle("shutter.field.lightCheck", isOn: value(\.checksFlicker))
                    .accessibilityIdentifier("shutter-light-check")
            }
        }
        if store.shutterSettings.mode == .flicker {
            numberField("shutter.field.preferred", field: .preferredAngle, suffix: "°")
        }
        numberField("shutter.field.maxAngle", field: .maxAngle, suffix: "°")
        if store.shutterSettings.needsLight {
            FieldCard("shutter.field.lightSource") {
                Picker("shutter.field.lightSource", selection: value(\.light)) {
                    ForEach(ShutterLight.allCases) { light in Text(light.label).tag(light) }
                }
                .fieldPicker(compact: usesCompactLayout)
                .accessibilityIdentifier("shutter-light-source")
            }
            if store.shutterSettings.light == .custom {
                numberField("shutter.field.lightPulseRate", field: .customLightHz, suffix: "Hz")
            }
            if store.shutterSettings.light == .displays {
                VStack(alignment: .leading, spacing: 4) {
                    FieldCard("shutter.field.displayRates") {
                        TextField("shutter.displayPlaceholder", text: value(\.displayRefreshRates))
                            .workbenchNumberStyle()
                            .frame(minHeight: Layout.controlHeight)
                            .focused($focusedInput, equals: .customLightHz)
                            .submitLabel(.done)
                            .onSubmit { focusedInput = nil }
                            .accessibilityLabel(Text("shutter.displayAccessibility"))
                            .accessibilityIdentifier("shutter-display-rates")
                    }
                    Text("shutter.displayHint")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    if validatedFields.contains(.customLightHz), store.shutterSettings.displayRefreshMilliHz == nil {
                        Label(ShutterSettings.displayRefreshError, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .id(ShutterInputField.customLightHz)
            }
        }
    }

    private var shutterResult: some View {
        let calculation = result
        return VStack(alignment: .leading, spacing: 12) {
            if let exposure = calculation.exposure {
                if store.shutterSettings.mode == .conversion,
                   store.shutterSettings.direction == .angleToTime {
                    Text("shutter.primary.time")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    Text(DisplayFormat.shutterTime(exposure))
                        .font(.system(size: usesCompactLayout ? 34 : 38, weight: .light, design: .monospaced))
                        .monospacedDigit()
                        .accessibilityIdentifier("shutter-time-primary")
                } else {
                    Text(store.shutterSettings.mode == .flicker
                         ? (calculation.compromise == nil ? "shutter.primary.recommended" : "shutter.compromise.title")
                         : "shutter.primary.angle")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    Text("\(DisplayFormat.shutterNumber(exposure.angle))°")
                        .font(.system(size: usesCompactLayout ? 34 : 38, weight: .light, design: .monospaced))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: exposure.angle)
                        .accessibilityIdentifier("shutter-angle-output")
                }
                if !(store.shutterSettings.mode == .conversion && store.shutterSettings.direction == .angleToTime) {
                    Text(DisplayFormat.shutterTime(exposure))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("shutter-time-output")
                } else {
                    Text("\(DisplayFormat.shutterNumber(exposure.angle))°")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("shutter-angle-output")
                }
                Button {
                    PlatformClipboard.copy(store.readableShutterSummary())
                } label: {
                    Label("shutter.copyResult", systemImage: "doc.on.doc")
                        .frame(minHeight: Layout.controlHeight)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("shutter-copy-action")
            }

            switch calculation.status {
            case .invalidInput(let field):
                statusLabel(field.error(for: store.shutterSettings[keyPath: field.keyPath]) ?? String(localized: "shutter.invalid", defaultValue: "Enter a valid value to calculate.", comment: "Invalid shutter result status."), symbol: "pencil.circle")
            case .invalidDisplays:
                statusLabel(ShutterSettings.displayRefreshError, symbol: "pencil.circle")
            case .numericalLimit:
                statusLabel(String(localized: "shutter.numericalLimit", defaultValue: "Values exceed calculation precision. Use a less extreme input.", comment: "Numerical limit status."), symbol: "exclamationmark.triangle")
            case .noCandidates:
                noCandidates
            default:
                EmptyView()
            }

            if calculation.compromise != nil {
                // Keep the qualification visible even when the details disclosure is collapsed.
                statusLabel(String(localized: "shutter.compromise.notice"), symbol: "info.circle")
                    .accessibilityIdentifier("shutter-compromise-notice")
            }
            if calculation.exposure != nil {
                DisclosureGroup {
                    shutterDetails
                } label: {
                    Text("result.technicalDetails")
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: Layout.controlHeight, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("shutter-details")
            }
        }
        .frame(maxWidth: .infinity,
               minHeight: max(store.shutterSettings.mode == .conversion ? Layout.shutterResultMinimumHeight : 0,
                              focusedInput == nil ? 0 : editingResultHeight), alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            resultHeight = height
            if focusedInput != nil { editingResultHeight = max(editingResultHeight, height) }
        }
        .padding(usesCompactLayout ? 14 : 18)
        .workbenchSurface(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .textSelection(.enabled)
        .accessibilityIdentifier("shutter-results")
    }

    private var shutterDetails: some View {
        let calculation = result
        return VStack(alignment: .leading, spacing: 12) {
            if let exposure = calculation.exposure {
                Text(DisplayFormat.exposureDuration(exposure))
                    .font(.system(.caption, design: .monospaced))
                if calculation.status == .exceedsMaximum {
                    statusLabel(AppText.resolve("shutter.overLimit",
                                                defaultValue: "Theoretical angle exceeds the \(DisplayFormat.shutterNumber(store.shutterSettings.maxAngle))° limit. Cannot realize this exposure within the limit.",
                                                comment: "Shutter result exceeds the user-set angle limit."), symbol: "exclamationmark.triangle")
                } else {
                    Detail("shutter.withinLimit")
                }
                if let speed = calculation.playbackSpeed, let duration = calculation.durationMultiplier {
                    Text("\(DisplayFormat.shutterNumber(speed))× PLAYBACK · \(DisplayFormat.shutterNumber(duration))× DURATION")
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityIdentifier("shutter-playback-output")
                    Detail(store.shutterSettings.match == .exposure
                           ? "shutter.matchesExposure"
                           : "shutter.keepsAngle")
                    Detail("shutter.frameByFrame")
                }
            }
            if store.shutterSettings.needsLight {
                if let matches = calculation.matchesLightCycles {
                    let completeKey = store.shutterSettings.light == .displays ? "shutter.displayComplete" : "shutter.complete"
                    let incompleteKey = store.shutterSettings.light == .displays ? "shutter.displayIncomplete" : "shutter.incomplete"
                    statusLabel(matches ? String(localized: String.LocalizationValue(completeKey))
                                : String(localized: String.LocalizationValue(incompleteKey)),
                                symbol: matches ? "checkmark.circle" : "info.circle")
                    if calculation.candidates.isEmpty && calculation.compromise == nil { noCandidates }
                }
                if let compromise = calculation.compromise {
                    Divider().overlay(Palette.line)
                    Text("shutter.compromise.title").font(.system(.caption, design: .monospaced))
                    Text("\(DisplayFormat.shutterNumber(compromise.exposure.angle))° · \(DisplayFormat.shutterTime(compromise.exposure))")
                        .accessibilityIdentifier("shutter-compromise-output")
                    Text(AppText.compromiseError(compromise.worstError))
                    ForEach(compromise.displays) { display in
                        Text(AppText.displayCycleMatch(display))
                            .font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Detail("shutter.compromise.method")
                    if compromise.approximateSearch { Detail("shutter.compromise.approximate") }
                    if store.shutterSettings.mode == .matching { Detail("shutter.referenceOnly") }
                }
                if !calculation.candidates.isEmpty {
                    Divider().overlay(Palette.line)
                    Text(store.shutterSettings.light == .displays ? "shutter.displayCandidates" : "shutter.candidates")
                        .font(.system(.caption, design: .monospaced))
                    ForEach(calculation.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            if store.shutterSettings.light == .displays,
                               let rates = store.shutterSettings.displayRefreshMilliHz {
                                Text("\(DisplayFormat.shutterNumber(candidate.exposure.angle))°")
                                let cyclesLabel = String(localized: "shutter.cycles")
                                Text(rates.map { rate in
                                    let hz = Double(rate) / 1_000
                                    return "\(DisplayFormat.shutterNumber(hz)) Hz × \(DisplayFormat.shutterNumber(candidate.exposure.exposureSeconds * hz)) \(cyclesLabel)"
                                }.joined(separator: " · "))
                            } else {
                                Text("\(DisplayFormat.shutterNumber(candidate.exposure.angle))° · \(DisplayFormat.shutterNumber(candidate.cycles)) LIGHT CYCLES")
                            }
                            Text(DisplayFormat.shutterTime(candidate.exposure))
                                .foregroundStyle(Palette.muted)
                            Text(DisplayFormat.exposureDuration(candidate.exposure))
                                .foregroundStyle(Palette.muted)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityElement(children: .contain)
                    }
                    if store.shutterSettings.mode == .matching {
                        Detail("shutter.referenceOnly")
                    }
                }
                if store.shutterSettings.light == .displays {
                    Detail("shutter.displayModel")
                } else {
                    Detail("shutter.periodicModel")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var noCandidates: some View {
        statusLabel(store.shutterSettings.light == .displays
                    ? String(localized: "shutter.noDisplayCandidates")
                    : String(localized: "shutter.noCandidates", defaultValue: "No complete light-cycle exposure fits the current angle limit. This does not prove that flicker will occur.", comment: "No candidate status."), symbol: "info.circle")
            .accessibilityIdentifier("shutter-no-candidates")
    }

    private func statusLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("shutter-status")
    }

    private func numberField(_ title: LocalizedStringKey, field: ShutterInputField, suffix: String,
                             presets: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCard(title) {
                HStack {
                    TextField(title, text: draft(field))
                        .workbenchNumberStyle()
                        .frame(minHeight: Layout.controlHeight)
                        .multilineTextAlignment(usesCompactLayout ? .trailing : .leading)
                        .numericKeyboard()
                        .focused($focusedInput, equals: field)
                        .submitLabel(.done)
                        .onSubmit { validatedFields.insert(field); focusedInput = nil }
                        .accessibilityLabel(Text(title))
                        .accessibilityHint(Text(suffix))
                        .accessibilityIdentifier("shutter-\(field.rawValue)")
                    Text(verbatim: suffix).foregroundStyle(Palette.muted)
                    if field == .angle {
                        Button("180°") { setNumber(180, field: .angle) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                            .accessibilityLabel(Text("shutter.use180"))
                            .accessibilityIdentifier("shutter-180")
                    }
                    if presets {
                        Menu {
                            ForEach(ShutterFramePreset.allCases) { preset in
                                Button(preset.label) { setNumber(preset.fps, field: field) }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        // Two preset menus can share the screen in matching mode, so
                        // the label names its field; both halves stay localized.
                        .accessibilityLabel(Text(title) + Text(verbatim: " · ") + Text("shutter.presets"))
                        .accessibilityIdentifier("shutter-presets-\(field.rawValue)")
                    }
                }
            }
            if validatedFields.contains(field), let error = field.error(for: store.shutterSettings[keyPath: field.keyPath]) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shutter-error-\(field.rawValue)")
            }
        }
        .id(field)
    }

    private func draft(_ field: ShutterInputField) -> Binding<String> {
        Binding(get: {
            drafts[field] ?? (store.shutterSettings[keyPath: field.keyPath].isFinite
                             ? DisplayFormat.shutterNumber(store.shutterSettings[keyPath: field.keyPath]) : "")
        }, set: { text in
            drafts[field] = text
            // A trailing decimal separator is an unfinished draft, never a silently committed integer.
            let separator = Locale.current.decimalSeparator ?? "."
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: separator, with: ".")
            let parsed = normalized.hasSuffix(".") ? nil : Double(normalized)
            store.updateShutterSettings(parsed ?? .nan, at: field.keyPath)
            validatedFields.remove(field)
        })
    }

    private func setNumber(_ number: Double, field: ShutterInputField) {
        focusedInput = nil
        drafts.removeValue(forKey: field)
        validatedFields.remove(field)
        store.updateShutterSettings(number, at: field.keyPath)
    }

    private func value<Value>(_ keyPath: WritableKeyPath<ShutterSettings, Value>) -> Binding<Value> {
        Binding(get: { store.shutterSettings[keyPath: keyPath] },
                set: { store.updateShutterSettings($0, at: keyPath) })
    }
}

#Preview("Regular Workbench") {
    ContentView().frame(width: 940, height: 760)
}

#Preview("Compact iPhone") {
    ContentView().frame(width: 393, height: 852)
}

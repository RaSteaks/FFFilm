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
            // All desktop workbenches share a footer below their scroll and canvas content.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AppCopyrightFooter()
                    .padding(.horizontal, Layout.pageGutter)
                    .padding(.vertical, 8)
                    .background(Palette.background)
            }
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

                        // Shutter results carry their own model limits; recording provenance
                        // and storage caveats should not appear on the shutter calculator.
                        if view == .rate {
                            Text("footer.estimate")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(Palette.mutedDeep)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                                .accessibilityLabel(Text("footer.estimateAccessibility"))
                        }
                        #if os(iOS)
                        // Keep attribution in the page scroller above the native tab bar.
                        AppCopyrightFooter()
                            .padding(.top, 4)
                        #endif
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
        // Header copying is the same committed calculation as the result-panel action.
        if view == .shutter { store.rememberShutterResult() }
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
            // Select the question first; changing it preserves both planning inputs.
            VStack(alignment: .leading, spacing: 6) {
                Picker("recording.task", selection: Binding(get: { store.recordingTask }, set: { store.recordingTask = $0 })) {
                    ForEach(RecordingTask.allCases) { task in
                        Text(task.label).tag(task)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: Layout.controlHeight)
                .accessibilityIdentifier("recording-task-picker")
                // Field labels explain the task visually; keep extra guidance available to VoiceOver.
                .accessibilityHint(Text(store.recordingTask.hint))
            }
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
            // Establish the recording format before entering the task-specific storage plan.
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
        .onChange(of: store.recordingTask) { _, _ in
            // Commit valid edits before hiding the field; invalid drafts remain available on return.
            commitDurationDraft()
            durationFocused = false
        }
        // Revalidate only the message; preserve the draft and its commit state.
        .onChange(of: AppLanguagePreference.shared.language) { _, _ in
            if durationError != nil { validateDuration(durationDraft) }
        }
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
        if store.recordingTask == .capacity {
            durationField
        } else {
            FieldCard("field.media") { mediaPicker }
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
                ? AppText.resolve("duration.empty", defaultValue: "Enter the actual recording time.", comment: "Empty recording-duration validation.")
                : AppText.resolve("duration.invalid", defaultValue: "Enter a value from 0.25 to 24 hours.", comment: "Recording-duration validation range.")
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
            // The answer to the selected question is primary; rate remains a shared reference.
            VStack(alignment: .leading, spacing: 6) {
                Text(store.recordingTask.label)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                Text(store.recordingTask == .capacity
                     ? DisplayFormat.compactStorage(result.dayTotalGb, unit: unit)
                     : DisplayFormat.duration(result.captureRuntimeHours))
                    .font(.system(size: usesCompactLayout ? 38 : 46, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(store.recordingTask == .capacity ? "plan-capacity-output" : "card-runtime-output")

            if store.recordingTask == .capacity {
                planningRow(title: "field.duration",
                            value: DisplayFormat.duration(store.settings.shootHours))
                    .accessibilityIdentifier("record-time-output")
            } else {
                planningRow(title: "field.media",
                            value: DisplayFormat.compactStorage(result.media.capacityGb, unit: unit),
                            detail: result.media.label)
            }
            planningRow(title: "recording.hourlyData",
                        value: "\(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour))) \(unit.symbol)/h",
                        detail: "\(DisplayFormat.number(result.sensorMbps)) Mb/s")

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

    private func planningRow(title: LocalizedStringKey, value: String, detail: String? = nil) -> some View {
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
                // Secondary text is optional when the row label already explains the value.
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

}

private struct CompactRateSummary: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    let store: CalculatorStore

    var body: some View {
        let result = store.calculation
        let taskLabel = AppText.resource(store.recordingTask.label)
        let answer = store.recordingTask == .capacity
            ? DisplayFormat.compactStorage(result.dayTotalGb, unit: unit)
            : DisplayFormat.duration(result.captureRuntimeHours)
        HStack(spacing: 10) {
            Text(answer)
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(taskLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(Palette.line) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(taskLabel), \(answer)"))
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
            .navigationTitle(AppText.localized("nav.viewComparison"))
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
    @State private var rigDrafts: [ShutterRigID: [ShutterInputField: String]] = [:]
    @State private var rigValidatedFields: [ShutterRigID: Set<ShutterInputField>] = [:]
    @State private var workspaceSheet: ShutterSheet?
    @State private var editingRig: ShutterRigID?
    private var drafts: [ShutterInputField: String] {
        get { rigDrafts[store.shutterWorkspace.selectedRig] ?? [:] }
        nonmutating set { rigDrafts[store.shutterWorkspace.selectedRig] = newValue }
    }
    private var validatedFields: Set<ShutterInputField> {
        get { rigValidatedFields[store.shutterWorkspace.selectedRig] ?? [] }
        nonmutating set { rigValidatedFields[store.shutterWorkspace.selectedRig] = newValue }
    }
    @State private var resultHeight: CGFloat = 0
    @State private var editingResultHeight: CGFloat = 0
    @State private var importFeedback: String?
    @State private var copyRevision = 0
    @State private var showsCopyConfirmation = false
    private var result: ShutterCalculation { store.shutterCalculation }

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: Layout.sectionSpacing) {
            HStack(spacing: 8) {
                Picker("shutter.rig.title", selection: Binding(get: { store.shutterWorkspace.selectedRig }, set: { next in
                    focusedInput = nil
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { store.selectShutterRig(next) }
                })) {
                    ForEach(ShutterRigID.allCases) { rig in Text(verbatim: rig.rawValue).tag(rig) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(minHeight: Layout.controlHeight)
                .accessibilityIdentifier("shutter-rig")
                Button("shutter.library.title", systemImage: "tray.full") {
                    focusedInput = nil
                    store.rememberShutterResult()
                    workspaceSheet = .library
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("shutter-library")
                Button { focusedInput = nil; workspaceSheet = .rig } label: {
                    Image(systemName: "slider.horizontal.3").frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                }
                .buttonStyle(WorkbenchPressStyle())
                .accessibilityLabel(Text("shutter.rig.configure"))
                .accessibilityIdentifier("shutter-rig-configure")
            }
            if !store.shutterWorkspace.active.cameraLabel.isEmpty {
                Text(store.shutterWorkspace.active.cameraLabel).font(.caption).foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("shutter.field.mode", selection: switching(\.mode)) {
                ForEach(ShutterMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: Layout.controlHeight)
            .accessibilityIdentifier("shutter-mode")
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
            if let old, let editingRig {
                // Blur belongs to the rig that owned focus, even if selection has already moved.
                rigValidatedFields[editingRig, default: []].insert(old)
                if editingRig == store.shutterWorkspace.selectedRig { store.rememberShutterResult() }
            }
            if old == nil, new != nil { editingResultHeight = resultHeight }
            editingRig = new == nil ? nil : store.shutterWorkspace.selectedRig
        }
        .onChange(of: store.shutterInputRevision) { _, _ in
            drafts.removeAll()
            validatedFields.removeAll()
            importFeedback = nil
            focusedInput = nil
            showsCopyConfirmation = false
        }
        .onChange(of: store.shutterSettings.mode) { _, _ in
            focusedInput = nil
            importFeedback = nil
        }
        .onChange(of: store.shutterWorkspace.selectedRig) { _, _ in
            focusedInput = nil; importFeedback = nil; showsCopyConfirmation = false
        }
        .sheet(item: $workspaceSheet) { sheet in
            switch sheet {
            case .library: ShutterLibraryView(store: store)
            case .rig: ShutterRigView(store: store)
            case .save(let record): ShutterSaveView(store: store, snapshot: record)
            }
        }
        .task(id: copyRevision) {
            guard showsCopyConfirmation else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            showsCopyConfirmation = false
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if usesCompactLayout {
                VStack(spacing: 8) { shutterFields }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], alignment: .leading, spacing: 8) {
                    shutterFields
                }
            }
        }
        #if os(macOS)
        .padding(18)
        .workbenchSurface(cornerRadius: 12)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shutter-controls")
    }

    // Import is a secondary action of the camera FPS field, with a full accessible
    // label and tooltip so the compact icon remains understandable on every platform.
    private var importFrameRatesButton: some View {
        Button {
            focusedInput = nil
            showsCopyConfirmation = false
            let imported = store.importShutterFrameRates()
            importFeedback = AppText.imported(sensorFps: imported.sensor, projectFps: imported.project)
            for field in [ShutterInputField.sensorFps, .projectFps] {
                drafts.removeValue(forKey: field)
                validatedFields.remove(field)
            }
        } label: {
            Label("shutter.import", systemImage: "arrow.down.doc")
                .labelStyle(.iconOnly)
                .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkbenchPressStyle())
        .accessibilityIdentifier("shutter-import")
        .accessibilityHint(Text("shutter.importHint"))
        .help(Text("shutter.import"))
    }

    @ViewBuilder
    private var shutterFields: some View {
        numberField("shutter.field.cameraFPS", field: .sensorFps, suffix: "FPS", presets: true)
        if store.shutterSettings.mode == .conversion {
            VStack(alignment: .leading, spacing: 8) {
                Picker("shutter.field.input", selection: switching(\.direction)) {
                    ForEach(ShutterDirection.allCases) { direction in Text(direction.label).tag(direction) }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: Layout.controlHeight)
                .accessibilityIdentifier("shutter-direction")
                if store.shutterSettings.direction == .angleToTime {
                    numberField("shutter.field.angle", field: .angle, suffix: "°")
                        .transition(.opacity)
                } else {
                    numberField("shutter.field.time", field: .shutterDenominator, suffix: "")
                        .transition(.opacity)
                }
            }
            .transition(.opacity)
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
                        TextField("shutter.displayPlaceholder", text: displayRefreshDraft)
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
                    Text(calculation.status == .exceedsMaximum ? "shutter.primary.theoretical" :
                            store.shutterSettings.mode == .flicker
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
                if calculation.status == .exceedsMaximum {
                    // Critical feasibility stays beside the answer, outside collapsed details.
                    statusLabel(AppText.shutterOverLimit(store.shutterSettings.maxAngle), symbol: "exclamationmark.triangle")
                        .accessibilityIdentifier("shutter-over-limit")
                    if let alternative = calculation.maximumExposure,
                       let stops = calculation.maximumExposureDifferenceStops {
                        Text(AppText.shutterMaximumAlternative(alternative, stops: stops))
                            .font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("shutter-maximum-alternative")
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        store.rememberShutterResult()
                        PlatformClipboard.copy(store.readableShutterSummary())
                        showsCopyConfirmation = true
                        copyRevision += 1
                    } label: {
                        // Reserve the full action label so completion feedback does not shift the button.
                        ZStack {
                            Label("shutter.copyResult", systemImage: "doc.on.doc").hidden()
                            Label(showsCopyConfirmation ? "shutter.copied" : "shutter.copyResult",
                                  systemImage: showsCopyConfirmation ? "checkmark" : "doc.on.doc")
                        }
                        .frame(minHeight: Layout.controlHeight)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("shutter-copy-action")
                    Button("shutter.library.save", systemImage: "bookmark") {
                        focusedInput = nil
                        if let record = store.currentShutterRecord() { workspaceSheet = .save(record) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("shutter-save-setup")
                }
            }

            if store.shutterSettings.needsLight {
                Text(AppText.shutterLightModel(store.shutterSettings))
                    .font(.caption).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !calculation.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calculation.candidates) { candidate in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(DisplayFormat.shutterNumber(candidate.exposure.angle))° · \(DisplayFormat.shutterTime(candidate.exposure))")
                                    let target = store.shutterSettings.mode == .flicker ? store.shutterSettings.preferredAngle : calculation.exposure?.angle
                                    if let target, let stops = candidate.differenceStops(relativeTo: target) {
                                        Text(AppText.shutterCandidateDifference(stops))
                                            .font(.caption).foregroundStyle(Palette.muted)
                                    }
                                }
                                Spacer(minLength: 4)
                                if store.shutterSettings.mode == .flicker {
                                    Button("shutter.candidate.use") {
                                        focusedInput = nil
                                        drafts.removeValue(forKey: .preferredAngle)
                                        store.chooseShutterCandidate(candidate)
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: Layout.controlHeight)
                                    .accessibilityLabel(Text("shutter.candidate.use") + Text(verbatim: " \(DisplayFormat.shutterNumber(candidate.exposure.angle))°"))
                                    .accessibilityIdentifier("shutter-candidate-\(candidate.cycles)")
                                }
                            }
                        }
                        Text("shutter.candidate.scope").font(.caption).foregroundStyle(Palette.muted)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("shutter-candidates")
                }
            }

            switch calculation.status {
            case .invalidInput(let field):
                statusLabel(field.error(for: store.shutterSettings[keyPath: field.keyPath]) ?? AppText.resolve("shutter.invalid", defaultValue: "Enter a valid value to calculate.", comment: "Invalid shutter result status."), symbol: "pencil.circle")
            case .invalidDisplays:
                statusLabel(ShutterSettings.displayRefreshError, symbol: "pencil.circle")
            case .numericalLimit:
                statusLabel(AppText.resolve("shutter.numericalLimit", defaultValue: "Values exceed calculation precision. Use a less extreme input.", comment: "Numerical limit status."), symbol: "exclamationmark.triangle")
            case .noCandidates:
                noCandidates
            default:
                EmptyView()
            }

            if calculation.compromise != nil {
                // Keep the qualification visible even when the details disclosure is collapsed.
                statusLabel(AppText.localized("shutter.compromise.notice"), symbol: "info.circle")
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
                if calculation.status != .exceedsMaximum {
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
                    statusLabel(matches ? AppText.localized(String.LocalizationValue(completeKey))
                                : AppText.localized(String.LocalizationValue(incompleteKey)),
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
                                let cyclesLabel = AppText.localized("shutter.cycles")
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
                    ? AppText.localized("shutter.noDisplayCandidates")
                    : AppText.resolve("shutter.noCandidates", defaultValue: "No complete light-cycle exposure fits the current angle limit. This does not prove that flicker will occur.", comment: "No candidate status."), symbol: "info.circle")
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
                        .numericKeyboard(allowsTimeExpression: field == .shutterDenominator)
                        .focused($focusedInput, equals: field)
                        .submitLabel(.done)
                        .onSubmit { validatedFields.insert(field); focusedInput = nil }
                        .accessibilityLabel(Text(title))
                        .accessibilityHint(Text(suffix))
                        .accessibilityIdentifier("shutter-\(field.rawValue)")
                    if field == .shutterDenominator {
                        // Expressions contain separators/units; clear explicitly without losing
                        // focus or asking the operator to select individual text tokens.
                        Button {
                            showsCopyConfirmation = false
                            drafts[field] = ""
                            validatedFields.remove(field)
                            store.updateShutterSettings(Double.nan, at: field.keyPath)
                            focusedInput = field
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                        }
                        .buttonStyle(WorkbenchPressStyle())
                        .disabled(draft(field).wrappedValue.isEmpty)
                        .accessibilityLabel(Text("shutter.clearTime"))
                        .accessibilityIdentifier("shutter-clear-time")
                    }
                    if !suffix.isEmpty { Text(verbatim: suffix).foregroundStyle(Palette.muted) }
                    if presets {
                        Menu {
                            // 100/3 is a capture cadence; keep the project-rate preset choices unchanged.
                            ForEach(ShutterFramePreset.allCases.filter { field == .sensorFps || $0 != .fractional100Over3 }) { preset in
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
                    if field == .sensorFps { importFrameRatesButton }
                }
            }
            if presets {
                quickPresets(field: field, values: ShutterFramePreset.quick.map { ($0.shortLabel, $0.fps, $0.label) })
            } else if [.angle, .targetAngle, .preferredAngle].contains(field) {
                quickPresets(field: field, values: [90.0, 172.8, 180, 270].map {
                    (DisplayFormat.shutterNumber($0) + "°", $0, DisplayFormat.shutterNumber($0) + "°")
                })
            } else if field == .shutterDenominator {
                quickPresets(field: field, values: [48.0, 50, 60, 100].map {
                    ("1/" + DisplayFormat.shutterNumber($0), $0, "1/" + DisplayFormat.shutterNumber($0) + " s")
                })
                Text("shutter.timeInputHint")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if field == .sensorFps, let importFeedback {
                Label(importFeedback, systemImage: "checkmark.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shutter-import-feedback")
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

    private var displayRefreshDraft: Binding<String> {
        Binding(get: { store.shutterSettings.displayRefreshRates }, set: { text in
            // Update the live result and valid launch memory while typing; the shared
            // focus/submit handler records history only when editing is completed.
            showsCopyConfirmation = false
            store.updateShutterSettings(text, at: \.displayRefreshRates)
            validatedFields.remove(.customLightHz)
        })
    }

    private func draft(_ field: ShutterInputField) -> Binding<String> {
        Binding(get: {
            if let draft = drafts[field] { return draft }
            let number = store.shutterSettings[keyPath: field.keyPath]
            guard number.isFinite else { return "" }
            let formatted = DisplayFormat.shutterNumber(number)
            return field == .shutterDenominator ? "1/\(formatted) s" : formatted
        }, set: { text in
            // Clear feedback at the edit event; NaN draft settings are not an Equatable trigger.
            showsCopyConfirmation = false
            drafts[field] = text
            // A trailing decimal separator is an unfinished draft, never a silently committed integer.
            let separator = Locale.current.decimalSeparator ?? "."
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: separator, with: ".")
            let parsed = field == .shutterDenominator ? ShutterTimeInput.denominator(text)
                : (normalized.hasSuffix(".") ? nil : Double(normalized))
            store.updateShutterSettings(parsed ?? .nan, at: field.keyPath)
            validatedFields.remove(field)
        })
    }

    private func setNumber(_ number: Double, field: ShutterInputField) {
        showsCopyConfirmation = false
        focusedInput = nil
        drafts.removeValue(forKey: field)
        validatedFields.remove(field)
        store.updateShutterSettings(number, at: field.keyPath)
        store.rememberShutterResult()
    }

    /// Presets reuse the existing monochrome button style and exact model values.
    private func quickPresets(field: ShutterInputField, values: [(String, Double, String)]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(values, id: \.1) { title, number, accessibleLabel in
                    let selected = store.shutterSettings[keyPath: field.keyPath] == number
                    Button(title) { setNumber(number, field: field) }
                        .buttonStyle(PresetButtonStyle(selected: selected))
                        .accessibilityLabel(accessibleLabel)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("shutter-quick-\(field.rawValue)-\(number)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Animate only explicit task/direction changes. Fields retain their identity and
    /// draft storage, and native SwiftUI transactions can be interrupted by another tap.
    private func switching<Value>(_ keyPath: WritableKeyPath<ShutterSettings, Value>) -> Binding<Value> {
        Binding(get: { store.shutterSettings[keyPath: keyPath] }, set: { next in
            focusedInput = nil
            showsCopyConfirmation = false
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                store.updateShutterSettings(next, at: keyPath)
            }
            store.rememberShutterResult()
        })
    }

    private func value<Value>(_ keyPath: WritableKeyPath<ShutterSettings, Value>) -> Binding<Value> {
        Binding(get: { store.shutterSettings[keyPath: keyPath] },
                set: {
                    showsCopyConfirmation = false
                    store.updateShutterSettings($0, at: keyPath)
                    store.rememberShutterResult()
                })
    }
}

#Preview("Regular Workbench") {
    ContentView().frame(width: 940, height: 760)
}

#Preview("Compact iPhone") {
    ContentView().frame(width: 393, height: 852)
}

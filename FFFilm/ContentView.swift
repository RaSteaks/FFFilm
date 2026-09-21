import SwiftUI

struct ContentView: View {
    @State private var store = CalculatorStore()

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Layout.sectionSpacing) {
                        #if os(macOS)
                        HStack {
                            Text(store.activeView == .rate ? "Recording calculator" : "Shutter workbench")
                                .font(.title2.weight(.semibold))
                            Spacer()
                            Text("FORMAT & DATA")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("app-title")
                        }
                        .padding(.bottom, 4)
                        #else
                        HeaderView(store: store)
                        #endif
                        if store.activeView == .rate {
                            RateView(store: store)
                        } else {
                            ShutterView(store: store, scrollProxy: proxy)
                        }
                        Text("ESTIMATES · PRORES TARGETS APR 2022 · VERIFY AGAINST CAMERA")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Palette.mutedDeep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .accessibilityLabel("Estimates. Verify against the selected camera and recording media.")
                    }
                    .frame(maxWidth: Layout.maximumContentWidth)
                    .padding(.horizontal, Layout.pageGutter)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                // Both supported platforms use native scroll-driven keyboard dismissal.
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .tint(Palette.text)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: store.activeView)
        .sensoryFeedback(.selection, trigger: store.settings)
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560)
        .toolbar { MacWorkbenchToolbar(store: store) }
        .focusedSceneValue(\.calculatorStore, store)
        #endif
    }
}

private struct HeaderView: View {
    @Bindable var store: CalculatorStore
    @State private var copied = false
    @State private var pinFeedback = 0
    @State private var resetFeedback = 0
    @State private var copyResetTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if usesCompactLayout {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        title
                        SettingsButton()
                        Spacer(minLength: 8)
                        actions
                    }
                    viewPicker.frame(maxWidth: .infinity)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        title
                        SettingsButton()
                        Spacer(minLength: 12)
                        viewPicker
                        actions
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { title; SettingsButton(); Spacer(); actions }
                        viewPicker
                    }
                }
            }
        }
        .padding(usesCompactLayout ? 12 : 14)
        .workbenchSurface(cornerRadius: 16)
        .onDisappear { copyResetTask?.cancel() }
    }

    private var title: some View {
        Text("FORMAT & DATA")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.7)
            .lineLimit(1)
            .accessibilityIdentifier("app-title")
    }

    private var viewPicker: some View {
        Picker("View", selection: $store.activeView) {
            ForEach(CalculatorView.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: usesCompactLayout ? .infinity : 250)
        .accessibilityIdentifier("calculator-view-picker")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if store.activeView == .rate {
                Button {
                    store.pinCurrentSetup()
                    pinFeedback += 1
                } label: {
                    actionLabel(
                        "PIN",
                        systemImage: store.pinnedSetups.isEmpty ? "pin" : "pin.fill"
                    )
                }
                .disabled(store.pinnedSetups.count >= 4)
                .accessibilityIdentifier("pin-action")
                .accessibilityHint("Pins the current setup for comparison")
                .sensoryFeedback(.impact(weight: .light), trigger: pinFeedback)

                Button {
                    PlatformClipboard.copy(store.configurationText)
                    copied = true
                    // Keep the visible success state stable across repeated copy taps.
                    copyResetTask?.cancel()
                    copyResetTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                } label: {
                    actionLabel(copied ? "COPIED" : "COPY", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("copy-action")
                .accessibilityHint("Copies the current configuration")
                .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }
            }

            Button {
                store.resetActiveView()
                resetFeedback += 1
            } label: {
                actionLabel("RESET", systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("reset-action")
            .accessibilityHint("Restores defaults for the current view")
            .sensoryFeedback(.selection, trigger: resetFeedback)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    @ViewBuilder
    private func actionLabel(_ text: String, systemImage: String) -> some View {
        if usesCompactLayout {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Palette.controlSurface, in: Circle())
                .overlay { Circle().stroke(Palette.line) }
                .accessibilityLabel(text)
        } else {
            Label(text, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(minHeight: Layout.controlHeight)
                .padding(.horizontal, 10)
                .background(Palette.controlSurface, in: Capsule())
                .overlay { Capsule().stroke(Palette.line) }
        }
    }
}

private struct RateView: View {
    let store: CalculatorStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: Layout.sectionSpacing) {
            QuickStartView(store: store)
            if usesCompactLayout {
                // Phone users keep the live meter in view while tuning the denser field rows.
                RateResults(store: store)
                CaptureControls(store: store)
            } else {
                CaptureControls(store: store)
                RateResults(store: store)
            }
            if !store.pinnedSetups.isEmpty { PinnedSetups(store: store) }
        }
    }
}

private struct CaptureControls: View {
    let store: CalculatorStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 8)]

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            #if os(macOS)
            VStack(alignment: .leading, spacing: 14) {
                Text("RECORDING SETUP")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    formatFields
                }
                Divider()
                // Fill the timing row rather than leaving an unused adaptive-grid column on wide windows.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    timingFields
                }
            }
            .padding(18)
            .workbenchSurface(cornerRadius: 12)
            #else
            if usesCompactLayout {
                VStack(spacing: 8) { fields }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) { fields }
            }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture-controls")
    }

    @ViewBuilder
    private var fields: some View {
        formatFields
        timingFields
    }

    @ViewBuilder
    private var formatFields: some View {
        FieldCard(store.currentCamera.isStandaloneProRes ? "SOURCE" : "CAMERA") {
            Picker("Camera", selection: bind({ store.settings.cameraId }, store.selectCamera)) {
                ForEach(CameraManufacturer.allCases, id: \.self) { manufacturer in
                    let items = store.sortedCameras.filter { $0.manufacturer == manufacturer }
                    if !items.isEmpty {
                        Section(manufacturer.rawValue) { ForEach(items) { Text($0.name).tag($0.id) } }
                    }
                }
            }.fieldPicker(compact: usesCompactLayout)
        }
        FieldCard(store.currentCamera.isStandaloneProRes ? "FRAME" : "MODE") {
            Picker("Mode", selection: bind({ store.settings.modeId }, store.selectMode)) {
                ForEach(store.currentCamera.modes) { Text($0.label).tag($0.id) }
            }.fieldPicker(compact: usesCompactLayout)
        }
        FieldCard(store.currentCamera.isStandaloneProRes ? "SIZE" : "RES") {
            Picker("Resolution", selection: bind({ store.settings.resolutionId }, store.selectResolution)) {
                ForEach(store.currentMode.resolutions) { Text($0.label).tag($0.id) }
            }.fieldPicker(compact: usesCompactLayout)
        }
        FieldCard("CODEC") {
            Picker("Codec", selection: bind({ store.settings.codecId }, store.selectCodec)) {
                ForEach(store.availableCodecs) { Text($0.name).tag($0.id) }
            }.fieldPicker(compact: usesCompactLayout)
        }
    }

    @ViewBuilder
    private var timingFields: some View {
        // Camera data rates use sensor cadence; only standalone ProRes exposes project cadence.
        if store.currentCamera.isStandaloneProRes {
            FieldCard("PROJECT FPS") {
                Picker("Project frame rate", selection: bind({ store.settings.projectFps }, store.selectProjectFps)) {
                    ForEach(store.catalog.projectFrameRates, id: \.self) { Text(DisplayFormat.fps($0)).tag($0) }
                }.fieldPicker(compact: usesCompactLayout)
            }
        } else {
            FieldCard("SENSOR FPS") {
                Picker("Sensor frame rate", selection: bind({ store.settings.sensorFps }, store.selectSensorFps)) {
                    ForEach(store.availableSensorFrameRates, id: \.self) { Text(DisplayFormat.fps($0)).tag($0) }
                }.fieldPicker(compact: usesCompactLayout)
            }
        }
        FieldCard("MEDIA") {
            Picker("Media", selection: bind({ store.settings.mediaId }, store.selectMedia)) {
                ForEach(store.catalog.mediaOptions) { Text($0.label).tag($0.id) }
            }.fieldPicker(compact: usesCompactLayout)
        }
        FieldCard("TIME") {
            Stepper(value: bind({ store.settings.shootHours }, store.setShootHours), in: 0.25 ... 24, step: 0.25) {
                Text("\(DisplayFormat.number(store.settings.shootHours, decimals: 2)) H")
                    .monospacedDigit()
            }
        }
        if store.currentCamera.supportsSensorOverdrive == true {
            FieldCard("OVERDRIVE") {
                Toggle("660 FPS", isOn: bind({ store.settings.sensorOverdrive }, store.setSensorOverdrive))
            }
        }
    }

    private func bind<Value>(_ get: @escaping () -> Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

private struct RateResults: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    let store: CalculatorStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var result: Calculation { store.calculation }

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: usesCompactLayout ? 12 : 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    primaryRate
                    Text("\(unit.symbol)/h").foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    bitrate
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        primaryRate
                        Text("\(unit.symbol)/h").foregroundStyle(Palette.muted)
                    }
                    bitrate
                }
            }
            recordingTimeOutput
            Divider().overlay(Palette.line)
            VStack(alignment: .leading, spacing: 8) {
                Detail("PLAYBACK \(DisplayFormat.duration(result.projectRuntimeHours)) @ \(DisplayFormat.fps(store.settings.projectFps))")
                Detail("\(DisplayFormat.number(store.settings.shootHours, decimals: 2)) H DAY → \(DisplayFormat.compactStorage(result.dayTotalGb, unit: unit)) / \(result.media.label) · \(DisplayFormat.number(result.dayUsagePercent, decimals: 0))%\(result.dayUsagePercent > 100 ? " OVER" : "")")
                if !result.camera.isStandaloneProRes, store.settings.sensorFps != store.settings.projectFps {
                    Detail("CAPTURE @ \(DisplayFormat.fps(store.settings.sensorFps)) → \(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour))) \(unit.symbol)/h")
                }
                if !result.camera.isStandaloneProRes {
                    Detail("ACTIVE \(DisplayFormat.number(result.clipWidthMm, decimals: 2)) × \(DisplayFormat.number(result.clipHeightMm, decimals: 2)) MM · Ø \(DisplayFormat.number(result.imageCircleMm)) · \(DisplayFormat.number(result.formatFactor, decimals: 2))× S35")
                }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(usesCompactLayout ? 14 : 18)
        .workbenchSurface(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        // Enable native selection for every result, including derived values and explanatory text.
        .textSelection(.enabled)
        .accessibilityIdentifier("rate-results")
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: result.sensorGbPerHour)
    }

    // Storage planning uses capture rates; standalone ProRes resolves these from project fps.
    private var primaryRate: some View {
        Text(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour)))
            .font(.system(size: usesCompactLayout ? 34 : 38, weight: .light, design: .monospaced))
            .monospacedDigit()
            .contentTransition(.numericText(value: result.sensorGbPerHour))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var bitrate: some View {
        Text("\(DisplayFormat.number(result.sensorMbps)) Mb/s")
            .foregroundStyle(Palette.muted)
            .monospacedDigit()
    }

    private var recordingTimeOutput: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("EST. RECORD TIME")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(DisplayFormat.duration(result.captureRuntimeHours))
                .font(.system(size: usesCompactLayout ? 18 : 20, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("/ \(result.media.label)")
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estimated recording time \(DisplayFormat.duration(result.captureRuntimeHours)) on \(result.media.label)")
        .accessibilityIdentifier("record-time-output")
    }
}

private struct PinnedSetups: View {
    let store: CalculatorStore

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(store.pinnedSetups.enumerated()), id: \.element.id) { index, pin in
                PinnedSetupRow(index: index, pin: pin) {
                    store.removePinnedSetup(id: pin.id)
                }
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .workbenchSurface(cornerRadius: 14)
        // Enable native selection for every result, including derived values and explanatory text.
        .textSelection(.enabled)
        .accessibilityIdentifier("pinned-setups")
    }
}

private struct PinnedSetupRow: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal
    let index: Int
    let pin: PinnedSetup
    let remove: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if usesCompactLayout {
                // Compact rows preserve a 44-point control region without the tall desktop card stack.
                HStack(spacing: 10) {
                    Text(String(format: "%02d", index + 1)).foregroundStyle(Palette.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(pin.calculation.camera.name) · \(pin.calculation.codec.name)")
                            .lineLimit(1)
                        Text("\(DisplayFormat.fps(pin.calculation.camera.isStandaloneProRes ? pin.settings.projectFps : pin.settings.sensorFps)) · \(DisplayFormat.humanDuration(pin.calculation.captureRuntimeHours)) / \(pin.calculation.media.label)")
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 6)
                    Text("\(DisplayFormat.number(unit.converted(decimalGB: pin.calculation.sensorGbPerHour)))\n\(unit.symbol)/h")
                        .multilineTextAlignment(.trailing)
                    removeButton
                }
            } else {
                HStack(spacing: 10) {
                    Text(String(format: "%02d", index + 1)).foregroundStyle(Palette.muted)
                    Text("\(pin.calculation.camera.name) · \(pin.calculation.codec.name) · \(DisplayFormat.fps(pin.calculation.camera.isStandaloneProRes ? pin.settings.projectFps : pin.settings.sensorFps))").lineLimit(1)
                    Spacer()
                    Text("\(DisplayFormat.number(unit.converted(decimalGB: pin.calculation.sensorGbPerHour))) \(unit.symbol)/h")
                    Text("\(DisplayFormat.humanDuration(pin.calculation.captureRuntimeHours)) / \(pin.calculation.media.label)").foregroundStyle(Palette.muted)
                    removeButton
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var removeButton: some View {
        Button(action: remove) {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(WorkbenchPressStyle())
        .accessibilityLabel("Remove pinned setup")
    }
}

private struct ShutterView: View {
    let store: CalculatorStore
    let scrollProxy: ScrollViewProxy
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedInput: ShutterInputField?
    // Draft text belongs to the editor; only parsed numeric values enter the pure calculation model.
    @State private var drafts: [ShutterInputField: String] = [:]
    @State private var validatedFields: Set<ShutterInputField> = []
    @State private var resultHeight: CGFloat = 0
    @State private var editingResultHeight: CGFloat = 0
    private var result: ShutterCalculation { store.shutterCalculation }
    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 16)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 8)]
    #endif

    private var usesCompactLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: Layout.sectionSpacing) {
            if usesCompactLayout { shutterResult }
            controls
            if !usesCompactLayout { shutterResult }
        }
        .shutterInputToolbar(focusedInput: $focusedInput)
        .task(id: focusedInput) {
            #if os(iOS)
            // Wait for the keyboard inset before centering the active field in the single page scroller.
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
            focusedInput = nil
        }
        .onChange(of: store.shutterSettings.mode) { _, _ in focusedInput = nil }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldCard("MODE") {
                Picker("Shutter mode", selection: value(\.mode)) {
                    ForEach(ShutterMode.allCases) { Text($0.label).tag($0) }
                }
                .fieldPicker(compact: usesCompactLayout)
                .accessibilityIdentifier("shutter-mode")
            }
            Button {
                focusedInput = nil
                store.importShutterFrameRates()
                for field in [ShutterInputField.sensorFps, .projectFps] {
                    drafts.removeValue(forKey: field)
                    validatedFields.remove(field)
                }
            } label: {
                Label("USE RATE FPS", systemImage: "arrow.down.doc")
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: Layout.controlHeight)
            }
            .accessibilityIdentifier("shutter-import")
            .accessibilityHint("Copies both frame rates once. RATE remains unchanged.")
            if usesCompactLayout {
                VStack(spacing: 8) { shutterFields }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) { shutterFields }
            }
            Detail("USER-SET THEORETICAL LIMIT · VERIFY CAMERA SUPPORT")
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
        numberField("CAMERA FPS", field: .sensorFps, suffix: "FPS", presets: true)
        if store.shutterSettings.mode == .conversion {
            FieldCard("INPUT") {
                Picker("Conversion input", selection: value(\.direction)) {
                    ForEach(ShutterDirection.allCases) { Text($0.label).tag($0) }
                }.fieldPicker(compact: usesCompactLayout)
                    .accessibilityIdentifier("shutter-direction")
            }
            if store.shutterSettings.direction == .angleToTime {
                numberField("ANGLE", field: .angle, suffix: "°")
            } else {
                numberField("TIME: 1 /", field: .shutterDenominator, suffix: "s⁻¹")
            }
        }
        if store.shutterSettings.mode == .matching {
            numberField("PROJECT FPS", field: .projectFps, suffix: "FPS", presets: true)
            FieldCard("MATCH") {
                Picker("Match target", selection: value(\.match)) {
                    ForEach(ShutterMatch.allCases) { Text($0.label).tag($0) }
                }.fieldPicker(compact: usesCompactLayout)
                    .accessibilityIdentifier("shutter-match")
            }
            numberField("BASELINE", field: .targetAngle, suffix: "°")
            FieldCard("LIGHT CHECK") {
                Toggle("Check light cycles", isOn: value(\.checksFlicker))
                    .accessibilityIdentifier("shutter-light-check")
            }
        }
        if store.shutterSettings.mode == .flicker {
            numberField("PREFERRED", field: .preferredAngle, suffix: "°")
        }
        numberField("MAX ANGLE", field: .maxAngle, suffix: "°")
        if store.shutterSettings.needsLight {
            FieldCard("LIGHT SOURCE") {
                Picker("Light source", selection: value(\.light)) {
                    ForEach(ShutterLight.allCases) { Text($0.label).tag($0) }
                }.fieldPicker(compact: usesCompactLayout)
                    .accessibilityIdentifier("shutter-light-source")
            }
            if store.shutterSettings.light == .custom {
                numberField("LIGHT PULSE RATE", field: .customLightHz, suffix: "Hz")
            }
        }
    }

    private var shutterResult: some View {
        let calculation = result
        return VStack(alignment: .leading, spacing: 12) {
            if let exposure = calculation.exposure {
                Text(store.shutterSettings.mode == .flicker ? "RECOMMENDED CANDIDATE" : "CAMERA SHUTTER")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                Text("\(DisplayFormat.shutterNumber(exposure.angle))°")
                    .font(.system(size: usesCompactLayout ? 34 : 38, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: exposure.angle)
                    .accessibilityIdentifier("shutter-angle-output")
                Text(DisplayFormat.shutterTime(exposure))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("shutter-time-output")
            }
            switch calculation.status {
            case .invalidInput(let field):
                statusLabel(validatedFields.contains(field)
                            ? (field.error(for: store.shutterSettings[keyPath: field.keyPath]) ?? "Check the input.")
                            : "Complete a valid input to calculate.", symbol: "pencil.circle")
            case .numericalLimit:
                statusLabel("Values exceed calculation precision. Use a less extreme input.", symbol: "exclamationmark.triangle")
            case .noCandidates:
                noCandidates
            default:
                EmptyView()
            }
            if calculation.exposure != nil {
                // Keep all supporting information behind one disclosure, initially collapsed.
                DisclosureGroup {
                    shutterDetails
                } label: {
                    Text("DETAILS")
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: usesCompactLayout ? 44 : 28)
                }
                // Preserve child identifiers for VoiceOver and UI automation.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("shutter-details")
            }
        }
        // Keep fields in place while a draft temporarily removes candidates or the numeric result.
        // Otherwise the scroll offset can clamp, dismissing the keyboard during text replacement.
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
        // Enable native selection for every result, including derived values and explanatory text.
        .textSelection(.enabled)
        .accessibilityIdentifier("shutter-results")
    }

    // Main and candidate exposure units share the same details section without nested disclosures.
    private var shutterDetails: some View {
        let calculation = result
        return VStack(alignment: .leading, spacing: 12) {
            if let exposure = calculation.exposure {
                Text(DisplayFormat.exposureDuration(exposure))
                    .font(.system(.caption, design: .monospaced))
                if calculation.status == .exceedsMaximum {
                    statusLabel("Theoretical angle exceeds the \(DisplayFormat.shutterNumber(store.shutterSettings.maxAngle))° limit. Cannot realize this exposure within the limit.", symbol: "exclamationmark.triangle")
                } else {
                    Detail("WITHIN USER-SET LIMIT · CAMERA SUPPORT NOT VERIFIED")
                }
                if let speed = calculation.playbackSpeed, let duration = calculation.durationMultiplier {
                    Text("\(DisplayFormat.shutterNumber(speed))× PLAYBACK · \(DisplayFormat.shutterNumber(duration))× DURATION")
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityIdentifier("shutter-playback-output")
                    Detail(store.shutterSettings.match == .exposure
                           ? "MATCHES EXPOSURE AT THE PROJECT BASELINE"
                           : "KEEPS ANGLE · EXPOSURE CHANGES WITH CAMERA FPS")
                    Detail("FRAME-BY-FRAME RETIMING · NO INTERPOLATION OR FRAME BLENDING")
                }
            }
            if store.shutterSettings.needsLight {
                if let matches = calculation.matchesLightCycles {
                    statusLabel(matches ? "Target covers complete light cycles in this model."
                                : "Target does not cover complete light cycles in this model.",
                                symbol: matches ? "checkmark.circle" : "info.circle")
                    if calculation.candidates.isEmpty { noCandidates }
                }
                if !calculation.candidates.isEmpty {
                    Divider().overlay(Palette.line)
                    Text("NEAREST LIGHT-CYCLE CANDIDATES")
                        .font(.system(.caption, design: .monospaced))
                    ForEach(calculation.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(DisplayFormat.shutterNumber(candidate.exposure.angle))° · \(DisplayFormat.shutterNumber(candidate.cycles)) LIGHT CYCLES")
                            Text(DisplayFormat.shutterTime(candidate.exposure))
                                .foregroundStyle(Palette.muted)
                            Text(DisplayFormat.exposureDuration(candidate.exposure))
                                .foregroundStyle(Palette.muted)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityElement(children: .contain)
                    }
                    if store.shutterSettings.mode == .matching {
                        Detail("REFERENCE ONLY · USING A DIFFERENT CANDIDATE CHANGES THE TARGET EXPOSURE")
                    }
                }
                Detail("PERIODIC LIGHT MODEL · VERIFY WITH TEST FOOTAGE. LED/PWM AND ROLLING SHUTTER MAY DIFFER.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var noCandidates: some View {
        statusLabel("No complete light-cycle exposure fits the current angle limit. This does not prove that flicker will occur.", symbol: "info.circle")
            .accessibilityIdentifier("shutter-no-candidates")
    }

    private func statusLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("shutter-status")
    }

    private func numberField(_ title: String, field: ShutterInputField, suffix: String,
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
                        .accessibilityLabel(title)
                        .accessibilityHint(field.error(for: store.shutterSettings[keyPath: field.keyPath]) ?? suffix)
                        .accessibilityIdentifier("shutter-\(field.rawValue)")
                    Text(suffix).foregroundStyle(Palette.muted)
                    if field == .angle {
                        Button("180°") { setNumber(180, field: .angle) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                            .accessibilityLabel("Use 180 degrees")
                            .accessibilityIdentifier("shutter-180")
                    }
                    if presets {
                        // Explain exact fractional cadence in the menu without persistent field helper text.
                        Menu {
                            ForEach(ShutterFramePreset.allCases) { preset in
                                Button(preset.label) { setNumber(preset.fps, field: field) }
                            }
                        } label: {
                            Image(systemName: "list.bullet").frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                        }
                        // Keep the native macOS menu at its intrinsic width beside the numeric editor.
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("\(title) presets")
                    }
                }
            }
            if validatedFields.contains(field), let error = field.error(for: store.shutterSettings[keyPath: field.keyPath]) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
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
            store.shutterSettings[keyPath: field.keyPath] = parsed ?? .nan
            validatedFields.remove(field)
        })
    }

    private func setNumber(_ number: Double, field: ShutterInputField) {
        focusedInput = nil
        drafts.removeValue(forKey: field)
        validatedFields.remove(field)
        store.shutterSettings[keyPath: field.keyPath] = number
    }

    private func value<Value>(_ keyPath: WritableKeyPath<ShutterSettings, Value>) -> Binding<Value> {
        Binding(get: { store.shutterSettings[keyPath: keyPath] }, set: { store.shutterSettings[keyPath: keyPath] = $0 })
    }
}

#Preview("Regular Workbench") {
    ContentView().frame(width: 940, height: 760)
}

#Preview("Compact iPhone") {
    ContentView().frame(width: 393, height: 852)
}

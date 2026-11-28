#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreImage

struct NegativePreviewView: View {
    @Bindable var store: NegativeStore
    @State private var showsFiles = false
    @State private var showsPhotos = false
    @State private var photo: PhotosPickerItem?
    @State private var cameraImmersive = true
    @State private var showsCameraSettings = false
    @State private var showsLookOptions = false
    private let lookPreferences = FilmLookPreferences.shared
    @ScaledMetric(relativeTo: .subheadline) private var filmRowHeight: CGFloat = 40
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var immersive: Bool { store.isCamera && cameraImmersive }
    private var displayedLook: CameraFilmLook {
        guard !store.isComparingOriginal, !store.sampling, store.phase != .locking,
              !store.inputType.requiresBase || store.showsPositive else { return .neutral }
        return store.filmLook
    }
    private var offersComparison: Bool {
        guard !store.sampling, store.phase != .locking, store.asset != nil else { return false }
        if store.isComparingOriginal || store.base != nil { return true }
        return displayedLook != .neutral && lookPreferences[displayedLook] > 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if immersive { cameraWorkspace }
                else { documentWorkspace }
            }
            .navigationTitle(AppText.localized("negative.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(immersive ? .hidden : .visible, for: .navigationBar)
            .toolbarVisibility(immersive ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("negative.files", systemImage: "folder") { showsFiles = true }
                        Button("negative.photos", systemImage: "photo.on.rectangle") { showsPhotos = true }
                        Button("negative.camera", systemImage: "camera") { cameraImmersive = true; store.startCamera() }
                    } label: { Label("negative.input", systemImage: "plus") }
                    .disabled(store.busy != nil || store.sampling)
                    .accessibilityIdentifier("negative-input")
                }
            }
        }
        .sheet(isPresented: $showsCameraSettings) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        if let asset = store.asset {
                            Text("\(asset.width) × \(asset.height)")
                                .font(.caption.monospacedDigit())
                                .accessibilityIdentifier("negative-dimensions")
                        }
                        NegativeCameraControls(store: store)
                    }.padding()
                }
                .navigationTitle(AppText.localized("negative.camera.settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("negative.done") { showsCameraSettings = false }
                        .accessibilityIdentifier("negative-settings-done")
                } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsLookOptions) { lookOptionsSheet }
        .onChange(of: displayedLook) { _, _ in
            if !store.isCamera { store.resetDisplayFailure() }
        }
        .onChange(of: lookPreferences[store.filmLook]) { _, _ in
            if !store.isCamera { store.resetDisplayFailure() }
        }
        .onChange(of: store.externalOpenID, initial: true) { _, request in
            guard request != nil else { return }
            // External opens always reveal the document workspace, including failed imports.
            cameraImmersive = false
            showsFiles = false; showsPhotos = false; showsCameraSettings = false; showsLookOptions = false; photo = nil
        }
        .onChange(of: store.isCamera) { _, camera in if camera { cameraImmersive = true } }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.tiff, .jpeg, .png, .heic, .heif]) { result in
            switch result {
            case .success(let url): store.loadFile(url)
            case .failure(let error): store.reportImportError(error)
            }
        }
        .photosPicker(isPresented: $showsPhotos, selection: $photo, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photo) { _, item in
            if let item { store.loadPhoto(item); photo = nil }
        }
        .sheet(item: $store.share) { share in NegativeShareSheet(share: share) }
        .alert("negative.photos.title", isPresented: Binding(
            get: { store.photoNotice != nil },
            set: { if !$0 { store.photoNotice = nil } }
        )) {
            if store.photoAccessDenied {
                Button("negative.openSettings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("negative.done", role: .cancel) { store.photoNotice = nil }
        } message: {
            Text(store.photoNotice ?? "")
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { store.suspend() } }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            store.rotate(UIDevice.current.orientation)
        }
        .onDisappear {
            store.suspend()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        #if DEBUG
        // UI tests inject a local fixture through the production file-loading path.
        .task {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["NEGATIVE_UI_CAMERA"] == "1" { store.startCamera(); return }
            #endif
            if let path = ProcessInfo.processInfo.environment["NEGATIVE_UI_FIXTURE"], store.asset == nil {
                store.loadFile(URL(fileURLWithPath: path))
            }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            store.rotate(UIDevice.current.orientation)
        }
    }

    private var documentWorkspace: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    if store.asset != nil {
                        inputTypePicker
                        NegativeImagePanel(store: store, look: displayedLook, strength: lookPreferences[store.filmLook])
                            // File review remains a scrollable workbench; live capture has its own viewport.
                            .frame(height: max(220, geometry.size.height - (store.sampling ? 300 : store.isCamera ? 240 : 210)))
                            .overlay(alignment: .topLeading) {
                                if offersComparison { compareOriginalButton.padding(8) }
                            }
                        if let asset = store.asset {
                            if let name = asset.sourceName { Text(name).font(.callout).textSelection(.enabled) }
                            Text("\(asset.width) × \(asset.height)")
                                .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                                .accessibilityIdentifier("negative-dimensions")
                            if asset.assumesSRGB { Text("negative.assumedProfile").font(.caption).foregroundStyle(Palette.muted) }
                        }
                        if store.sampling { samplingControls }
                        else {
                            lookOptionsButton
                            viewingControls
                        }
                    } else {
                        ContentUnavailableView {
                            Label("negative.title", systemImage: "photo")
                        } description: {
                            Text("negative.intro")
                        } actions: {
                            Button("negative.files", systemImage: "folder") { showsFiles = true }
                                .accessibilityIdentifier("negative-import-file")
                            Button("negative.photos", systemImage: "photo.on.rectangle") { showsPhotos = true }
                            Button("negative.camera", systemImage: "camera") { cameraImmersive = true; store.startCamera() }
                                .accessibilityIdentifier("negative-open-camera")
                        }
                        .frame(minHeight: max(300, geometry.size.height - 100))
                        .disabled(store.busy != nil)
                    }
                    // File review shares the page footer; immersive capture keeps its full viewport.
                    AppCopyrightFooter()
                        .padding(.top, 4)
                }
                .padding(12)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            // Progress and errors own a stable region above the tab bar; inside the
            // scroll content they hid behind the floating tab bar during imports.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.busy != nil || store.error != nil {
                    VStack(spacing: 8) {
                        if let busy = store.busy {
                            HStack {
                                operationProgress
                                Text(LocalizedStringKey(busy))
                                Spacer()
                                // Photo-library commits cannot be cancelled after submission.
                                if store.phase != .savingPhotos {
                                    Button("negative.cancel") { store.cancelWork() }.frame(minHeight: 44)
                                }
                            }
                            .accessibilityIdentifier("negative-progress")
                        }
                        if let error = store.error {
                            Text(error).font(.callout).foregroundStyle(Palette.text)
                                .accessibilityIdentifier("negative-error")
                            if store.cameraDenied {
                                permissionSettingsButton
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                    .background(Palette.background)
                }
            }
            .background(Palette.background)
        }
    }

    /// Both workspaces expose the same recovery action after camera authorization fails.
    private var permissionSettingsButton: some View {
        Button("negative.openSettings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("negative-open-camera-settings")
    }

    /// The camera owns the viewport; controls overlay it instead of shrinking its height.
    private var cameraWorkspace: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let panelHeight = dynamicTypeSize.isAccessibilitySize
                ? geometry.size.height * 0.55
                : min(geometry.size.height * 0.44, 260)
            let availableHeight = wide ? max(100, geometry.size.height - 80) : panelHeight
            ZStack {
                // Only sampling needs every film edge clear of the header and actions.
                NegativeImagePanel(store: store, cornerRadius: 0, fillsViewport: !store.sampling,
                                   look: displayedLook, strength: lookPreferences[store.filmLook])
                    .padding(.top, store.sampling ? 64 : 0)
                    .padding(.bottom, store.sampling && !wide ? panelHeight + 24 : 0)
                    .padding(.trailing, store.sampling && wide ? 324 : 0)
                    .ignoresSafeArea(.container, edges: store.sampling ? [] : .all)
                VStack {
                    cameraHeader
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        if wide { Spacer(minLength: 0) }
                        VStack(alignment: .trailing, spacing: 6) {
                            if !store.sampling, store.asset != nil {
                                // Keep the drum outside the action scroller. Its three rows can use at
                                // most half the available height, including in landscape and large text.
                                HStack(alignment: .bottom, spacing: 6) {
                                    VStack(alignment: .trailing, spacing: 6) {
                                        if offersComparison { compareOriginalButton }
                                        lookOptionsButton.labelStyle(.iconOnly)
                                            .background(Palette.background.opacity(0.94), in: Circle())
                                    }
                                    RulerDial(values: CameraFilmLook.allCases, selection: store.filmLook,
                                              spacing: min(filmRowHeight, availableHeight / 6),
                                              identifier: "negative-film-look", accessibilityLabel: Text("negative.look.previewOnly"),
                                              label: { AppText.key($0.rawValue) }, accessibilityValue: { AppText.key($0.rawValue) },
                                              isNotch: { $0 == .neutral }, face: .verticalWheel, onSelect: selectLook)
                                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 280 : 196)
                                }
                                .disabled(store.busy != nil)
                            }
                            ViewThatFits(in: .vertical) {
                                cameraPanelContent.fixedSize(horizontal: false, vertical: true)
                                ScrollView { cameraPanelContent }
                                    .accessibilityIdentifier("negative-camera-actions")
                            }
                            .background(Palette.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 18))
                        }
                        .frame(maxWidth: wide ? 300 : 600)
                        .frame(maxHeight: availableHeight, alignment: .bottom)
                    }
                }.padding(12)
            }
        }
        .background(.black)
    }

    private var cameraPanelContent: some View {
        VStack(spacing: 8) {
            if let busy = store.busy {
                HStack {
                    operationProgress
                    Text(LocalizedStringKey(busy))
                    Spacer()
                    // Photo-library commits cannot be cancelled after submission.
                    if store.phase != .savingPhotos {
                        Button("negative.cancel") { store.cancelWork() }.frame(minHeight: 44)
                    }
                }.accessibilityIdentifier("negative-progress")
            }
            if let error = store.error {
                Text(error).font(.callout).accessibilityIdentifier("negative-error")
                if store.cameraDenied { permissionSettingsButton }
            }
            if store.sampling { samplingControls }
            else { cameraActions }
        }.padding(12)
    }

    private var cameraHeader: some View {
        HStack(spacing: 12) {
            Button {
                // Return to the same frame and look; live acquisition resumes explicitly.
                store.suspend(); cameraImmersive = false
            } label: { Label("negative.camera.close", systemImage: "chevron.backward").labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 44) }
            .accessibilityIdentifier("negative-camera-close")
            .disabled(store.phase == .savingPhotos)
            inputTypeMenu
                .frame(maxWidth: .infinity)
            Button { showsCameraSettings = true } label: {
                Label("negative.camera.settings", systemImage: "slider.horizontal.3").labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .disabled(!store.canAdjustCamera)
            .accessibilityIdentifier("negative-camera-settings")
        }
        .padding(4)
        .frame(maxWidth: 600)
        .background(Palette.background.opacity(0.94), in: Capsule())
    }

    private var inputTypePicker: some View {
        LabeledContent("negative.inputType.title") { inputTypeMenu }
    }

    private var inputTypeMenu: some View {
        Picker("negative.inputType.title", selection: Binding(get: { store.inputType }, set: store.setInputType)) {
            ForEach(FilmPreviewInput.allCases, id: \.self) { input in
                Text(LocalizedStringKey(input.localizationKey)).tag(input)
            }
        }
        .pickerStyle(.menu).labelsHidden()
        .disabled(!store.canChangeInputType)
        .accessibilityIdentifier("negative-input-type")
    }

    private func selectLook(_ look: CameraFilmLook) {
        store.setComparingOriginal(false)
        store.filmLook = look
    }

    private var lookOptionsButton: some View {
        Button {
            store.setComparingOriginal(false)
            showsLookOptions = true
        } label: {
            Label("negative.look.options", systemImage: "camera.filters")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityValue(Text(LocalizedStringKey(store.filmLook.rawValue)))
        .accessibilityIdentifier("negative-look-options")
        .disabled(store.busy != nil || store.sampling)
    }

    private var lookOptionsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("negative.look.previewOnly", selection: Binding(get: { store.filmLook }, set: selectLook)) {
                        ForEach(CameraFilmLook.allCases, id: \.self) { look in
                            Text(LocalizedStringKey(look.rawValue)).tag(look)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("negative-look-picker")
                    if store.filmLook != .neutral {
                        let strength = Binding(get: { lookPreferences[store.filmLook] },
                                               set: { lookPreferences[store.filmLook] = $0 })
                        VStack(alignment: .leading) {
                            LabeledContent("negative.look.strength") {
                                Text(strength.wrappedValue, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }
                            HStack {
                                strengthStep(-1, value: strength)
                                Slider(value: strength, in: 0...1, step: 0.05) { Text("negative.look.strength") }
                                    .accessibilityIdentifier("negative-look-strength")
                                strengthStep(1, value: strength)
                            }
                        }
                    }
                } footer: {
                    if store.inputType.requiresBase && store.base == nil {
                        Text("negative.simulation.calibrateHint")
                    } else {
                        Text(store.inputType == .scene ? "negative.look.sceneHint" : "negative.look.previewHint")
                    }
                }
                if let reference = store.filmLook.kodakDataSheet {
                    Section {
                        Link("negative.look.dataSheet", destination: reference)
                    } footer: {
                        Text("negative.look.profileHint")
                    }
                }
            }
            .navigationTitle(AppText.localized("negative.look.options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("negative.done") { showsLookOptions = false }
                        .accessibilityIdentifier("negative-look-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func strengthStep(_ delta: Int, value: Binding<Double>) -> some View {
        let next = Int((value.wrappedValue * 20).rounded()) + delta
        return Button {
            value.wrappedValue = Double(next) / 20
        } label: {
            Image(systemName: delta < 0 ? "minus" : "plus").frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(delta < 0 ? Text("negative.look.decrease") : Text("negative.look.increase"))
        .accessibilityIdentifier(delta < 0 ? "negative-look-strength-decrease" : "negative-look-strength-increase")
        .disabled(!(0...20).contains(next))
    }

    private var compareOriginalButton: some View {
        Button { store.setComparingOriginal(!store.isComparingOriginal) } label: {
            Text(store.isComparingOriginal ? "negative.simulation.return" : "negative.simulation.compare")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .padding(.horizontal, 10)
        }
        .background(Palette.background.opacity(0.94), in: Capsule())
        .disabled(store.busy != nil)
        .accessibilityIdentifier("negative-compare-original")
    }

    private var cameraActions: some View {
        // Stack actions vertically at accessibility sizes instead of compressing their labels.
        let actions = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(spacing: 8) {
            if !dynamicTypeSize.isAccessibilitySize { cameraStatus }
            actions {
                if store.inputType.requiresBase {
                    if let base = store.base { baseSwatch(base) }
                    Button { store.selectBase() } label: {
                        Label(store.base == nil ? "negative.simulation.invert" : "negative.resample", systemImage: "scope")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
                    .disabled(store.busy != nil || store.asset == nil)
                    .accessibilityIdentifier("negative-sample")
                }
                Button {
                    if store.live { store.freeze() } else { store.resume() }
                } label: {
                    Label(store.live ? "negative.freeze" : "negative.continue", systemImage: store.live ? "pause.fill" : "play.fill")
                        .frame(minHeight: 44)
                }
                .disabled(store.busy != nil || store.asset == nil)
                .accessibilityIdentifier("negative-camera-freeze")
                if store.inputType != .scene { exportMenu.labelStyle(.iconOnly) }
            }
            if dynamicTypeSize.isAccessibilitySize { cameraStatus }
        }
    }

    private var cameraStatus: some View {
        VStack(spacing: 8) {
            Text(cameraHint).font(.caption)
            if store.cameraConfiguration?.automaticMacro == true {
                Text(store.macroActive ? "negative.camera.macroActive" : "negative.camera.macroAutomatic")
                    .font(.caption).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("negative-camera-macro-status")
            }
        }
    }

    @ViewBuilder private var operationProgress: some View {
        if store.phase == .exporting, store.exportProgress > 0 {
            if store.exportProgress < 1 {
                ProgressView(value: store.exportProgress).frame(maxWidth: 90)
            } else {
                Text("negative.encoding").font(.caption)
            }
        } else { ProgressView() }
    }

    private var exportMenu: some View {
        Menu {
            Button(store.inputType == .slide ? "negative.photos.saveOriginal" : "negative.photos.save",
                   systemImage: "square.and.arrow.down") { store.saveToPhotos() }
                .accessibilityIdentifier("negative-save-photos")
            Divider()
            ForEach(NegativeFormat.allCases) { format in
                Button {
                    store.export(format)
                } label: {
                    let bytes = Double(store.asset?.width ?? 0) * Double(store.asset?.height ?? 0) * (format == .jpg ? 8 : 16) + 67_108_864
                    Text("\(format.title) · \(AppText.key("negative.scratch")) ≈ \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                }
                    .accessibilityIdentifier("negative-export-\(format.rawValue)")
            }
        } label: {
            Label(store.inputType == .slide ? "negative.exportOriginal" : "negative.export",
                  systemImage: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!store.canExport)
        .accessibilityIdentifier("negative-export")
    }

    private var viewingControls: some View {
        VStack(spacing: 8) {
            if store.base != nil || store.inputType == .slide {
                TextField("negative.outputName", text: Bindable(store).outputName).textFieldStyle(.roundedBorder)
            }
            if store.inputType.requiresBase {
                HStack {
                    if let base = store.base { baseSwatch(base) }
                    Text(store.base == nil ? "negative.needsBase" : "negative.baseSet")
                        .font(.callout).foregroundStyle(Palette.muted)
                    Spacer()
                    Button { store.selectBase() } label: {
                        Text(store.base == nil ? "negative.simulation.invert" : "negative.resample").frame(minHeight: 44).contentShape(Rectangle())
                    }
                        .accessibilityIdentifier("negative-sample")
                        .disabled(store.busy != nil)
                }
            }
            if store.isCamera {
                Text(cameraHint)
                    .font(.caption).foregroundStyle(Palette.muted)
                if store.cameraConfiguration?.automaticMacro == true {
                    Text(store.macroActive ? "negative.camera.macroActive" : "negative.camera.macroAutomatic")
                        .font(.caption).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("negative-camera-macro-status")
                }
            }
            HStack {
                if store.isCamera {
                    Button {
                        cameraImmersive = true
                        if store.paused { store.resume() }
                    } label: {
                        Label("negative.camera.fullscreen", systemImage: "viewfinder").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("negative-camera-fullscreen")
                    .disabled(store.busy != nil)
                }
                Spacer()
                if store.inputType != .scene { exportMenu }
            }
        }
    }

    private var cameraHint: LocalizedStringKey {
        if store.paused { return "negative.paused" }
        if store.needsCameraResampling { return "negative.camera.recalibrate" }
        if !store.live { return "negative.camera.frozen" }
        if store.inputType.requiresBase && store.base == nil { return "negative.simulation.calibrateHint" }
        if store.captureLocked { return "negative.locked" }
        // Fixed-focus lenses must not invite an unsupported tap-to-focus action.
        if store.cameraConfiguration?.supportsFocus == false { return "negative.camera.fixedFocus" }
        return "negative.cameraHint"
    }

    private var samplingControls: some View {
        let actions = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return VStack(spacing: 8) {
            if !dynamicTypeSize.isAccessibilitySize { Text("negative.sampleHint").font(.callout) }
            HStack {
                if let candidate = store.candidate { baseSwatch(candidate) }
                if store.candidateBusy { ProgressView() }
                if let error = store.sampleError { Text(error).font(.caption) }
                else if store.candidate?.uneven == true { Text("negative.uneven").font(.caption) }
                Spacer()
            }
            HStack {
                moveButton("negative.left", symbol: "arrow.left", x: -0.01, y: 0)
                moveButton("negative.right", symbol: "arrow.right", x: 0.01, y: 0)
                Button { store.selectSamplePoint(CGPoint(x: 0.5, y: 0.5)) } label: {
                    Label("negative.centerSample", systemImage: "scope").labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 44)
                }
                .disabled(store.busy != nil)
                .accessibilityIdentifier("negative-center-sample")
                moveButton("negative.up", symbol: "arrow.up", x: 0, y: -0.01)
                moveButton("negative.down", symbol: "arrow.down", x: 0, y: 0.01)
            }
            actions {
                Button { store.cancelSampling() } label: { Text("negative.cancel").frame(minHeight: 44).contentShape(Rectangle()) }
                Spacer()
                Button("negative.useBase") {
                    store.confirmBase()
                }
                    // The app's light monochrome tint needs a dark label on this filled action.
                    .foregroundStyle(Palette.background)
                    .controlSize(.large).buttonStyle(.borderedProminent).disabled(store.candidate == nil || store.busy != nil)
                    .accessibilityIdentifier("negative-confirm-base")
            }.disabled(store.busy != nil)
            if dynamicTypeSize.isAccessibilitySize { Text("negative.sampleHint").font(.callout) }
        }
    }

    private func moveButton(_ label: LocalizedStringKey, symbol: String, x: CGFloat, y: CGFloat) -> some View {
        Button { store.moveSample(x: x, y: y) } label: { Label(label, systemImage: symbol).labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 44) }
            .disabled(store.busy != nil)
    }

    private func baseSwatch(_ base: NegativeBase) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(.sRGBLinear, red: Double(base.red), green: Double(base.green), blue: Double(base.blue)))
            .frame(width: 28, height: 28)
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(Palette.line) }
            .accessibilityLabel("negative.baseColor")
    }
}

/// Frame observation stays inside the image panel; the zoom surface is reused at video cadence.
private struct NegativeImagePanel: View {
    let store: NegativeStore
    var cornerRadius: CGFloat = 12
    var fillsViewport = false
    var look: CameraFilmLook = .neutral
    var strength: Double = 1
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if store.imageState.cameraImage != nil || store.displayed != nil {
                // Camera pixels go straight to Metal; file bitmaps keep their existing tier cache.
                NegativeCanvas(image: store.displayed, cameraImage: store.imageState.cameraImage,
                               base: !store.sampling && store.phase != .locking && store.showsPositive ? store.base : nil,
                               fillsViewport: fillsViewport, look: look, strength: strength,
                               monochrome: store.inputType == .monochromeNegative,
                               sourceURL: store.asset?.fileURL,
                               sampling: store.sampling || store.focusPoint != nil,
                               point: store.sampling || store.phase == .locking ? store.point : store.focusPoint ?? CGPoint(x: 0.5, y: 0.5),
                               displayNeed: { store.displayNeeds($0) }, failed: { store.displayFailed() }) { point in
                    guard store.busy == nil else { return }
                    if store.sampling { store.selectSamplePoint(point) }
                    else { store.focus(point) }
                }
                .accessibilityIdentifier("negative-image")
            }
            if store.sampling, let image = store.imageState.loupe {
                // This bounded source crop stays sharp even when the display uses a smaller tier.
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(width: 90, height: 90).overlay { Rectangle().stroke(.white, lineWidth: 1) }
                    .overlay { Image(systemName: "plus").foregroundStyle(.white).shadow(radius: 1) }
                    .padding(8).allowsHitTesting(false)
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct NegativeShareSheet: UIViewControllerRepresentable {
    let share: NegativeShare
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [share.url], applicationActivities: nil)
        // Retain the owner until activity completion, even if the SwiftUI sheet is dismissed.
        controller.completionWithItemsHandler = { [share] _, _, _, _ in _ = share.url }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct NegativeCanvas: UIViewRepresentable {
    let image: CGImage?
    let cameraImage: CIImage?
    let base: NegativeBase?
    let fillsViewport: Bool
    let look: CameraFilmLook
    let strength: Double
    let monochrome: Bool
    let sourceURL: URL?
    let sampling: Bool
    let point: CGPoint
    var displayNeed: ((CGFloat) -> Void)? = nil
    let failed: () -> Void
    let selected: (CGPoint) -> Void
    func makeUIView(context: Context) -> NegativeZoomView { NegativeZoomView() }
    func updateUIView(_ view: NegativeZoomView, context: Context) {
        // Refresh UIKit accessibility text without recreating its zoom/pan state.
        view.updateAccessibility()
        view.selected = selected
        view.displayNeed = displayNeed
        view.fillsViewport = fillsViewport
        if let cameraImage {
            view.setCameraImage(cameraImage, base: base, look: look, strength: strength, monochrome: monochrome,
                                sampling: sampling, point: point, failed: failed)
        } else if let image {
            view.setImage(image, sourceURL: sourceURL, look: look, strength: strength, sampling: sampling, point: point, failed: failed)
        }
    }
}

/// UIKit owns pinch/pan transforms so touch-to-source mapping stays exact on iPad resizing.
final class NegativeZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    let marker = CAShapeLayer()
    let centerDot = CAShapeLayer()
    var selected: ((CGPoint) -> Void)?
    /// Reports the bitmap long side the current zoom needs so file previews can re-render sharper.
    var displayNeed: ((CGFloat) -> Void)?
    private var sourceURL: URL?
    private var imageSize = CGSize.zero
    private var lastBounds = CGSize.zero
    private var point = CGPoint.zero
    private var sampling = false
    private var fitLongPoints: CGFloat = 0
    private var pendingViewport: (zoom: CGFloat, center: CGPoint)?
    private var lastViewport: (zoom: CGFloat, center: CGPoint)?
    private var arranging = false
    private var metalView: NegativeMetalView?
    private weak var previousImage: CGImage?
    private var fileTexture: CIImage?
    var fillsViewport = false {
        didSet {
            guard fillsViewport != oldValue else { return }
            // An old zoom/pan could hide the film edge when entering sampling.
            lastBounds = .zero; pendingViewport = nil; lastViewport = nil
            setNeedsLayout()
        }
    }

    init() {
        super.init(frame: .zero)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 8
        // SwiftUI owns safe areas; UIKit must not add another inset to source coordinates.
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        addSubview(imageView)
        imageView.layer.addSublayer(marker)
        imageView.layer.addSublayer(centerDot)
        marker.fillColor = UIColor.clear.cgColor; marker.strokeColor = UIColor.white.cgColor
        marker.shadowColor = UIColor.black.cgColor; marker.shadowOpacity = 1; marker.shadowRadius = 1
        centerDot.fillColor = UIColor.white.cgColor
        centerDot.shadowColor = UIColor.black.cgColor; centerDot.shadowOpacity = 1; centerDot.shadowRadius = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap); addGestureRecognizer(doubleTap)
        isAccessibilityElement = true
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateAccessibility() {
        let label = AppText.localized("negative.image")
        // Video updates need not reallocate unchanged VoiceOver actions every frame.
        guard accessibilityLabel != label else { return }
        accessibilityLabel = label
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: AppText.localized("negative.zoomIn"), target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: AppText.localized("negative.resetZoom"), target: self, selector: #selector(resetZoom))
        ]
    }
    func setImage(_ image: CGImage, sourceURL: URL?, look: CameraFilmLook = .neutral, strength: Double = 1,
                  sampling: Bool, point: CGPoint, failed: (() -> Void)? = nil) {
        if look == .neutral || strength == 0 {
            metalView?.failed = nil; metalView?.removeFromSuperview(); metalView = nil; fileTexture = nil
            if previousImage !== image || imageView.image == nil { imageView.image = UIImage(cgImage: image) }
        } else {
            // File tiers already contain the selected original or calibrated positive.
            // Wrap this tier once and apply only the creative look as its strength changes.
            if previousImage !== image || fileTexture == nil { fileTexture = CIImage(cgImage: image) }
            if let fileTexture {
                showOnMetal(fileTexture, base: nil, look: look, strength: strength, monochrome: false, failed: failed)
            }
        }
        previousImage = image
        setSource(size: CGSize(width: image.width, height: image.height), sourceURL: sourceURL, sampling: sampling, point: point)
        updateCameraResolution()
    }
    func setCameraImage(_ image: CIImage, base: NegativeBase?, look: CameraFilmLook, strength: Double = 1, monochrome: Bool = false,
                        sampling: Bool, point: CGPoint, failed: @escaping () -> Void) {
        fileTexture = nil; previousImage = nil
        showOnMetal(image, base: base, look: look, strength: strength, monochrome: monochrome, failed: failed)
        setSource(size: image.extent.size, sourceURL: nil, sampling: sampling, point: point)
        updateCameraResolution()
    }
    private func showOnMetal(_ image: CIImage, base: NegativeBase?, look: CameraFilmLook, strength: Double,
                             monochrome: Bool, failed: (() -> Void)?) {
        if metalView == nil {
            let surface = NegativeMetalView()
            // Insert below the source-coordinate reticle layers.
            imageView.insertSubview(surface, at: 0)
            metalView = surface
            imageView.image = nil
        }
        metalView?.failed = failed
        metalView?.show(image, base: base, look: look, strength: strength, monochrome: monochrome)
    }
    private func setSource(size: CGSize, sourceURL: URL?, sampling: Bool, point: CGPoint) {
        let sourceChanged = self.sourceURL != sourceURL
        self.sourceURL = sourceURL
        if sourceChanged || imageSize != size {
            pendingViewport = !sourceChanged && imageSize.width > 0 && bounds.width > 0 ? viewport() : nil
            if sourceChanged { lastViewport = nil }
            imageSize = size; lastBounds = .zero; setNeedsLayout()
        }
        // Most frames only change the texture; don't rebuild marker paths at video cadence.
        if self.sampling != sampling || self.point != point {
            self.sampling = sampling; self.point = point
            updateMarker()
        }
    }
    override func layoutSubviews() {
        arranging = true
        defer { arranging = false; if imageSize.width > 0 { lastViewport = viewport() } }
        super.layoutSubviews()
        if lastBounds != bounds.size, imageSize.width > 0, bounds.width > 0 {
            // Resize and rotation preserve the viewed source region, just like sharper file tiers.
            let restore = pendingViewport ?? (lastBounds != .zero ? lastViewport : nil)
            lastBounds = bounds.size
            pendingViewport = nil
            setZoomScale(1, animated: false)
            let horizontal = bounds.width / imageSize.width, vertical = bounds.height / imageSize.height
            let factor = fillsViewport ? max(horizontal, vertical) : min(horizontal, vertical)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: imageSize.width * factor, height: imageSize.height * factor))
            contentSize = imageView.frame.size
            fitLongPoints = max(imageSize.width, imageSize.height) * factor
            centerImage()
            if let restore {
                setZoomScale(min(max(restore.zoom, minimumZoomScale), maximumZoomScale), animated: false)
                let target = CGPoint(x: restore.center.x * contentSize.width - bounds.width / 2,
                                     y: restore.center.y * contentSize.height - bounds.height / 2)
                contentOffset = CGPoint(
                    x: min(max(target.x, -contentInset.left), contentSize.width - bounds.width + contentInset.right),
                    y: min(max(target.y, -contentInset.top), contentSize.height - bounds.height + contentInset.bottom))
            } else {
                // Center both letterboxing and overflow from the camera's aspect-fill crop.
                contentOffset = CGPoint(x: (contentSize.width - bounds.width) / 2,
                                        y: (contentSize.height - bounds.height) / 2)
            }
        }
        centerImage(); updateMarker(); updateCameraResolution()
    }
    private func updateCameraResolution() {
        guard let metalView else { return }
        metalView.frame = imageView.bounds
        metalView.updateResolution(zoom: zoomScale, displayScale: traitCollection.displayScale)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !arranging, imageSize.width > 0 { lastViewport = viewport() }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage(); updateMarker(); updateCameraResolution()
        if !arranging { lastViewport = viewport() }
        guard !arranging, let displayNeed, fitLongPoints > 0, zoomScale > 1.01 else { return }
        // Screen pixels covering the fitted long side at this zoom; more than the current
        // bitmap resolution means the preview is being stretched on screen.
        displayNeed((fitLongPoints * zoomScale * max(1, traitCollection.displayScale)).rounded(.up))
    }
    /// The visible content center in normalized coordinates plus the current visual zoom.
    private func viewport() -> (zoom: CGFloat, center: CGPoint) {
        let x = (contentOffset.x + bounds.width / 2) / max(contentSize.width, 1)
        let y = (contentOffset.y + bounds.height / 2) / max(contentSize.height, 1)
        return (zoomScale, CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y))))
    }
    private func centerImage() {
        // Symmetric slack preserves centered scroll boundaries after zoom and rotation.
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
    private func updateMarker() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        marker.isHidden = !sampling
        centerDot.isHidden = !sampling
        let side = max(8 / max(imageSize.width, 1), min(imageSize.width, imageSize.height) * 0.01 / max(imageSize.width, 1)) * imageView.bounds.width
        let center = CGPoint(x: point.x * imageView.bounds.width, y: point.y * imageView.bounds.height)
        let path = UIBezierPath(rect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        // Keep the exact sample box; a compact, thin crosshair avoids obscuring film detail.
        let inner = max(side / 2 + 1 / zoomScale, 3 / zoomScale)
        let outer = inner + 3 / zoomScale
        for direction in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)] {
            path.move(to: CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
            path.addLine(to: CGPoint(x: center.x + direction.x * outer, y: center.y + direction.y * outer))
        }
        marker.path = path.cgPath
        let radius = 0.75 / zoomScale
        centerDot.path = UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).cgPath
        marker.lineWidth = 1 / zoomScale
        CATransaction.commit()
    }
    /// Double-tap is inspection only; it cannot accidentally move focus or the sample point.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard imageView.bounds.contains(gesture.location(in: imageView)) else { return }
        if zoomScale > 1.01 { _ = resetZoom() }
        else { zoom(to: gesture.location(in: imageView), scale: 2) }
    }
    private func zoom(to point: CGPoint, scale: CGFloat) {
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    @objc func zoomIn() -> Bool {
        let center = viewport().center
        zoom(to: CGPoint(x: center.x * imageView.bounds.width, y: center.y * imageView.bounds.height),
             scale: min(maximumZoomScale, zoomScale * 2))
        return true
    }
    @objc func resetZoom() -> Bool {
        setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
        return true
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: imageView)
        guard imageView.bounds.contains(p), imageView.bounds.width > 0 else { return }
        selected?(CGPoint(x: p.x / imageView.bounds.width, y: p.y / imageView.bounds.height))
    }
}
#endif

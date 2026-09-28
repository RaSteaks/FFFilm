#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct NegativePreviewView: View {
    @State private var store: NegativeStore
    @State private var showsFiles = false
    @State private var showsPhotos = false
    @State private var photo: PhotosPickerItem?
    @State private var cameraControlsExpanded = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["NEGATIVE_UI_CAMERA"] == "1" {
            _store = State(initialValue: NegativeStore(camera: NegativeCameraFixture()))
            return
        }
        #endif
        _store = State(initialValue: NegativeStore())
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 12) {
                        if store.asset != nil {
                            Picker("negative.comparison", selection: $store.showsPositive) {
                                Text("negative.original").tag(false)
                                Text("negative.positive").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .disabled(store.base == nil || store.sampling)
                            .accessibilityIdentifier("negative-comparison")
                            NegativeImagePanel(store: store)
                                // Reserve room for expanded camera controls above the system tab bar.
                                .frame(height: max(220, geometry.size.height - (store.sampling ? 300 : store.isCamera ? (cameraControlsExpanded ? 560 : 310) : 210)))
                            if let asset = store.asset {
                                Text("\(asset.width) × \(asset.height)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                                    .accessibilityIdentifier("negative-dimensions")
                                if asset.assumesSRGB { Text("negative.assumedProfile").font(.caption).foregroundStyle(Palette.muted) }
                            }
                            if store.sampling { samplingControls }
                            else { viewingControls }
                        } else {
                            ContentUnavailableView {
                                Label("negative.title", systemImage: "photo")
                            } description: {
                                Text("negative.intro")
                            } actions: {
                                Button("negative.files", systemImage: "folder") { showsFiles = true }
                                    .accessibilityIdentifier("negative-import-file")
                                Button("negative.photos", systemImage: "photo.on.rectangle") { showsPhotos = true }
                                Button("negative.camera", systemImage: "camera") { store.startCamera() }
                                    .accessibilityIdentifier("negative-open-camera")
                            }
                            .frame(minHeight: max(300, geometry.size.height - 100))
                            .disabled(store.busy != nil)
                        }
                        if let busy = store.busy {
                            HStack {
                                ProgressView()
                                Text(LocalizedStringKey(busy))
                                Spacer()
                                Button("negative.cancel") { store.cancelWork() }.frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("negative-progress")
                        }
                        if let error = store.error {
                            Text(error).font(.callout).foregroundStyle(Palette.text)
                                .accessibilityIdentifier("negative-error")
                            if store.cameraDenied {
                                Button("negative.openSettings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                }
                .background(Palette.background)
            }
            .navigationTitle("negative.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("negative.files", systemImage: "folder") { showsFiles = true }
                        Button("negative.photos", systemImage: "photo.on.rectangle") { showsPhotos = true }
                        Button("negative.camera", systemImage: "camera") { store.startCamera() }
                    } label: { Label("negative.input", systemImage: "plus") }
                    .disabled(store.busy != nil || store.sampling)
                    .accessibilityIdentifier("negative-input")
                }
            }
        }
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

    private var viewingControls: some View {
        VStack(spacing: 8) {
            HStack {
                if let base = store.base { baseSwatch(base) }
                Text(store.base == nil ? "negative.needsBase" : "negative.baseSet")
                    .font(.callout).foregroundStyle(Palette.muted)
                Spacer()
                Button { store.selectBase() } label: {
                    Text(store.base == nil ? "negative.sample" : "negative.resample").frame(minHeight: 44).contentShape(Rectangle())
                }
                    .accessibilityIdentifier("negative-sample")
                    .disabled(store.busy != nil)
            }
            if store.isCamera {
                Text(cameraHint)
                    .font(.caption).foregroundStyle(Palette.muted)
                NegativeCameraControls(store: store, expanded: $cameraControlsExpanded)
            }
            HStack {
                if store.isCamera {
                    Button {
                        if store.live { store.freeze() } else { store.resume() }
                    } label: { Text(store.live ? "negative.freeze" : "negative.continue").frame(minHeight: 44).contentShape(Rectangle()) }
                    .disabled(store.busy != nil)
                }
                Spacer()
                Menu {
                    ForEach(NegativeFormat.allCases) { format in
                        Button(format.title) { store.export(format) }
                            .accessibilityIdentifier("negative-export-\(format.rawValue)")
                    }
                } label: { Label("negative.export", systemImage: "square.and.arrow.up").frame(minHeight: 44).contentShape(Rectangle()) }
                .disabled(!store.canExport)
                .accessibilityIdentifier("negative-export")
            }
        }
    }

    private var cameraHint: LocalizedStringKey {
        if store.paused { return "negative.paused" }
        if store.captureLocked { return "negative.locked" }
        if store.cameraTapSamplesBase { return "negative.cameraSampleHint" }
        // Fixed-focus lenses must not invite an unsupported tap-to-focus action.
        if store.cameraConfiguration?.supportsFocus == false { return "negative.camera.fixedFocus" }
        return "negative.cameraHint"
    }

    private var samplingControls: some View {
        VStack(spacing: 8) {
            Text("negative.sampleHint").font(.callout)
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
                    Label("negative.centerSample", systemImage: "scope").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                .disabled(store.busy != nil)
                .accessibilityIdentifier("negative-center-sample")
                moveButton("negative.up", symbol: "arrow.up", x: 0, y: -0.01)
                moveButton("negative.down", symbol: "arrow.down", x: 0, y: 0.01)
            }
            HStack {
                Button { store.cancelSampling() } label: { Text("negative.cancel").frame(minHeight: 44).contentShape(Rectangle()) }
                Spacer()
                Button("negative.useBase") { store.confirmBase() }
                    // The app's light monochrome tint needs a dark label on this filled action.
                    .foregroundStyle(Palette.background)
                    .controlSize(.large).buttonStyle(.borderedProminent).disabled(store.candidate == nil || store.busy != nil)
                    .accessibilityIdentifier("negative-confirm-base")
            }.disabled(store.busy != nil)
        }
    }

    private func moveButton(_ label: LocalizedStringKey, symbol: String, x: CGFloat, y: CGFloat) -> some View {
        Button { store.moveSample(x: x, y: y) } label: { Label(label, systemImage: symbol).labelStyle(.iconOnly).frame(width: 44, height: 44) }
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
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = store.displayed {
                // Tap intent is explicit: focusing must never unexpectedly enter film-base sampling.
                NegativeCanvas(image: image,
                               sampling: store.sampling || (store.isCamera && store.live && store.cameraTapSamplesBase) || store.focusPoint != nil,
                               point: store.sampling || store.phase == .locking ? store.point : store.focusPoint ?? CGPoint(x: 0.5, y: 0.5)) { point in
                    guard store.busy == nil else { return }
                    if store.sampling { store.selectSamplePoint(point) }
                    else if store.isCamera && store.live && store.cameraTapSamplesBase { store.selectBase(at: point) }
                    else { store.focus(point) }
                }
                .accessibilityIdentifier("negative-image")
            }
            if store.sampling, let image = store.asset?.preview {
                // Magnifier uses the original preview for positioning only, never for sampling.
                let side = CGFloat(min(image.width, image.height)) * 0.12
                let rect = CGRect(x: store.point.x * CGFloat(image.width) - side / 2,
                                  y: store.point.y * CGFloat(image.height) - side / 2, width: side, height: side)
                if let crop = image.cropping(to: rect) {
                    Image(decorative: crop, scale: 1).resizable().scaledToFit()
                        .frame(width: 90, height: 90).overlay { Rectangle().stroke(.white, lineWidth: 1) }
                        .overlay { Image(systemName: "plus").foregroundStyle(.white).shadow(radius: 1) }
                        .padding(8).allowsHitTesting(false)
                }
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
    let image: CGImage
    let sampling: Bool
    let point: CGPoint
    let selected: (CGPoint) -> Void
    func makeUIView(context: Context) -> NegativeZoomView { NegativeZoomView() }
    func updateUIView(_ view: NegativeZoomView, context: Context) {
        view.selected = selected
        view.setImage(image, sampling: sampling, point: point)
    }
}

/// UIKit owns pinch/pan transforms so touch-to-source mapping stays exact on iPad resizing.
private final class NegativeZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    let marker = CAShapeLayer()
    let centerDot = CAShapeLayer()
    var selected: ((CGPoint) -> Void)?
    private var imageSize = CGSize.zero
    private var lastBounds = CGSize.zero
    private var point = CGPoint.zero
    private var sampling = false
    private weak var previousImage: CGImage?

    init() {
        super.init(frame: .zero)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 8
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        addSubview(imageView)
        imageView.layer.addSublayer(marker)
        imageView.layer.addSublayer(centerDot)
        marker.fillColor = UIColor.clear.cgColor; marker.strokeColor = UIColor.white.cgColor
        marker.shadowColor = UIColor.black.cgColor; marker.shadowOpacity = 1; marker.shadowRadius = 1
        centerDot.fillColor = UIColor.white.cgColor
        centerDot.shadowColor = UIColor.black.cgColor; centerDot.shadowOpacity = 1; centerDot.shadowRadius = 1
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = true
        accessibilityLabel = NSLocalizedString("negative.image", comment: "Preview image")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImage(_ image: CGImage, sampling: Bool, point: CGPoint) {
        if previousImage !== image { imageView.image = UIImage(cgImage: image); previousImage = image }
        let size = CGSize(width: image.width, height: image.height)
        if imageSize != size { imageSize = size; lastBounds = .zero; setNeedsLayout() }
        self.sampling = sampling; self.point = point
        updateMarker()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if lastBounds != bounds.size, imageSize.width > 0, bounds.width > 0 {
            lastBounds = bounds.size
            setZoomScale(1, animated: false)
            let factor = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: imageSize.width * factor, height: imageSize.height * factor))
            contentSize = imageView.frame.size
        }
        centerImage(); updateMarker()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage(); updateMarker() }
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
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: imageView)
        guard imageView.bounds.contains(p), imageView.bounds.width > 0 else { return }
        selected?(CGPoint(x: p.x / imageView.bounds.width, y: p.y / imageView.bounds.height))
    }
}
#endif

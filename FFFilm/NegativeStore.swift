#if os(iOS)
import SwiftUI
import PhotosUI
import AVFoundation
import CoreTransferable

/// Transfer photos as files, avoiding a whole-file Data copy for large images.
nonisolated struct NegativePhoto: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            NegativePhoto(url: try NegativeRenderer.copiedFile(received.file))
        }
    }
}

/// Video invalidation is confined to the canvas, not the surrounding SwiftUI controls.
@MainActor @Observable
final class NegativeImageState {
    var original: CGImage?
    var positive: CGImage?
}

@MainActor @Observable
final class NegativeStore {
    private(set) var asset: NegativeAsset?
    let imageState = NegativeImageState()
    private var positive: CGImage? {
        get { imageState.positive }
        set { imageState.positive = newValue }
    }
    @ObservationIgnored private var latestCameraAsset: NegativeAsset?
    private(set) var base: NegativeBase?
    private(set) var candidate: NegativeBase?
    private(set) var isCamera = false
    private(set) var live = false
    private(set) var sampling = false
    // Workflow decisions use phases; localization keys are presentation only.
    enum Phase: String {
        case loading = "negative.loading"
        case cameraStarting = "negative.cameraStarting"
        case locking = "negative.locking"
        case rendering = "negative.rendering"
        case exporting = "negative.exporting"

        func acceptsCameraFrame(frozenForSampling: Bool) -> Bool {
            switch self {
            case .cameraStarting: return !frozenForSampling
            case .locking: return frozenForSampling
            case .loading, .rendering, .exporting: return false
            }
        }
    }
    private(set) var phase: Phase?
    var busy: String? { phase?.rawValue }
    private(set) var candidateBusy = false
    var showsPositive = false
    var point = CGPoint(x: 0.5, y: 0.5)
    var error: String?
    var share: NegativeShare?
    var cameraDenied = false
    private(set) var sampleError: String?
    private(set) var paused = false
    private(set) var captureLocked = false
    private(set) var cameraSettings = NegativeCameraSettings()
    private(set) var cameraConfiguration: NegativeCameraConfiguration?
    private(set) var macroActive = false
    private(set) var needsCameraResampling = false
    var cameraTapSamplesBase = false
    private(set) var focusPoint: CGPoint?
    @ObservationIgnored private var focusFeedback: Task<Void, Never>?
    @ObservationIgnored private let renderer = NegativeRenderer()
    @ObservationIgnored private let camera: any NegativeCameraCapture
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var sampleRevision = UUID()
    @ObservationIgnored private var cameraRevision = UUID()
    @ObservationIgnored private var calibrationID: UUID?
    @ObservationIgnored private var beforeSamplingLive = false

    init(camera: any NegativeCameraCapture = NegativeCamera()) {
        self.camera = camera
    }

    var displayed: CGImage? { !sampling && showsPositive ? positive ?? imageState.original : imageState.original }
    var canExport: Bool { base != nil && asset != nil && !sampling && busy == nil }
    var canAdjustCamera: Bool { isCamera && live && busy == nil && !sampling && cameraConfiguration != nil }

    func reportImportError(_ error: Error) {
        // Picker cancellation is not an import failure, including provider cancellation.
        let cocoa = error as NSError
        guard !(error is CancellationError),
              !(cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError) else { return }
        self.error = error.localizedDescription
    }

    func loadFile(_ url: URL) { importImage { [renderer] in try await renderer.load(url) } }
    func loadPhoto(_ item: PhotosPickerItem) {
        importImage { [renderer] in
            guard let photo = try await item.loadTransferable(type: NegativePhoto.self) else { throw NegativeFailure(key: "negative.error.decode") }
            // Transfer the app-owned copy to the renderer, including cleanup on failure.
            return try await renderer.load(owned: photo.url)
        }
    }

    private func importImage(_ load: @escaping () async throws -> NegativeAsset) {
        cancelWork()
        freeze()
        let id = revision
        phase = .loading; error = nil
        operation = Task {
            do {
                let result = try await load()
                guard !Task.isCancelled, revision == id else { return }
                camera.stop(); cameraRevision = UUID()
                asset = result; imageState.original = result.preview; latestCameraAsset = nil; positive = nil; base = nil; candidate = nil
                isCamera = false; live = false; paused = false; sampling = false; showsPositive = false
            } catch {
                if revision == id && !Task.isCancelled { reportImportError(error) }
            }
            if revision == id { phase = nil }
        }
    }

    func startCamera() {
        cancelWork(); error = nil; cameraDenied = false
        // Invalidate old configuration callbacks before the permission await can yield.
        cameraRevision = UUID()
        let requestedSettings = cameraSettings
        focusFeedback?.cancel(); focusPoint = nil
        macroActive = false; needsCameraResampling = false; calibrationID = nil
        let id = revision
        phase = .cameraStarting
        operation = Task {
            let granted = await camera.requestAccess()
            guard revision == id, !Task.isCancelled else { return }
            guard granted else { phase = nil; cameraDenied = true; error = String(localized: "negative.error.permission"); return }
            let generation = UUID(); cameraRevision = generation
            base = nil; positive = nil; sampling = false; candidate = nil; showsPositive = false
            isCamera = true; live = true; paused = false; captureLocked = false
            camera.start(settings: requestedSettings, onConfiguration: { [weak self] configuration in
                Task { @MainActor [weak self] in
                    guard let self, self.cameraRevision == generation else { return }
                    self.cameraConfiguration = configuration
                    self.cameraSettings = configuration.settings
                }
            }) { [weak self] frame, acknowledge in
                Task { @MainActor [weak self] in
                    defer { acknowledge() }
                    guard let self, self.cameraRevision == generation, self.live else { return }
                    if let phase = self.phase, !phase.acceptsCameraFrame(frozenForSampling: frame.frozenForSampling) { return }
                    self.macroActive = frame.isMacro
                    if let previous = self.calibrationID, let current = frame.calibrationID, previous != current {
                        // Switching into or out of macro changes the optical/color pipeline.
                        self.needsCameraResampling = self.needsCameraResampling || self.base != nil
                        self.base = nil; self.positive = nil; self.showsPositive = false; self.captureLocked = false
                    }
                    self.calibrationID = frame.calibrationID
                    self.latestCameraAsset = frame.asset
                    if self.asset?.width != frame.asset.width || self.asset?.height != frame.asset.height || self.asset?.fileURL != nil || frame.frozenForSampling {
                        self.asset = frame.asset
                    }
                    self.imageState.original = frame.asset.preview; self.positive = frame.positive
                    self.phase = nil
                    if frame.frozenForSampling { self.live = false; self.captureLocked = true; self.beginSampling() }
                }
            } onError: { [weak self] key in
                Task { @MainActor [weak self] in
                    guard let self, self.cameraRevision == generation else { return }
                    // Freeze the last displayed source before allowing static sampling/export.
                    // Suspension also cancels pending renders and invalidates late callbacks.
                    self.suspend()
                    self.error = NSLocalizedString(key, comment: "Camera error")
                    // Interrupted configuration cannot retain a valid sampled base.
                    self.base = nil; self.positive = nil; self.showsPositive = false; self.camera.setBase(nil)
                }
            }
        }
    }

    func selectBase(at selected: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        guard asset != nil, busy == nil, !sampling,
              selected.x.isFinite, selected.y.isFinite,
              (0...1).contains(selected.x), (0...1).contains(selected.y) else { return }
        // Preserve a tap in source coordinates while exposure and white balance lock.
        point = selected
        beforeSamplingLive = live
        if isCamera && live {
            phase = .locking
            camera.sampleWhenLocked()
        } else { beginSampling() }
    }

    private func beginSampling() {
        sampling = true; candidate = nil; sampleError = nil
        sampleAtPoint()
    }

    func selectSamplePoint(_ selected: CGPoint) {
        guard sampling, busy == nil else { return }
        point = selected
        sampleAtPoint()
    }

    func sampleAtPoint() {
        guard sampling, busy == nil, let asset else { return }
        sampleTask?.cancel()
        let id = UUID(); sampleRevision = id
        let selected = point
        candidate = nil; sampleError = nil; candidateBusy = true
        sampleTask = Task {
            do {
                let value = try await renderer.sample(asset, point: selected)
                guard !Task.isCancelled, sampleRevision == id, sampling else { return }
                candidate = value
            } catch {
                if !Task.isCancelled && sampleRevision == id { sampleError = error.localizedDescription }
            }
            if sampleRevision == id { candidateBusy = false }
        }
    }

    func moveSample(x: CGFloat, y: CGFloat) {
        selectSamplePoint(CGPoint(x: min(0.98, max(0.02, point.x + x)), y: min(0.98, max(0.02, point.y + y))))
    }

    func confirmBase() {
        guard let candidate, let asset, busy == nil else { return }
        let id = revision
        phase = .rendering
        operation = Task {
            do {
                let result = try await renderer.render(asset, base: candidate)
                guard revision == id, !Task.isCancelled else { return }
                base = candidate; positive = result; sampling = false; showsPositive = true
                needsCameraResampling = false
                // Only the sampled RGB values persist for this capture session, not a frame history.
                camera.setBase(candidate)
                if isCamera && beforeSamplingLive && captureLocked && !paused { live = true; camera.freeze(false) }
            } catch { if revision == id && !Task.isCancelled { self.error = error.localizedDescription } }
            if revision == id { phase = nil }
        }
    }

    func cancelSampling() {
        let shouldResume = sampling && isCamera && beforeSamplingLive && !paused
        sampleTask?.cancel(); sampleRevision = UUID(); candidateBusy = false
        sampling = false; candidate = nil; sampleError = nil
        if shouldResume { live = true; camera.freeze(false) }
    }

    func freeze() {
        if isCamera { live = false; if let latestCameraAsset { asset = latestCameraAsset }; camera.freeze(true) }
    }
    func resume() {
        if paused { startCamera() }
        else {
            // A manually frozen auto-exposed frame is valid only as a static preview.
            if !captureLocked { base = nil; positive = nil; showsPositive = false; camera.setBase(nil) }
            live = true; camera.freeze(false)
        }
    }
    func focus(_ point: CGPoint) {
        guard canAdjustCamera, cameraConfiguration?.supportsFocus == true,
              NegativeFocusCoordinates.sensorPoint(point, rotation: 0) != nil else { return }
        camera.focus(point)
        // This reticle acknowledges the requested point, not a claim that focus has completed.
        focusPoint = point; focusFeedback?.cancel()
        focusFeedback = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.focusPoint = nil
        }
    }
    func setCameraLens(_ id: String) {
        guard canAdjustCamera, cameraConfiguration?.lenses.contains(where: { $0.id == id }) == true, id != cameraSettings.lensID else { return }
        cameraSettings.lensID = id
        startCamera()
    }
    func setCameraResolution(_ resolution: NegativeResolution) {
        guard canAdjustCamera, cameraConfiguration?.resolutions.contains(resolution) == true, resolution != cameraSettings.resolution else { return }
        cameraSettings.resolution = resolution
        startCamera()
    }
    func setExposureBias(_ bias: Float) {
        guard canAdjustCamera, bias.isFinite, let range = cameraConfiguration?.exposureRange else { return }
        let clamped = min(range.upperBound, max(range.lowerBound, bias))
        guard abs(clamped - cameraSettings.exposureBias) > 0.001 else { return }
        // Commit once at slider release. Any exposure change invalidates the sampled film base.
        cameraSettings.exposureBias = clamped
        startCamera()
    }
    func rotate(_ orientation: UIDeviceOrientation) {
        let angle: CGFloat
        switch orientation {
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        default: return
        }
        camera.rotate(angle)
    }

    func export(_ format: NegativeFormat) {
        guard canExport else { return }
        freeze()
        guard let asset, let base else { return }
        let id = revision
        phase = .exporting; error = nil
        operation = Task {
            do {
                let url = try await renderer.export(asset, base: base, format: format)
                guard revision == id, !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                share = NegativeShare(url: url)
            } catch { if revision == id && !Task.isCancelled { self.error = error.localizedDescription } }
            if revision == id { phase = nil }
        }
    }

    func cancelWork() {
        operation?.cancel(); operation = nil
        revision = UUID(); phase = nil
        if isCamera { freeze() }
    }
    func suspend() {
        focusFeedback?.cancel(); focusPoint = nil
        // Mark paused first so cancelling a sampling sheet cannot resume capture during suspension.
        if isCamera { paused = true }
        cancelWork(); cancelSampling()
        cameraRevision = UUID(); camera.stop()
        if isCamera { live = false; paused = true; captureLocked = false; base = nil; positive = nil; showsPositive = false }
    }
}

/// The share sheet retains its file through the system's asynchronous read lifetime.
nonisolated final class NegativeShare: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}
#endif

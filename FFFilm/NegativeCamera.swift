#if os(iOS)
@preconcurrency import AVFoundation
import CoreImage

nonisolated struct NegativeCameraFrame: @unchecked Sendable {
    let asset: NegativeAsset
    let positive: CGImage?
    let frozenForSampling: Bool
}

/// The workflow can exercise camera delivery and failure without capture hardware.
nonisolated protocol NegativeCameraCapture: Sendable {
    func requestAccess() async -> Bool
    func start(settings: NegativeCameraSettings, onConfiguration: @escaping @Sendable (NegativeCameraConfiguration) -> Void, onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void, onError: @escaping @Sendable (String) -> Void)
    func sampleWhenLocked()
    func setBase(_ value: NegativeBase?)
    func freeze(_ value: Bool)
    func stop()
    func focus(_ point: CGPoint)
    func continuousFocus()
    func rotate(_ angle: CGFloat)
}

/// Session, device, frame and rendering state belong exclusively to this serial queue.
/// Only immutable frame snapshots are delivered to the main actor.
nonisolated final class NegativeCamera: NSObject, NegativeCameraCapture, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FFFilm.negative.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    // A failed/interrupted session can stop before its notification reaches our queue.
    private var captureRequested = false
    private let context = NegativePixels.context()
    private var device: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private var frameHandler: (@Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void)?
    private var deliveringFrame = false
    private var awaitingLockCompletion = false
    private var lockedTimestamp = CMTime.invalid
    private var errorHandler: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var base: NegativeBase?
    private var frozen = false
    private var locking = false
    private var waitingForLockedFrame = false
    private var lockDeadline: CFAbsoluteTime = 0
    private var lockGeneration = UUID()
    private var stableFrames = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var rotation: CGFloat = 90
    private var deliveryGeneration = UUID()
    private var minimumFrameTimestamp = CMTime.invalid

    override init() {
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.captureRequested else { return }
                    self.stopOnQueue()
                    self.errorHandler?("negative.error.interrupted")
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.captureRequested, ProcessInfo.processInfo.thermalState == .critical else { return }
                self.stopOnQueue(); self.errorHandler?("negative.error.thermal")
            }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(settings: NegativeCameraSettings, onConfiguration: @escaping @Sendable (NegativeCameraConfiguration) -> Void, onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void, onError: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            frameHandler = onFrame; errorHandler = onError
            captureRequested = true
            do {
                // Stop before changing inputs/formats so old frames cannot enter the new calibration.
                session.stopRunning()
                context.clearCaches()
                let configuration = try configure(settings)
                guard let device else { throw NegativeFailure(key: "negative.error.camera") }
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .none }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                else if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                device.setExposureTargetBias(configuration.settings.exposureBias, completionHandler: nil)
                // Bound capture cadence as well as UI delivery; do not acquire 60fps only to discard it.
                if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                }
                device.unlockForConfiguration()
                base = nil; frozen = false; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; deliveringFrame = false
                deliveryGeneration = UUID(); lastFrameTime = 0
                minimumFrameTimestamp = CMClockGetTime(CMClockGetHostTimeClock())
                onConfiguration(configuration)
                session.startRunning()
            } catch { stopOnQueue(); onError("negative.error.camera") }
        }
    }

    private func configure(_ requested: NegativeCameraSettings) throws -> NegativeCameraConfiguration {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        guard let camera = devices.first(where: { $0.uniqueID == requested.lensID })
                ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            throw NegativeFailure(key: "negative.error.camera")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        let video = output ?? AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        // Match the selected video preset instead of allowing a lower-resolution preview proxy.
        video.automaticallyConfiguresOutputBufferDimensions = false
        video.deliversPreviewSizedOutputBuffers = false
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Capability checks depend on the selected input, not on the previous lens.
        // Drop a previous lens's 4K requirement before adding a lower-capability input.
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        for old in session.inputs { session.removeInput(old) }
        guard session.canAddInput(input) else { throw NegativeFailure(key: "negative.error.camera") }
        session.addInput(input)
        if output == nil {
            guard session.canAddOutput(video) else { throw NegativeFailure(key: "negative.error.camera") }
            session.addOutput(video)
            // Retain an added output even if a later capability check fails, so retry reuses it.
            output = video
        }
        let resolutions = NegativeResolution.allCases.filter { session.canSetSessionPreset($0.preset) }
        guard let resolution = resolutions.contains(requested.resolution) ? requested.resolution : resolutions.first else {
            throw NegativeFailure(key: "negative.error.camera")
        }
        session.sessionPreset = resolution.preset
        video.setSampleBufferDelegate(self, queue: queue)
        if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        device = camera; output = video
        let range = max(-3, camera.minExposureTargetBias)...min(3, camera.maxExposureTargetBias)
        let bias = requested.exposureBias.isFinite ? min(range.upperBound, max(range.lowerBound, requested.exposureBias)) : 0
        let lenses = devices.map { device in
            NegativeLens(id: device.uniqueID, titleKey: device.deviceType == .builtInUltraWideCamera ? "negative.lens.ultraWide" : device.deviceType == .builtInTelephotoCamera ? "negative.lens.telephoto" : "negative.lens.wide")
        }
        return NegativeCameraConfiguration(settings: NegativeCameraSettings(lensID: camera.uniqueID, resolution: resolution, exposureBias: bias),
            lenses: lenses, resolutions: resolutions, exposureRange: range,
            supportsFocus: camera.isFocusPointOfInterestSupported && camera.isFocusModeSupported(.autoFocus), minimumFocusDistance: camera.minimumFocusDistance)
    }

    func rotate(_ angle: CGFloat) {
        queue.async { [self] in
            rotation = angle
            guard let connection = output?.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    func focus(_ point: CGPoint) {
        queue.async { [self] in
            guard captureRequested, !frozen, let device, !locking, !awaitingLockCompletion, !waitingForLockedFrame,
                  let sensor = NegativeFocusCoordinates.sensorPoint(point, rotation: output?.connection(with: .video)?.videoRotationAngle ?? rotation) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = sensor
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
            } catch { errorHandler?("negative.error.camera") }
        }
    }

    func continuousFocus() {
        queue.async { [self] in
            guard captureRequested, !frozen, !locking, !awaitingLockCompletion, !waitingForLockedFrame, let device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                else if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            } catch { errorHandler?("negative.error.camera") }
        }
    }

    func sampleWhenLocked() {
        queue.async { [self] in
            frozen = false; locking = true; stableFrames = 0
            lockDeadline = CFAbsoluteTimeGetCurrent() + 5
            lockGeneration = UUID()
        }
    }
    func setBase(_ value: NegativeBase?) { queue.async { [self] in base = value } }
    func freeze(_ value: Bool) { queue.async { [self] in frozen = value; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; lockGeneration = UUID() } }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        captureRequested = false
        frozen = true; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; lockGeneration = UUID()
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !frozen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= minimumFrameTimestamp else { return }
        if (locking || awaitingLockCompletion || waitingForLockedFrame), CFAbsoluteTimeGetCurrent() > lockDeadline {
            locking = false; awaitingLockCompletion = false; waitingForLockedFrame = false; frozen = true
            lockGeneration = UUID(); errorHandler?("negative.error.lock"); return
        }
        if awaitingLockCompletion { return }
        if locking {
            guard let device, device.isExposureModeSupported(.locked), device.isWhiteBalanceModeSupported(.locked) else {
                locking = false; frozen = true; errorHandler?("negative.error.lock"); return
            }
            if CFAbsoluteTimeGetCurrent() > lockDeadline {
                locking = false; frozen = true; errorHandler?("negative.error.lock"); return
            }
            if device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance { stableFrames = 0; return }
            stableFrames += 1
            guard stableFrames >= 3 else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.exposureMode = .locked
                let generation = lockGeneration
                awaitingLockCompletion = true
                device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains) { [weak self] timestamp in
                    self?.queue.async { [weak self] in
                        guard let self, self.lockGeneration == generation else { return }
                        self.awaitingLockCompletion = false; self.lockedTimestamp = timestamp
                        self.waitingForLockedFrame = true; self.stableFrames = 0
                    }
                }
                locking = false
            } catch { locking = false; frozen = true; errorHandler?("negative.error.lock") }
            return
        }
        // Three subsequent frames ensure both locked settings have reached the video pipeline.
        if waitingForLockedFrame {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if lockedTimestamp.isValid && timestamp < lockedTimestamp { return }
            stableFrames += 1; if stableFrames < 3 { return }
        }
        guard !deliveringFrame else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let highResolution = CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer) > 1920 * 1080
        let fps: Double = ProcessInfo.processInfo.thermalState == .serious ? 10 : highResolution ? 15 : 30
        guard waitingForLockedFrame || now - lastFrameTime >= 1 / fps else { return }
        lastFrameTime = now
        autoreleasepool {
            do {
                let image = CIImage(cvPixelBuffer: buffer)
                // Materialize bounded camera pixels so holding a frame never pins a capture-pool buffer.
                guard let cg = context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: NegativePixels.linear) else {
                    throw NegativeFailure(key: "negative.error.render")
                }
                let retained = CIImage(cgImage: cg)
                let asset = NegativeAsset(image: retained, preview: cg)
                let rendered = try base.map { try NegativePixels.preview(retained, base: $0, context: context,
                    limit: max(retained.extent.width, retained.extent.height)) }
                let sample = waitingForLockedFrame
                if sample { frozen = true; waitingForLockedFrame = false }
                // One main-actor delivery at a time; a busy UI drops frames rather than retaining a queue of images.
                deliveringFrame = true
                let generation = deliveryGeneration
                frameHandler?(NegativeCameraFrame(asset: asset, positive: rendered, frozenForSampling: sample)) { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, self.deliveryGeneration == generation else { return }
                        self.deliveringFrame = false
                    }
                }
            } catch { errorHandler?("negative.error.render") }
        }
    }
}
#endif

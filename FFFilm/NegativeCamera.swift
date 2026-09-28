#if os(iOS)
@preconcurrency import AVFoundation
import CoreImage
import OSLog

nonisolated struct NegativeCameraFrame: @unchecked Sendable {
    let asset: NegativeAsset
    let positive: CGImage?
    let frozenForSampling: Bool
    var isMacro = false
    // Repeated on every frame so dropping one delivery cannot lose a lens-change event.
    var calibrationID: UUID?
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
    func rotate(_ angle: CGFloat)
}

/// Session, device, frame and rendering state belong exclusively to this serial queue.
/// Only immutable frame snapshots are delivered to the main actor.
nonisolated final class NegativeCamera: NSObject, NegativeCameraCapture, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FFFilm.negative.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    // A failed/interrupted session can stop before its notification reaches our queue.
    private var captureRequested = false
    // Initialize the GPU context only on the capture queue, not during SwiftUI view creation.
    private var renderContext: CIContext?
    private var context: CIContext {
        if let renderContext { return renderContext }
        let created = NegativePixels.context()
        renderContext = created
        return created
    }
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
    private var cadence = NegativeFrameCadence()
    private var requestedCaptureFPS: Double = 0
    private var highResolution = false
    private var rotation: CGFloat = 90
    private var deliveryGeneration = UUID()
    private var minimumFrameTimestamp = CMTime.invalid
    private var primaryDeviceID: String?
    private var lensSettlingFrames = 0
    private var calibrationID = UUID()
    #if DEBUG
    private let performanceLog = Logger(subsystem: "com.rasteaks.FFFilm", category: "NegativeCameraPerformance")
    private var performanceStart: CFAbsoluteTime = 0
    private var receivedFrames = 0, deliveredFrames = 0, throttledFrames = 0, busyFrames = 0, droppedFrames = 0
    private var renderSeconds: Double = 0
    #endif

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
                guard let self, self.captureRequested else { return }
                if ProcessInfo.processInfo.thermalState == .critical {
                    self.stopOnQueue(); self.errorHandler?("negative.error.thermal")
                } else { self.updateCaptureCadence() }
            }
        })
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        // Teardown must not bypass the queue's confinement; capture the session because
        // self is already being destroyed by the time the asynchronous stop runs.
        let session = session
        queue.async { session.stopRunning() }
    }

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
                // Reuse the context and compiled kernels across lens/format changes.
                let configuration = try configure(settings)
                guard let device else { throw NegativeFailure(key: "negative.error.camera") }
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .none }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                else if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isVirtualDevice {
                    // Match the wide camera's field of view while allowing an autofocus
                    // ultra-wide constituent to take over at macro distances.
                    if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                        device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                    }
                    let wideIndex = device.constituentDevices.firstIndex { $0.deviceType == .builtInWideAngleCamera } ?? 0
                    let zoom = wideIndex > 0 ? CGFloat(truncating: device.virtualDeviceSwitchOverVideoZoomFactors[wideIndex - 1]) : 1
                    device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, zoom))
                }
                device.unlockForConfiguration()
                highResolution = configuration.settings.resolution == .ultraHD
                requestedCaptureFPS = 0
                base = nil; frozen = false; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; deliveringFrame = false
                updateCaptureCadence()
                deliveryGeneration = UUID(); cadence = NegativeFrameCadence()
                primaryDeviceID = nil; lensSettlingFrames = 0; calibrationID = UUID()
                minimumFrameTimestamp = CMClockGetTime(CMClockGetHostTimeClock())
                #if DEBUG
                performanceStart = CFAbsoluteTimeGetCurrent()
                receivedFrames = 0; deliveredFrames = 0; throttledFrames = 0; busyFrames = 0; droppedFrames = 0; renderSeconds = 0
                #endif
                onConfiguration(configuration)
                session.startRunning()
            } catch { stopOnQueue(); onError("negative.error.camera") }
        }
    }

    private func configure(_ requested: NegativeCameraSettings) throws -> NegativeCameraConfiguration {
        let physical = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        let virtual = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualWideCamera, .builtInTripleCamera], mediaType: .video, position: .back).devices
        // Fixed-focus ultra-wide hardware cannot provide automatic macro capture.
        let macro = virtual.first { $0.deviceType == .builtInDualWideCamera && Self.supportsMacro($0) }
            ?? virtual.first(where: Self.supportsMacro)
        let devices = macro.map { [$0] + physical } ?? physical
        guard let camera = devices.first(where: { $0.uniqueID == requested.lensID })
                ?? macro ?? physical.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? physical.first else {
            throw NegativeFailure(key: "negative.error.camera")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        let video = output ?? AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        // Match the selected video preset instead of allowing a lower-resolution preview proxy.
        video.automaticallyConfiguresOutputBufferDimensions = false
        video.deliversPreviewSizedOutputBuffers = false
        session.beginConfiguration()
        var committed = false
        defer { if !committed { session.commitConfiguration() } }
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
        session.commitConfiguration(); committed = true
        // Availability depends on the selected input/format; query only after selecting them.
        guard let pixelFormat = NegativeCapturePixelFormat.preferred(in: video.availableVideoPixelFormatTypes) else {
            throw NegativeFailure(key: "negative.error.camera")
        }
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        video.setSampleBufferDelegate(self, queue: queue)
        if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        device = camera; output = video
        let lenses = devices.map { device in
            NegativeLens(id: device.uniqueID, titleKey: device.isVirtualDevice ? "negative.lens.automatic" : device.deviceType == .builtInUltraWideCamera ? "negative.lens.ultraWide" : device.deviceType == .builtInTelephotoCamera ? "negative.lens.telephoto" : "negative.lens.wide")
        }
        return NegativeCameraConfiguration(settings: NegativeCameraSettings(lensID: camera.uniqueID, resolution: resolution),
            lenses: lenses, resolutions: resolutions,
            supportsFocus: camera.isFocusPointOfInterestSupported && (camera.isFocusModeSupported(.continuousAutoFocus) || camera.isFocusModeSupported(.autoFocus)),
            minimumFocusDistance: camera.minimumFocusDistance, automaticMacro: camera.uniqueID == macro?.uniqueID)
    }

    private static func supportsMacro(_ device: AVCaptureDevice) -> Bool {
        device.primaryConstituentDeviceSwitchingBehavior != .unsupported && device.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera && $0.isFocusModeSupported(.continuousAutoFocus)
        }
    }

    private var targetFPS: Double {
        let pressure = device?.systemPressureState.level
        if ProcessInfo.processInfo.thermalState == .serious || pressure == .serious || pressure == .critical || pressure == .shutdown { return 10 }
        return highResolution ? 15 : 30
    }

    private func updateCaptureCadence() {
        guard let device else { return }
        // Shortening a calibrated exposure's frame duration can alter its brightness.
        // Preserve locks; the software delivery cap still responds to heat/pressure.
        guard !locking, !awaitingLockCompletion, !waitingForLockedFrame,
              base == nil, device.exposureMode != .locked else { return }
        let fps = targetFPS
        guard requestedCaptureFPS != fps else { return }
        // Remember unsupported requests too; never lock/reconfigure the device every frame.
        requestedCaptureFPS = fps
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let duration = CMTime(value: 1, timescale: Int32(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            // Frame delivery remains bounded even when a hardware rate change is unavailable.
            #if DEBUG
            performanceLog.debug("Capture frame-rate adjustment unavailable")
            #endif
        }
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
                    // A tap moves the tracking region; it must not stop continuous AF.
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    else if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
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
    func freeze(_ value: Bool) {
        queue.async { [self] in
            frozen = value; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; lockGeneration = UUID()
            // Sampling temporarily pins the lens. Live preview always restores automatic switching.
            if !value, let device, device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                do {
                    try device.lockForConfiguration()
                    device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                    device.unlockForConfiguration()
                } catch { errorHandler?("negative.error.camera") }
            }
        }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        captureRequested = false
        frozen = true; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; lockGeneration = UUID()
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !frozen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        #if DEBUG
        receivedFrames += 1
        defer { reportPerformanceIfNeeded() }
        #endif
        updateCaptureCadence()
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= minimumFrameTimestamp else { return }
        if let device, let primary = device.activePrimaryConstituent {
            if let previous = primaryDeviceID, previous != primary.uniqueID {
                // Never apply a physical lens's RGB calibration to another lens.
                base = nil; calibrationID = UUID(); stableFrames = 0; lensSettlingFrames = 3
                if locking || awaitingLockCompletion || waitingForLockedFrame {
                    // A late constituent change invalidates the old lens's lock completion.
                    lockGeneration = UUID(); locking = true
                    awaitingLockCompletion = false; waitingForLockedFrame = false
                }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                } catch { errorHandler?("negative.error.camera"); return }
            }
            primaryDeviceID = primary.uniqueID
        }
        // Drop transition buffers and restart stability counting before a new sample.
        if lensSettlingFrames > 0 { lensSettlingFrames -= 1; return }
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
                if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                    device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
                }
                device.exposureMode = .locked
                let generation = lockGeneration
                awaitingLockCompletion = true
                // Freeze the current AWB result using the sentinel: reading gains back and
                // supplying them explicitly requires custom-gain support, which virtual cameras may lack.
                device.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains) { [weak self] timestamp in
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
        guard !deliveringFrame else {
            #if DEBUG
            busyFrames += 1
            #endif
            return
        }
        guard cadence.shouldDeliver(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), fps: targetFPS, force: waitingForLockedFrame) else {
            #if DEBUG
            throttledFrames += 1
            #endif
            return
        }
        #if DEBUG
        let renderStart = CFAbsoluteTimeGetCurrent()
        defer { renderSeconds += CFAbsoluteTimeGetCurrent() - renderStart }
        #endif
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
                #if DEBUG
                deliveredFrames += 1
                #endif
                let isMacro = device?.isVirtualDevice == true && device?.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera
                frameHandler?(NegativeCameraFrame(asset: asset, positive: rendered, frozenForSampling: sample,
                    isMacro: isMacro, calibrationID: calibrationID)) { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, self.deliveryGeneration == generation else { return }
                        self.deliveringFrame = false
                    }
                }
            } catch { errorHandler?("negative.error.render") }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        #if DEBUG
        droppedFrames += 1
        reportPerformanceIfNeeded()
        #endif
    }

    #if DEBUG
    private func reportPerformanceIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent(), elapsed = now - performanceStart
        guard performanceStart > 0, elapsed >= 5 else { return }
        // One aggregate every five seconds; never log images, device identifiers or per-frame payloads.
        let fps = Double(deliveredFrames) / elapsed
        let milliseconds = deliveredFrames > 0 ? renderSeconds * 1000 / Double(deliveredFrames) : 0
        performanceLog.debug("Preview fps=\(fps, privacy: .public) render_ms=\(milliseconds, privacy: .public) received=\(self.receivedFrames) throttled=\(self.throttledFrames) ui_busy=\(self.busyFrames) capture_dropped=\(self.droppedFrames)")
        performanceStart = now
        receivedFrames = 0; deliveredFrames = 0; throttledFrames = 0; busyFrames = 0; droppedFrames = 0; renderSeconds = 0
    }
    #endif
}
#endif

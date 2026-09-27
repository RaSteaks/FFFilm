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
    func start(onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void, onError: @escaping @Sendable (String) -> Void)
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

    func start(onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void, onError: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            frameHandler = onFrame; errorHandler = onError
            captureRequested = true
            do {
                if device == nil { try configure() }
                guard let device else { throw NegativeFailure(key: "negative.error.camera") }
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
                base = nil; frozen = false; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; deliveringFrame = false
                session.startRunning()
            } catch { stopOnQueue(); onError("negative.error.camera") }
        }
    }

    private func configure() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw NegativeFailure(key: "negative.error.camera")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input), session.canAddOutput(video) else { throw NegativeFailure(key: "negative.error.camera") }
        session.addInput(input); session.addOutput(video)
        video.setSampleBufferDelegate(self, queue: queue)
        if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        device = camera; output = video
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
            guard let device, !locking else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    // Convert the oriented preview point to the sensor's landscape coordinates.
                    let angle = output?.connection(with: .video)?.videoRotationAngle ?? 90
                    let sensor: CGPoint
                    switch Int(angle) {
                    case 90: sensor = CGPoint(x: point.y, y: 1 - point.x)
                    case 180: sensor = CGPoint(x: 1 - point.x, y: 1 - point.y)
                    case 270: sensor = CGPoint(x: 1 - point.y, y: point.x)
                    default: sensor = point
                    }
                    device.focusPointOfInterest = sensor
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
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
    func freeze(_ value: Bool) { queue.async { [self] in frozen = value; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; lockGeneration = UUID() } }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        captureRequested = false
        frozen = true; locking = false; waitingForLockedFrame = false; awaitingLockCompletion = false; lockGeneration = UUID()
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !frozen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
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
            if device.isAdjustingExposure || device.isAdjustingWhiteBalance { stableFrames = 0; return }
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
        guard waitingForLockedFrame || now - lastFrameTime >= (ProcessInfo.processInfo.thermalState == .serious ? 1.0 / 10 : 1.0 / 30) else { return }
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
                let rendered = try base.map { try NegativePixels.preview(retained, base: $0, context: context) }
                let sample = waitingForLockedFrame
                if sample { frozen = true; waitingForLockedFrame = false }
                // One main-actor delivery at a time; a busy UI drops frames rather than retaining a queue of images.
                deliveringFrame = true
                frameHandler?(NegativeCameraFrame(asset: asset, positive: rendered, frozenForSampling: sample)) { [weak self] in
                    self?.queue.async { [weak self] in self?.deliveringFrame = false }
                }
            } catch { errorHandler?("negative.error.render") }
        }
    }
}
#endif

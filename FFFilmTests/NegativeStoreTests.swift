#if os(iOS)
import Testing
import CoreImage
@testable import FFFilm

@MainActor
struct NegativeStoreTests {
    @Test func automaticLensSwitchRequiresNewCalibrationInBothDirections() async throws {
        let camera = StubNegativeCamera(), store = NegativeStore(camera: camera)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1,
                                          colorSpace: NegativePixels.linear)!).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 96))
        let asset = NegativeAsset(image: image, preview: try NegativePixels.preview(image, context: NegativePixels.context()))
        store.startCamera()
        try await waitFor { camera.hasStarted }
        camera.deliver(asset)
        try await waitFor { store.canAdjustCamera }
        store.selectBase()
        camera.deliver(asset, frozenForSampling: true)
        try await waitFor { store.sampling && store.candidate != nil && store.phase == nil }
        store.confirmBase()
        try await waitUntilIdle(store)
        #expect(store.canExport && store.captureLocked)

        for macro in [true, false] {
            // Entering and leaving the macro lens both invalidate optical calibration.
            camera.deliver(asset, isMacro: macro, calibrationInvalidated: true)
            try await waitFor { store.base == nil }
            #expect(store.macroActive == macro && store.needsCameraResampling)
            #expect(!store.canExport && !store.captureLocked && !store.showsPositive && store.live)
            camera.deliver(asset, isMacro: macro)
            await Task.yield()
            #expect(store.needsCameraResampling)
            store.selectBase(at: CGPoint(x: 0.3, y: 0.2))
            camera.deliver(asset, frozenForSampling: true, isMacro: macro)
            try await waitFor { store.sampling && store.candidate != nil && store.phase == nil }
            store.confirmBase()
            try await waitUntilIdle(store)
            #expect(store.canExport && !store.needsCameraResampling && store.live)
        }
        // A lens switch while acquiring a new locked sample cannot retain the old base.
        store.selectBase()
        camera.deliver(asset, isMacro: true, calibrationInvalidated: true)
        await Task.yield()
        // The normal frame is rejected during locking; the generation on the subsequent
        // frozen frame must still clear calibration even without a repeated switch event.
        camera.deliver(asset, frozenForSampling: true, isMacro: true)
        try await waitFor { store.sampling && store.candidate != nil && store.phase == nil }
        store.cancelSampling()
        #expect(store.base == nil && !store.canExport && store.needsCameraResampling)
        store.suspend()
    }

    @Test func focusCoordinatesFollowAllCaptureRotations() {
        let point = CGPoint(x: 0.2, y: 0.3)
        #expect(NegativeFocusCoordinates.sensorPoint(point, rotation: 0) == point)
        #expect(NegativeFocusCoordinates.sensorPoint(point, rotation: 90) == CGPoint(x: 0.3, y: 0.8))
        #expect(NegativeFocusCoordinates.sensorPoint(point, rotation: 180) == CGPoint(x: 0.8, y: 0.7))
        #expect(NegativeFocusCoordinates.sensorPoint(point, rotation: 270) == CGPoint(x: 0.7, y: 0.2))
        #expect(NegativeFocusCoordinates.sensorPoint(CGPoint(x: -1, y: 0.5), rotation: 90) == nil)
        #expect(NegativeFocusCoordinates.sensorPoint(CGPoint(x: CGFloat.nan, y: 0.5), rotation: 90) == nil)
    }

    @Test func cameraControlsRespectCapabilitiesAndInvalidateCalibration() async throws {
        let camera = StubNegativeCamera(), store = NegativeStore(camera: camera)
        let context = NegativePixels.context()
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1,
                                          colorSpace: NegativePixels.linear)!).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 96))
        let asset = NegativeAsset(image: image, preview: try NegativePixels.preview(image, context: context))
        store.startCamera()
        try await waitFor { camera.hasStarted }
        camera.deliver(asset)
        try await waitFor { store.canAdjustCamera }
        #expect(!store.cameraTapSamplesBase)
        store.focus(CGPoint(x: 0.2, y: 0.3))
        #expect(camera.lastFocus == CGPoint(x: 0.2, y: 0.3) && !store.sampling && store.busy == nil)
        store.selectBase()
        // Focus changes must not race exposure/white-balance locking.
        store.focus(CGPoint(x: 0.8, y: 0.7))
        #expect(camera.lastFocus == CGPoint(x: 0.2, y: 0.3))
        camera.deliver(asset, frozenForSampling: true)
        try await waitFor { store.candidate != nil }
        store.confirmBase()
        try await waitUntilIdle(store)
        #expect(store.base != nil && store.canExport)
        store.setExposureBias(9)
        try await waitFor { camera.lastSettings.exposureBias == 2 }
        #expect(store.base == nil && !store.canExport && !store.captureLocked)
        camera.deliver(asset)
        try await waitFor { store.canAdjustCamera }
        let starts = camera.startCount
        store.setExposureBias(.nan)
        store.setCameraLens("missing")
        store.setCameraResolution(.ultraHD)
        #expect(camera.startCount == starts)
        store.setCameraResolution(.fullHD)
        try await waitFor { camera.lastSettings.resolution == .fullHD }
        camera.deliver(asset)
        try await waitFor { store.canAdjustCamera }
        store.setCameraLens("ultra")
        try await waitFor { camera.lastSettings.lensID == "ultra" }
        #expect(store.cameraSettings.exposureBias == 2)
        store.suspend()
        let stoppedSettings = store.cameraSettings
        store.setExposureBias(0)
        #expect(store.cameraSettings == stoppedSettings)
    }

    @Test func tappedCameraBaseSurvivesLockAndDrivesSessionPreview() async throws {
        let camera = StubNegativeCamera(), store = NegativeStore(camera: camera)
        let context = NegativePixels.context()
        let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
        let background = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1,
                                               colorSpace: NegativePixels.linear)!).cropped(to: extent)
        let edge = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1,
                                         colorSpace: NegativePixels.linear)!)
            .cropped(to: CGRect(x: 0, y: 150, width: 200, height: 50))
        let image = edge.composited(over: background)
        let asset = NegativeAsset(image: image, preview: try NegativePixels.preview(image, context: context))
        store.startCamera()
        try await waitFor { camera.hasStarted }
        camera.deliver(asset)
        try await waitFor { store.asset != nil }
        let tapped = CGPoint(x: 0.3, y: 0.1)
        store.selectBase(at: tapped)
        #expect(camera.requestedLock && store.phase == .locking)
        // The lock callback must sample the tapped edge, not silently reset to image center.
        camera.deliver(asset, frozenForSampling: true)
        try await waitFor { store.candidate != nil }
        #expect(store.point == tapped && store.captureLocked && !store.live)
        #expect(abs(try #require(store.candidate).red - 0.6) < 0.001)
        store.selectSamplePoint(CGPoint(x: 0.5, y: 0.5))
        try await waitUntilIdle(store)
        #expect(abs(try #require(store.candidate).red - 0.2) < 0.001)
        store.selectSamplePoint(tapped)
        try await waitUntilIdle(store)
        store.confirmBase()
        try await waitUntilIdle(store)
        #expect(store.showsPositive && store.live && !store.sampling)
        #expect(camera.storedBase == store.base && store.base != nil)
        #expect(store.imageState.positive != nil)
        // Re-sampling is provisional, and camera restart clears the temporary calibration.
        let committed = store.base
        store.selectBase()
        camera.deliver(asset, frozenForSampling: true)
        try await waitFor { store.sampling }
        store.cancelSampling()
        #expect(store.base == committed && camera.storedBase == committed && store.live)
        store.startCamera()
        try await waitFor { store.base == nil }
        #expect(camera.storedBase == nil && !store.showsPositive)
        store.suspend()
    }

    @Test func importCancellationDoesNotBecomeAnError() {
        let store = NegativeStore()
        store.reportImportError(CocoaError(.userCancelled))
        store.reportImportError(CancellationError())
        #expect(store.error == nil)
        store.reportImportError(CocoaError(.fileReadNoSuchFile))
        #expect(store.error != nil)
    }

    @Test func cameraFramesRespectWorkflowPhase() {
        // Only startup and a completed lock may consume frames while busy.
        for phase in [NegativeStore.Phase.loading, .rendering, .exporting] {
            #expect(!phase.acceptsCameraFrame(frozenForSampling: false))
            #expect(!phase.acceptsCameraFrame(frozenForSampling: true))
        }
        #expect(NegativeStore.Phase.cameraStarting.acceptsCameraFrame(frozenForSampling: false))
        #expect(!NegativeStore.Phase.locking.acceptsCameraFrame(frozenForSampling: false))
        #expect(NegativeStore.Phase.locking.acceptsCameraFrame(frozenForSampling: true))
    }

    private func waitUntilIdle(_ store: NegativeStore) async throws {
        for _ in 0..<200 {
            if store.busy == nil && !store.candidateBusy { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Negative operation did not finish")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func cameraFailureBeforeFirstFrameEndsLoading() async throws {
        let camera = StubNegativeCamera(), store = NegativeStore(camera: camera)
        store.startCamera()
        try await waitFor { camera.hasStarted }
        #expect(store.busy != nil)
        camera.fail()
        try await waitFor { store.error != nil }
        #expect(store.busy == nil && store.paused && !store.live)
        #expect(!store.canExport && !store.captureLocked)
    }

    @Test func interruptedPreviewSamplesAndExportsLastDisplayedFrame() async throws {
        let camera = StubNegativeCamera(), store = NegativeStore(camera: camera)
        let context = NegativePixels.context()
        func asset(_ red: CGFloat) throws -> NegativeAsset {
            let image = CIImage(color: CIColor(red: red, green: 0.4, blue: 0.2,
                                               alpha: 1, colorSpace: NegativePixels.linear)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            return NegativeAsset(image: image, preview: try NegativePixels.preview(image, context: context))
        }
        let first = try asset(0.25), latest = try asset(0.6)
        store.startCamera()
        try await waitFor { camera.hasStarted }
        camera.deliver(first)
        try await waitFor { store.imageState.original === first.preview }
        camera.deliver(latest)
        try await waitFor { store.imageState.original === latest.preview }
        // Same-size live frames intentionally avoid replacing the observable source.
        #expect(store.asset === first)
        camera.fail()
        try await waitFor { store.paused }
        #expect(store.asset === latest && store.imageState.original === latest.preview)
        #expect(store.base == nil && !store.canExport)

        // Late frames from the interrupted session cannot replace the frozen source.
        camera.deliver(first)
        store.selectBase()
        try await waitUntilIdle(store)
        let sample = try #require(store.candidate)
        #expect(abs(sample.red - 0.6) < 0.001)
        store.confirmBase()
        try await waitUntilIdle(store)
        #expect(store.canExport && !store.live)
        store.export(.png)
        try await waitUntilIdle(store)
        let output = try #require(store.share)
        let exported = try #require(CIImage(contentsOf: output.url))
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(exported, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: NegativePixels.display)
        // A uniform image sampled from itself must export black, not the old frame's positive.
        #expect(pixel.prefix(3).allSatisfy { $0 < 3 })
        store.share = nil
    }

    @Test func failedAndCancelledImportsPreserveCurrentPositive() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("store-negative-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = NegativePixels.context()
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try context.writeTIFFRepresentation(of: image, to: file, format: .RGBA16, colorSpace: NegativePixels.display)
        let store = NegativeStore()
        store.loadFile(file); try await waitUntilIdle(store)
        #expect(!store.showsPositive && !store.canExport)
        store.selectBase(); try await waitUntilIdle(store)
        #expect(store.candidate != nil)
        store.confirmBase(); try await waitUntilIdle(store)
        #expect(store.canExport && store.showsPositive)
        let original = store.asset, base = store.base
        store.suspend()
        #expect(store.base == base && store.canExport)
        store.loadFile(file.appendingPathExtension("missing")); try await waitUntilIdle(store)
        #expect(store.asset === original && store.base == base && store.canExport)
        #expect(store.error != nil)
        store.loadFile(file); store.cancelWork()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.asset === original && store.base == base)
        store.selectBase(); store.cancelSampling()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.sampling && store.base == base && store.canExport)
        store.loadFile(file); try await waitUntilIdle(store)
        #expect(store.asset !== original && store.base == nil && !store.canExport && !store.showsPositive)
    }
}
/// Thread-safe callback source models camera errors even when no session is running.
nonisolated private final class StubNegativeCamera: NegativeCameraCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var frameHandler: (@Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void)?
    private var errorHandler: (@Sendable (String) -> Void)?
    private var base: NegativeBase?
    private var lockRequested = false
    private var settings = NegativeCameraSettings()
    private var starts = 0
    private var focusedPoint: CGPoint?
    private var calibrationID = UUID()
    var lastSettings: NegativeCameraSettings { lock.withLock { settings } }
    var startCount: Int { lock.withLock { starts } }
    var lastFocus: CGPoint? { lock.withLock { focusedPoint } }
    var storedBase: NegativeBase? { lock.withLock { base } }
    var requestedLock: Bool { lock.withLock { lockRequested } }
    var hasStarted: Bool { lock.withLock { frameHandler != nil } }
    func requestAccess() async -> Bool { true }
    func start(settings: NegativeCameraSettings, onConfiguration: @escaping @Sendable (NegativeCameraConfiguration) -> Void, onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void,
               onError: @escaping @Sendable (String) -> Void) {
        var effective = settings
        effective.lensID = settings.lensID ?? "wide"
        lock.withLock { frameHandler = onFrame; errorHandler = onError; base = nil; lockRequested = false; self.settings = effective; starts += 1 }
        onConfiguration(NegativeCameraConfiguration(settings: effective,
            lenses: [NegativeLens(id: "wide", titleKey: "negative.lens.wide"), NegativeLens(id: "ultra", titleKey: "negative.lens.ultraWide")],
            resolutions: [.hd, .fullHD], exposureRange: -2...2, supportsFocus: true, minimumFocusDistance: 100))
    }
    func deliver(_ asset: NegativeAsset, frozenForSampling: Bool = false, isMacro: Bool = false, calibrationInvalidated: Bool = false) {
        let (handler, generation) = lock.withLock {
            if calibrationInvalidated { calibrationID = UUID() }
            return (frameHandler, calibrationID)
        }
        handler?(NegativeCameraFrame(asset: asset, positive: nil, frozenForSampling: frozenForSampling,
            isMacro: isMacro, calibrationID: generation), {})
    }
    func fail() {
        let handler = lock.withLock { errorHandler }
        handler?("negative.error.interrupted")
    }
    func sampleWhenLocked() { lock.withLock { lockRequested = true } }
    func setBase(_ value: NegativeBase?) { lock.withLock { base = value } }
    func freeze(_ value: Bool) {}
    func stop() {}
    func focus(_ point: CGPoint) { lock.withLock { focusedPoint = point } }
    func rotate(_ angle: CGFloat) {}
}
#endif

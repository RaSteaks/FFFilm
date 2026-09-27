#if os(iOS)
import Testing
import CoreImage
@testable import FFFilm

@MainActor
struct NegativeStoreTests {
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
    var hasStarted: Bool { lock.withLock { frameHandler != nil } }
    func requestAccess() async -> Bool { true }
    func start(onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void,
               onError: @escaping @Sendable (String) -> Void) {
        lock.withLock { frameHandler = onFrame; errorHandler = onError }
    }
    func deliver(_ asset: NegativeAsset) {
        let handler = lock.withLock { frameHandler }
        handler?(NegativeCameraFrame(asset: asset, positive: nil, frozenForSampling: false), {})
    }
    func fail() {
        let handler = lock.withLock { errorHandler }
        handler?("negative.error.interrupted")
    }
    func sampleWhenLocked() {}
    func setBase(_ value: NegativeBase?) {}
    func freeze(_ value: Bool) {}
    func stop() {}
    func focus(_ point: CGPoint) {}
    func rotate(_ angle: CGFloat) {}
}
#endif

#if os(iOS)
import Testing
import CoreImage
import UIKit
@testable import FFFilm

@MainActor
struct NegativeStoreTests {
    @Test func externalFilesReplaceSourcesAndPreserveFailedImports() async throws {
        let first = try externalFixture(width: 100, height: 70)
        let second = try externalFixture(width: 80, height: 120)
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID()).tiff")
        defer { for url in [first, second, invalid] { try? FileManager.default.removeItem(at: url) } }
        try Data("not an image".utf8).write(to: invalid)
        let store = NegativeStore()
        store.openExternalFile(first); try await waitUntilIdle(store)
        #expect(store.asset?.width == 100 && store.asset?.fileURL != first)
        let request = store.externalOpenID
        store.selectBase(); try await waitUntilIdle(store)
        store.confirmBase(); try await waitUntilIdle(store)
        let old = store.asset
        store.openExternalFile(invalid); try await waitUntilIdle(store)
        #expect(store.error != nil && store.asset === old && store.canExport)
        store.openExternalFile(URL(string: "https://example.com/photo.tiff")!)
        #expect(store.error != nil && store.asset === old)
        store.openExternalFile(second); try await waitUntilIdle(store)
        #expect(store.externalOpenID != request && store.asset?.width == 80 && store.asset?.height == 120)
        #expect(store.error == nil && store.base == nil && !store.showsPositive)
        try FileManager.default.removeItem(at: second)
        // Decoding owns a private copy and remains usable after the sender removes its file.
        store.selectBase(); try await waitUntilIdle(store)
        #expect(store.candidate != nil)
        store.cancelSampling(); store.suspend()
    }

    @Test func externalOpenWaitsForSubmittedPhotoSave() async throws {
        let library = StubNegativePhotoLibrary()
        let store = try await photoStore(library)
        let first = try externalFixture(width: 90, height: 60)
        let latest = try externalFixture(width: 70, height: 100)
        defer { for url in [first, latest] { try? FileManager.default.removeItem(at: url) } }
        library.holdSave = true
        store.saveToPhotos()
        try await waitFor { library.completion != nil }
        store.openExternalFile(first)
        store.openExternalFile(latest)
        #expect(store.phase == .savingPhotos && store.asset?.width == 96)
        library.completion?.resume(); library.completion = nil
        try await waitFor { store.busy == nil && store.asset?.width == 70 }
        #expect(store.asset?.height == 100 && store.base == nil && library.saved.count == 1)
        #expect(library.saved.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    private func externalFixture(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID()).tiff")
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        try NegativePixels.context().writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: NegativePixels.display)
        return url
    }

    @Test func savePositiveToPhotosPreservesSizeAndCleansUp() async throws {
        let library = StubNegativePhotoLibrary()
        let store = try await photoStore(library)
        store.showsPositive = false
        store.saveToPhotos()
        store.saveToPhotos() // A duplicate tap while pending must not create another asset.
        try await waitUntilIdle(store)
        #expect(library.requests == 1 && library.saved.count == 1)
        #expect(library.dimensions == CGSize(width: 96, height: 64))
        #expect(library.saved.first?.pathExtension == "jpg")
        #expect(store.photoNotice == String(localized: "negative.photos.saved"))
        #expect(store.share == nil && store.canExport)
        #expect(library.saved.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func photoPermissionAndWriteFailuresRemainRetryable() async throws {
        let library = StubNegativePhotoLibrary()
        let store = try await photoStore(library)
        library.allowed = false
        store.saveToPhotos(); try await waitUntilIdle(store)
        #expect(store.photoAccessDenied && library.saved.isEmpty && store.canExport)
        library.allowed = true; library.fails = true
        store.saveToPhotos(); try await waitUntilIdle(store)
        #expect(!store.photoAccessDenied && store.photoNotice != nil && store.canExport)
        #expect(library.saved.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        library.fails = false
        store.saveToPhotos(); try await waitUntilIdle(store)
        #expect(store.photoNotice == String(localized: "negative.photos.saved"))
    }

    @Test func photoSaveCancellationStopsBeforeCommitButRetainsSubmittedFile() async throws {
        let library = StubNegativePhotoLibrary()
        let store = try await photoStore(library)
        library.holdAuthorization = true
        store.saveToPhotos()
        try await waitFor { library.authorization != nil }
        store.cancelWork()
        library.authorization?.resume(returning: true); library.authorization = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(library.saved.isEmpty && store.photoNotice == nil)
        library.holdAuthorization = false; library.holdSave = true
        store.saveToPhotos()
        try await waitFor { library.completion != nil }
        #expect(store.phase == .savingPhotos)
        store.cancelWork(); store.suspend(); store.saveToPhotos()
        #expect(store.phase == .savingPhotos && library.saved.count == 1)
        #expect(library.saved.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        library.completion?.resume(); library.completion = nil
        try await waitUntilIdle(store)
        #expect(store.photoNotice == String(localized: "negative.photos.saved"))
        #expect(library.saved.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    private func photoStore(_ library: StubNegativePhotoLibrary) async throws -> NegativeStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("photo-test-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        try NegativePixels.context().writeTIFFRepresentation(of: image, to: file, format: .RGBA16, colorSpace: NegativePixels.display)
        let store = NegativeStore(photoLibrary: library)
        store.loadFile(file); try await waitUntilIdle(store)
        store.selectBase(); try await waitUntilIdle(store)
        store.confirmBase(); try await waitUntilIdle(store)
        return store
    }

    @Test func displayUpgradeNeverDowngradesEitherComparisonVariant() throws {
        let context = NegativePixels.context()
        func bitmap(_ side: CGFloat) throws -> CGImage {
            try NegativePixels.preview(CIImage(color: .white).cropped(to:
                CGRect(x: 0, y: 0, width: side, height: side)), context: context)
        }
        let small = try bitmap(64), current = try bitmap(128), equal = try bitmap(128), sharper = try bitmap(256)
        let state = NegativeImageState()
        for isPositive in [false, true] {
            state.publishSharper(current, positive: isPositive)
            // Simulate the result of a memory-capped render, independent of device RAM.
            state.publishSharper(small, positive: isPositive)
            state.publishSharper(equal, positive: isPositive)
            #expect((isPositive ? state.positive : state.original) === current)
            state.publishSharper(sharper, positive: isPositive)
            #expect((isPositive ? state.positive : state.original) === sharper)
        }
    }

    @Test func sourceChangesResetViewportButDisplayTiersPreserveIt() throws {
        let context = NegativePixels.context()
        func bitmap(_ width: CGFloat, _ height: CGFloat) throws -> CGImage {
            try NegativePixels.preview(CIImage(color: .white).cropped(to:
                CGRect(x: 0, y: 0, width: width, height: height)), context: context)
        }
        let initial = try bitmap(300, 300), sharper = try bitmap(600, 600)
        let view = NegativeZoomView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let first = URL(fileURLWithPath: "/tmp/first-negative.tiff")
        func show(_ image: CGImage, source: URL) {
            view.setImage(image, sourceURL: source, sampling: false, point: CGPoint(x: 0.5, y: 0.5))
            view.layoutIfNeeded()
        }
        show(initial, source: first)
        view.setZoomScale(2, animated: false)
        view.contentOffset = CGPoint(x: 80, y: 100)
        show(sharper, source: first)
        #expect(abs(view.zoomScale - 2) < 0.001)
        #expect(abs(view.contentOffset.x - 80) < 1 && abs(view.contentOffset.y - 100) < 1)
        // Both a different aspect ratio and identical bitmap dimensions are new sources.
        for (index, image) in [try bitmap(300, 150), try bitmap(300, 150)].enumerated() {
            view.setZoomScale(3, animated: false)
            view.contentOffset = CGPoint(x: 70, y: 30)
            show(image, source: URL(fileURLWithPath: "/tmp/replacement-\(index).tiff"))
            #expect(view.zoomScale == 1)
            #expect(abs(view.contentOffset.x + view.contentInset.left) < 1)
            #expect(abs(view.contentOffset.y + view.contentInset.top) < 1)
            #expect(view.contentSize.width <= view.bounds.width && view.contentSize.height <= view.bounds.height)
        }
    }

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
        let starts = camera.startCount
        store.setCameraLens("missing")
        store.setCameraResolution(.ultraHD)
        #expect(camera.startCount == starts)
        store.setCameraResolution(.fullHD)
        try await waitFor { camera.lastSettings.resolution == .fullHD }
        // A committed settings change invalidates calibration and requires re-sampling.
        #expect(store.base == nil && !store.canExport && !store.captureLocked)
        camera.deliver(asset)
        try await waitFor { store.canAdjustCamera }
        store.setCameraLens("ultra")
        try await waitFor { camera.lastSettings.lensID == "ultra" }
        store.suspend()
        let stoppedSettings = store.cameraSettings
        store.setCameraResolution(.hd)
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

    @Test func zoomDemandSharpensFilePreviewTiersOnly() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("store-negative-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = NegativePixels.context()
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 2200, height: 1400))
        try context.writeTIFFRepresentation(of: image, to: file, format: .RGBA16, colorSpace: NegativePixels.display)
        let store = NegativeStore()
        store.loadFile(file); try await waitUntilIdle(store)
        let initial = store.imageState.original
        #expect(initial?.width == 1800)
        store.displayNeeds(100)
        store.displayNeeds(4000)
        // The demand is clamped to the source long side and debounced past the settled pinch.
        for _ in 0..<600 where !(store.imageState.original !== initial) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.imageState.original?.width == 2200 && store.imageState.original?.height == 1400)
        #expect(store.displayLimit == 2200)
        // Sampling stays at source precision; the confirmed positive renders at the demanded tier.
        store.selectBase(); try await waitUntilIdle(store)
        store.confirmBase(); try await waitUntilIdle(store)
        #expect(store.showsPositive && store.imageState.positive?.width == 2200)
        // Camera frames arrive at capture resolution; zoom demands never re-render them.
        let camera = StubNegativeCamera(), cameraStore = NegativeStore(camera: camera)
        let frame = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 96))
        let cameraAsset = NegativeAsset(image: frame, preview: try NegativePixels.preview(frame, context: context))
        cameraStore.startCamera()
        try await waitFor { camera.hasStarted }
        camera.deliver(cameraAsset)
        try await waitFor { cameraStore.imageState.original === cameraAsset.preview }
        cameraStore.displayNeeds(4000)
        try await Task.sleep(for: .milliseconds(500))
        #expect(cameraStore.imageState.original === cameraAsset.preview && cameraStore.displayLimit == 1800)
        cameraStore.suspend()
    }

    @Test func comparisonSwitchSharpensOriginalAfterPositiveZoom() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = NegativePixels.context()
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 2200, height: 1400))
        try context.writeTIFFRepresentation(of: image, to: file, format: .RGBA16, colorSpace: NegativePixels.display)
        let store = NegativeStore()
        store.loadFile(file); try await waitUntilIdle(store)
        store.selectBase(); try await waitUntilIdle(store)
        store.confirmBase(); try await waitUntilIdle(store)
        store.displayNeeds(2200)
        try await waitFor { store.imageState.positive?.width == 2200 }
        #expect(store.imageState.original?.width == 1800)
        // Switching comparison must satisfy the retained zoom without another pinch gesture.
        store.showsPositive = false
        try await waitFor { store.imageState.original?.width == 2200 }
        #expect(store.displayLimit == 2200)
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
        for phase in [NegativeStore.Phase.loading, .rendering, .exporting, .savingPhotos] {
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
            resolutions: [.hd, .fullHD], supportsFocus: true, minimumFocusDistance: 100))
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
/// Controls permission and transaction completion without touching a user's photo library.
@MainActor private final class StubNegativePhotoLibrary: NegativePhotoSaving {
    var allowed = true, fails = false, holdAuthorization = false, holdSave = false
    var requests = 0
    var saved: [URL] = []
    var dimensions: CGSize?
    var authorization: CheckedContinuation<Bool, Never>?
    var completion: CheckedContinuation<Void, Never>?
    func requestAccess() async -> Bool {
        requests += 1
        if holdAuthorization { return await withCheckedContinuation { authorization = $0 } }
        return allowed
    }
    func save(_ file: URL) async throws {
        saved.append(file)
        let data = try Data(contentsOf: file)
        if let image = UIImage(data: data)?.cgImage { dimensions = CGSize(width: image.width, height: image.height) }
        if holdSave { await withCheckedContinuation { completion = $0 } }
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
    }
}
#endif

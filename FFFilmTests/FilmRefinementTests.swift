#if os(macOS)
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FFFilm

/// Fixtures describe an aperture in source coordinates, independent of detector implementation.
nonisolated enum FilmScanFixture {
    static func write(to url: URL, width: Int = 1200, height: Int = 240,
                      frames: Int = 6, gap: Int = 12, slope: Double = 0,
                      shading: Double = 0, sceneStripe: Range<Int>? = nil, scannerBorder: Bool = false, darkEdgeFrame: Int? = nil, base: SIMD3<Double> = SIMD3(0.65, 0.3, 0.12)) throws {
        let horizontal = width >= height
        let length = horizontal ? width : height, cross = horizontal ? height : width
        var pixels = [UInt16](repeating: 65535, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let along = horizontal ? x : y, across = horizontal ? y : x
                let shifted = Double(along) - (Double(across) - Double(cross) / 2) * slope
                let within = shifted.truncatingRemainder(dividingBy: Double(length) / Double(frames))
                let isImage = shifted >= 0 && shifted < Double(length)
                    && within >= Double(gap) / 2 && within < Double(length) / Double(frames) - Double(gap) / 2
                    && across >= cross * 13 / 100 && across < cross * 87 / 100
                let local = base * (1 - shading * Double(along) / Double(length))
                let scene = sceneStripe?.contains(along) == true ? SIMD3<Double>.zero
                    : local * 0.45 + SIMD3<Double>(repeating: Double((x * 3 + y * 7) % 13) / 2000)
                let frameIndex = Int(max(0, shifted) / (Double(length) / Double(frames)))
                let darkEdge = isImage && frameIndex == darkEdgeFrame && across < cross * 15 / 100
                let outside = scannerBorder && (across < cross * 13 / 100 || across >= cross * 87 / 100
                    || along < gap / 2 || along >= length - gap / 2)
                let value = outside || darkEdge ? SIMD3<Double>.zero : (isImage ? scene : local)
                let offset = (y * width + x) * 4
                for channel in 0..<3 { pixels[offset + channel] = UInt16((value[channel] * 65535).rounded()) }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder16Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}

@Suite(.serialized)
struct FilmRefinementTests {
    @Test func temporaryFilesUseRequestedRootWhenConfigured() throws {
        if let root = ProcessInfo.processInfo.environment["FFFILM_TEST_ARTIFACT_ROOT"] {
            let directory = try FilmTestFiles.directory()
            #expect(directory.standardizedFileURL.path.hasPrefix(root))
            let file = directory.appending(path: "location-probe-\(UUID()).bin")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data([1, 2, 3]).write(to: file)
            #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        }
    }

    @Test func robustBaseRejectsClippingAndTextureAndInterpolatesShading() throws {
        let base = SIMD3<Double>(0.6, 0.3, 0.15)
        var colors = (0..<100).map { base + SIMD3(repeating: Double($0 % 5 - 2) * 0.0002) }
        colors[5] = .zero
        let first = try #require(FilmBaseSample.estimate(colors, position: 0.1))
        let second = FilmBaseSample(position: 0.9, color: base * 0.8, noise: first.noise)
        let middle = FilmBaseModel(samples: [first, second]).sample(at: 0.5, fallback: .zero)
        #expect(abs(middle.color.x - 0.54) < 0.001)
        #expect(FilmBaseSample.estimate(Array(repeating: SIMD3(repeating: 1), count: 30), position: 0) == nil)
        let textured = (0..<100).map { $0 % 2 == 0 ? base : base * 0.5 }
        #expect(FilmBaseSample.estimate(textured, position: 0) == nil)
    }

    @Test func lineFitPreservesSlantedCornersAndRejectsAnUnsupportedEdge() throws {
        let base = FilmBaseSample(position: 0, color: SIMD3(0.6, 0.3, 0.15), noise: SIMD3(repeating: 0.0002))
        for edge in [FilmCropEdge.left, .right] {
            let colors = (0..<80).flatMap { y in
                (0..<100).map { x in
                    let inside = edge == .left ? Double(x) >= 20 + Double(y) * 0.1 : Double(x) < 60 - Double(y) * 0.1
                    return inside ? base.color * 0.5 : base.color
                }
            }
            let region = FilmPixelRegion(rect: FilmRect(), width: 100, height: 80, colors: colors)
            let result = try #require(FilmEdgeRefinement.boundary(in: region, edge: edge, base: base))
            if edge == .left { #expect(result.position <= 0.2 && result.position > 0.17) }
            else { #expect(result.position >= 0.6 && result.position < 0.63) }
        }
        let uniform = FilmPixelRegion(rect: FilmRect(), width: 100, height: 80, colors: Array(repeating: base.color, count: 8000))
        #expect(FilmEdgeRefinement.boundary(in: uniform, edge: .left, base: base) == nil)
    }

    @Test func scannerStepIgnoresHaloAndConfirmsSharpTransitionsAtSmallWindows() throws {
        let base = FilmBaseSample(position: 0, color: .zero, noise: SIMD3(repeating: 0.0001))
        for width in [80, 120] {
            let edge = width / 2
            let colors = (0..<40).flatMap { _ in
                (0..<width).map { x -> SIMD3<Double> in
                    if x >= edge { return SIMD3(0.3, 0.15, 0.08) }
                    return SIMD3(repeating: x < edge / 2 ? 0 : 0.003)
                }
            }
            let region = FilmPixelRegion(rect: FilmRect(), width: width, height: 40, colors: colors)
            let result = try #require(FilmEdgeRefinement.boundary(in: region, edge: .left, base: base, scannerBackground: true))
            #expect(result.position * Double(width) >= Double(edge - 2))
            #expect(result.position * Double(width) <= Double(edge))
        }
    }

    @Test func sourcePrecisionSamplingAndLongStripRefinementAreCached() async throws {
        for horizontal in [true, false] {
            let url = try FilmTestFiles.directory().appending(path: "FilmRefine-\(UUID()).tiff")
            defer { try? FileManager.default.removeItem(at: url) }
            try FilmScanFixture.write(to: url, width: horizontal ? 6000 : 240, height: horizontal ? 240 : 6000,
                                      frames: 6, gap: 12, shading: 0.02)
            let renderer = FilmRenderer()
            _ = try await renderer.load(url, inputSpace: "Linear sRGB")
            let point = horizontal ? CGPoint(x: 0.25, y: 0.04) : CGPoint(x: 0.04, y: 0.25)
            let sample = try await renderer.sampleFilmBase(at: point)
            #expect(abs(sample.color.x - 0.65 * 0.995) < 0.0001)
            let result = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
            #expect(result.candidates.count == 6)
            for (index, candidate) in result.candidates.enumerated() {
                let lower = (horizontal ? candidate.crop.x : candidate.crop.y) * 6000
                let upper = (horizontal ? candidate.crop.x + candidate.crop.width : candidate.crop.y + candidate.crop.height) * 6000
                #expect(lower <= Double(index * 1000 + 6) + 0.01)
                #expect(upper >= Double((index + 1) * 1000 - 6) - 0.01)
                #expect(lower >= Double(index * 1000) - 4)
                #expect(upper <= Double((index + 1) * 1000) + 4)
            }
            let count = await renderer.performance.measurements.count
            let cached = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
            #expect(cached == result)
            #expect(await renderer.performance.measurements.count == count)
            await renderer.close()
        }
    }

    @Test func overlappingSegmentsRecoverTwoPixelGapsAndSlantedFramesKeepCorners() async throws {
        for (gap, slope) in [(2, 0.0), (12, 0.025)] {
            let url = try FilmTestFiles.directory().appending(path: "FilmThin-\(UUID()).tiff")
            defer { try? FileManager.default.removeItem(at: url) }
            try FilmScanFixture.write(to: url, width: 6000, height: 240, frames: 6, gap: gap, slope: slope)
            let renderer = FilmRenderer()
            _ = try await renderer.load(url, inputSpace: "Linear sRGB")
            let result = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
            try #require(result.candidates.count == 6)
            for (index, candidate) in result.candidates.enumerated() {
                let firstImagePixel = ceil(Double(index * 1000 + gap / 2) + (31 - 120) * slope)
                let lastImageBoundary = ceil(Double((index + 1) * 1000 - gap / 2) + (207 - 120) * slope)
                #expect(candidate.crop.x * 6000 <= firstImagePixel + 0.01)
                #expect((candidate.crop.x + candidate.crop.width) * 6000 >= lastImageBoundary - 0.01)
            }
            await renderer.close()
        }
    }

    @Test func wideScansDoNotDiscardAlternatingShortFrames() async throws {
        let url = try FilmTestFiles.directory().appending(path: "FilmWide-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try FilmScanFixture.write(to: url, width: 800, height: 300, frames: 6, gap: 6)
        let renderer = FilmRenderer()
        _ = try await renderer.load(url, inputSpace: "Linear sRGB")
        let result = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
        #expect(result.candidates.count == 6)
        await renderer.close()
    }

    @Test func scannerSurroundIsRemovedWithoutCroppingAnEdgeTouchingDarkObject() async throws {
        for horizontal in [true, false] {
            let url = try FilmTestFiles.directory().appending(path: "FilmScannerBorder-\(UUID()).tiff")
            defer { try? FileManager.default.removeItem(at: url) }
            let width = horizontal ? 6000 : 1000, height = horizontal ? 1000 : 6000
            try FilmScanFixture.write(to: url, width: width, height: height, frames: 6, gap: 30,
                                      scannerBorder: true, darkEdgeFrame: 2)
            let renderer = FilmRenderer()
            _ = try await renderer.load(url, inputSpace: "Linear sRGB")
            let result = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
            try #require(result.candidates.count == 6)
            #expect(result.scannerBackground != nil)
            for candidate in result.candidates {
                let lo = horizontal ? candidate.crop.y : candidate.crop.x
                let hi = horizontal ? candidate.crop.y + candidate.crop.height : candidate.crop.x + candidate.crop.width
                #expect(lo >= 0.125 && lo <= 0.131)
                #expect(hi >= 0.869 && hi <= 0.875)
            }
            let first = try #require(result.candidates.first), last = try #require(result.candidates.last)
            let head = (horizontal ? first.crop.x : first.crop.y) * 6000
            let tail = (horizontal ? last.crop.x + last.crop.width : last.crop.y + last.crop.height) * 6000
            #expect(head >= 12 && head <= 15.1)
            #expect(tail >= 5984.9 && tail <= 5988)
            await renderer.close()
        }
    }

    @Test func interiorBlackContentDoesNotSeedAScannerSurround() async throws {
        let url = try FilmTestFiles.directory().appending(path: "FilmInteriorBlack-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try FilmScanFixture.write(to: url, sceneStripe: 70..<100, darkEdgeFrame: 2)
        let renderer = FilmRenderer()
        _ = try await renderer.load(url, inputSpace: "Linear sRGB")
        let result = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
        #expect(result.scannerBackground == nil)
        #expect(result.candidates.allSatisfy { $0.scannerEdges.isEmpty })
        await renderer.close()
    }

    @Test func aTileContainingOnlyASceneStripeCannotInventAnExtraFrame() async throws {
        let url = try FilmTestFiles.directory().appending(path: "FilmTileStripe-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try FilmScanFixture.write(to: url, width: 6000, height: 240, frames: 3, gap: 16, sceneStripe: 900..<908)
        let renderer = FilmRenderer()
        _ = try await renderer.load(url, inputSpace: "Linear sRGB")
        let result = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
        #expect(result.candidates.count == 3)
        #expect(result.gaps.allSatisfy { abs($0.center - 0.15) > 0.01 })
        await renderer.close()
    }

    @Test @MainActor func samplingCalibrationCancellationAndManualGeometryRemainIndependent() async throws {
        let url = try FilmTestFiles.directory().appending(path: "FilmControls-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try FilmScanFixture.write(to: url)
        let store = FilmStore()
        store.loadSource(url, restoring: nil)
        try await finish(store)
        store.detect(); try await finish(store)
        try #require(store.project.frames.count == 6)
        let initial = store.project
        store.detect(); store.cancelDetection(); try await finish(store)
        #expect(store.project == initial && !store.detecting)
        store.sampleFilmBase(at: CGPoint(x: -1, y: 0.1)); try await finish(store)
        #expect(store.error != nil && store.detectionOptions.base == nil && store.project == initial)
        store.error = nil
        store.sampleFilmBase(at: CGPoint(x: 0.5, y: 0.04)); try await finish(store)
        #expect(store.detectionOptions.base != nil)
        #expect(store.project.frames.count == 6)
        store.updateFrame { $0.crop.y += 0.01; $0.crop.height -= 0.01; $0.name = "Protected" }
        let manual = try #require(store.frame)
        store.calibrateCurrentFrame(); try await finish(store)
        #expect(store.frame == manual && store.project.frames.count == 6)
        store.clearFilmBase(); try await finish(store)
        #expect(store.detectionOptions.base == nil && store.frame == manual)
        // A direct programmatic edit during analysis invalidates the whole old result.
        store.detect()
        store.updateFrame { $0.name = "New revision" }
        let revised = store.project
        try await finish(store)
        #expect(store.project == revised)
        let restored = store.project
        store.loadSource(url, restoring: restored); try await finish(store)
        #expect(store.detectionOptions == FilmDetectionOptions() && store.project == restored)
        await store.renderer.close()
    }

    @Test @MainActor func exportRecoveryWaitsForDetectionAndDocumentSheets() async throws {
        let directory = try FilmTestFiles.directory().appending(path: "FilmRecoveryGate-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "scan.tiff")
        try FilmScanFixture.write(to: input)
        let store = FilmStore()
        store.loadSource(input, restoring: nil); try await finish(store)
        let controller = store.exportController
        store.openExportSettings(); controller.setDirectory(directory)
        let item = try #require(controller.preview?.items.first)
        controller.confirm(); controller.didDismiss(); controller.cancel()
        await controller.task?.value
        try #require(controller.canResume && controller.job?.pendingCount == 1)

        store.detect()
        #expect(store.detecting && !controller.canResume)
        controller.resume()
        #expect(!store.exporting && controller.job?.pendingCount == 1)
        try await finish(store)
        #expect(store.project.frames.count == 6 && controller.canResume)
        store.presentingSheet = true
        controller.resume()
        #expect(!controller.canResume && !store.exporting)
        store.presentingSheet = false

        // A real late collision creates a failed job without mocking the renderer.
        let destination = directory.appendingPathComponent(item.fileName)
        let sentinel = Data("existing file".utf8)
        try sentinel.write(to: destination)
        controller.resume(); await controller.task?.value
        try #require(controller.canRetry && controller.job?.failedCount == 1)
        store.sampleFilmBase(at: CGPoint(x: 0.5, y: 0.04))
        #expect(store.detecting && !controller.canRetry)
        controller.retryFailed()
        #expect(!store.exporting && controller.job?.failedCount == 1 && controller.job?.pendingCount == 0)
        try await finish(store)
        #expect(store.project.frames.count == 6 && store.detectionOptions.base != nil && controller.canRetry)
        store.presentingSheet = true
        controller.retryFailed()
        #expect(!controller.canRetry && !store.exporting && controller.job?.failedCount == 1)
        store.presentingSheet = false
        #expect(try Data(contentsOf: destination) == sentinel)
        try FileManager.default.removeItem(at: destination)
        controller.retryFailed(); await controller.task?.value
        #expect(controller.job?.completedCount == 1 && controller.job?.failedCount == 0)
        store.renderTask?.cancel(); await store.renderer.close()
    }

    @Test @MainActor func undoRedoRestoresRefinementProvenanceAndProtectsManualEdits() async throws {
        let input = try FilmTestFiles.directory().appending(path: "FilmRefinementHistory-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: input) }
        try FilmScanFixture.write(to: input)
        let store = FilmStore()
        store.loadSource(input, restoring: nil); try await finish(store)
        store.detect(); try await finish(store)
        let original = store.project
        let originalEdges = original.frames.map { store.unresolvedEdges(for: $0) }
        store.sampleFilmBase(at: CGPoint(x: 0.5, y: 0.04)); try await finish(store)
        let refined = store.project
        let refinedEdges = refined.frames.map { store.unresolvedEdges(for: $0) }
        try #require(refined != original)
        store.undo()
        #expect(store.project == original)
        #expect(store.project.frames.map { store.unresolvedEdges(for: $0) } == originalEdges)
        store.redo()
        #expect(store.project == refined)
        #expect(store.project.frames.map { store.unresolvedEdges(for: $0) } == refinedEdges)
        store.undo()
        // Sampling stays session-local; re-detect should apply that sample to the
        // restored automatic geometry, rather than treating undo as a manual crop.
        store.detect(); try await finish(store)
        #expect(store.project == refined && store.redoStack.isEmpty)
        store.updateFrame { $0.crop.width *= 0.9; $0.name = "Manual" }
        let manual = store.project
        store.undo(); store.redo()
        store.detect(); try await finish(store)
        #expect(store.project == manual)
        store.undo()
        store.clearFilmBase(); try await finish(store)
        #expect(store.project == original)
        store.renderTask?.cancel(); await store.renderer.close()
    }

    @Test @MainActor func addingAfterAutomaticTrimKeepsPitchButManualCropsOwnTheirBoundary() async throws {
        let url = try FilmTestFiles.directory().appending(path: "FilmPitch-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try FilmScanFixture.write(to: url)
        let store = FilmStore()
        store.loadSource(url, restoring: nil); try await finish(store)
        store.detect(); try await finish(store)
        store.change { $0.frames = Array($0.frames.prefix(3)) }
        let last = try #require(store.project.frames.last)
        #expect(last.crop.x + last.crop.width < 0.5)
        store.addFrame()
        let appended = try #require(store.frame)
        #expect(abs(appended.crop.x - 0.5) < 0.002)
        #expect(abs(appended.crop.width - 1.0 / 6) < 0.002)
        #expect(appended.crop.y == last.crop.y && appended.crop.height == last.crop.height)
        store.undo(); store.select(last.id)
        store.updateFrame { $0.crop.width *= 0.9 }
        let manual = try #require(store.frame)
        store.addFrame()
        #expect(store.frame?.crop.x == manual.crop.x + manual.crop.width)
        await store.renderer.close()
    }

    @Test func cancellationAfterPartialWorkAndSourceReplacementDoNotPublishStaleResults() async throws {
        let url = try FilmTestFiles.directory().appending(path: "FilmCancel-\(UUID()).tiff")
        let replacement = try FilmTestFiles.directory().appending(path: "FilmReplacement-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: replacement) }
        try FilmScanFixture.write(to: url)
        try FilmScanFixture.write(to: replacement, frames: 3)
        let renderer = FilmRenderer()
        _ = try await renderer.load(url, inputSpace: "Linear sRGB")
        let cancelled = Task {
            try await renderer.refineFrames(options: FilmDetectionOptions()) { update in
                if case .edges = update.phase, update.completed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await cancelled.value; Issue.record("Partial cancelled detection must not complete") }
        catch is CancellationError { }
        let afterCancellation = await renderer.performance.measurements.count
        let result = try await renderer.refineFrames(options: FilmDetectionOptions()) { _ in }
        #expect(result.candidates.count == 6)
        #expect(await renderer.performance.measurements.count > afterCancellation)
        let identity = await renderer.sourceIdentifier
        let replaced = Task {
            try await renderer.refineFrames(options: FilmDetectionOptions(calibration: result.candidates[0].crop)) { update in
                if case .edges = update.phase, update.completed == 1 {
                    do { _ = try await renderer.load(replacement, inputSpace: "Linear sRGB") }
                    catch { Issue.record(error) }
                }
            }
        }
        do { _ = try await replaced.value; Issue.record("Source replacement must invalidate in-flight geometry") }
        catch is CancellationError { }
        #expect(await renderer.sourceIdentifier != identity)
        #expect(try await renderer.detectFrames().count == 3)
        await renderer.close()
    }

    @Test @MainActor func exportRetriesSnapshotAvoidsCollisionsAndCleansCancelledWork() async throws {
        let directory = try FilmTestFiles.directory().appending(path: "FilmExportFlow-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "scan.tiff")
        try FilmScanFixture.write(to: input)
        let store = FilmStore()
        store.loadSource(input, restoring: nil); try await finish(store)
        store.detect(); try await finish(store)
        let original = store.project
        let destination = directory.appending(path: "outputs", directoryHint: .isDirectory)
        let controller = store.exportController
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        store.openExportSettings(); controller.settings.scope = .all; controller.setDirectory(destination)
        controller.confirm()
        // The destination disappears after confirmation; each failed item must
        // retain its original snapshot for the later retry.
        try FileManager.default.removeItem(at: destination)
        controller.didDismiss(); try await finish(store)
        #expect(controller.job?.failedCount == 6 && controller.job?.project == original)
        store.updateFrame { $0.crop.width *= 0.9 }
        let edited = store.project
        store.error = nil
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        controller.retryFailed(); try await finish(store)
        #expect(controller.job?.failedCount == 0 && store.project == edited)
        let firstFiles = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        #expect(firstFiles.count == 6)
        let firstData = try firstFiles.map { try Data(contentsOf: $0) }
        for (index, file) in firstFiles.enumerated() {
            let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let expected = FilmRenderer.pixelRect(original.frames[index].crop, extent: CGRect(x: 0, y: 0, width: 1200, height: 240))
            #expect(image.width == Int(expected.width) && image.height == Int(expected.height) && image.bitsPerComponent == 16)
        }
        store.openExportSettings(); controller.confirm(); controller.didDismiss(); try await finish(store)
        #expect(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).count == 12)
        #expect(try firstFiles.map { try Data(contentsOf: $0) } == firstData)
        store.openExportSettings(); controller.confirm(); controller.didDismiss(); controller.cancel(); try await finish(store)
        let remaining = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(remaining.count == 12 && remaining.allSatisfy { !$0.lastPathComponent.hasPrefix(".") })
        await store.renderer.close()
    }

    @MainActor private func finish(_ store: FilmStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (store.busy || store.exporting) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!store.busy && !store.exporting)
    }
}
#endif

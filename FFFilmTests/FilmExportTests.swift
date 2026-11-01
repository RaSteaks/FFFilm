#if os(macOS)
import Testing
import Foundation
import CoreImage
import ImageIO
@testable import FFFilm

@MainActor
struct FilmExportTests {
    @Test func namesUseFrameIdentityAndSnapshotEncoding() throws {
        var project = FilmProject()
        project.frames = [FilmFrame(name: "01"), FilmFrame(name: "03"), FilmFrame(name: "山谷")]
        let original = project
        let checked = Set([project.frames[0].id, project.frames[2].id])
        var settings = FilmExportSettings(scope: .checked, format: .jpeg, qualityPercent: 88, prefix: "007")
        let first = try plan(project, settings, checked: checked)
        #expect(first.items.map(\.fileName) == ["007_001.jpg", "007_山谷.jpg"])
        #expect(first.project.exportJPEG && first.project.jpegQuality == 0.88)
        #expect(project == original)
        project.frames.reverse()
        let reordered = try plan(project, settings, checked: checked)
        #expect(reordered.items.map(\.fileName) == ["007_山谷.jpg", "007_001.jpg"])
        settings.naming = .sequence; settings.startNumber = 24
        #expect(try plan(project, settings, checked: checked).items.map(\.fileName) == ["007_024.jpg", "007_025.jpg"])
        project.frames = [FilmFrame(name: "999999999999999999999999999")]
        settings.scope = .all; settings.naming = .frameName
        #expect(try plan(project, settings).items[0].fileName == "007_999999999999999999999999999.jpg")
    }

    @Test func emptyCheckedScopeNeverFallsBackToCurrentFrame() throws {
        var project = FilmProject(); project.frames = [FilmFrame(name: "01")]
        let settings = FilmExportSettings(scope: .checked, prefix: "scan")
        #expect(throws: FilmFailure.self) { try plan(project, settings) }
        var strip = settings; strip.scope = .strip
        project.frames = []
        let whole = try plan(project, strip)
        #expect(whole.items.count == 1 && whole.items[0].frame == nil)
        #expect(whole.items[0].fileName == "scan_strip.tiff")
    }

    @Test func collisionsReserveDiskAndBatchNamesWithoutOverwriting() throws {
        let directory = try FilmTestFiles.directory().appending(path: "FilmExportNames-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appending(path: "scan_001.tiff")
        let bytes = Data("existing".utf8)
        try bytes.write(to: existing)
        try bytes.write(to: directory.appending(path: "scan_001 (2).tiff"))
        var project = FilmProject()
        project.frames = [FilmFrame(name: "01"), FilmFrame(name: "01"), FilmFrame(name: "A"), FilmFrame(name: "a")]
        var settings = FilmExportSettings(scope: .all, prefix: "scan")
        let output = try plan(project, settings, directory: directory)
        #expect(output.items.map(\.fileName) == ["scan_001 (3).tiff", "scan_001 (4).tiff", "scan_A.tiff", "scan_a (2).tiff"])
        settings.collision = .skip
        let skipping = try plan(project, settings, directory: directory)
        #expect(skipping.items.map(\.skipped) == [true, true, false, true])
        #expect(skipping.outputCount == 1)
        #expect(try Data(contentsOf: existing) == bytes)
    }

    @Test func invalidNamesAndNumericOptionsHaveActionableValidation() throws {
        var project = FilmProject(); project.frames = [FilmFrame(name: "01")]
        for prefix in ["", "  ", "a/b", "a\\b", "a:b", "a\nb", String(repeating: "胶", count: 90)] {
            #expect(throws: FilmFailure.self) { try plan(project, FilmExportSettings(scope: .all, prefix: prefix)) }
        }
        var settings = FilmExportSettings(scope: .all, prefix: "scan")
        settings.startNumber = 0
        #expect(throws: FilmFailure.self) { try plan(project, settings) }
        settings.startNumber = 1; settings.qualityPercent = 101
        #expect(throws: FilmFailure.self) { try plan(project, settings) }
        settings.qualityPercent = 95; settings.digits = 200
        #expect(throws: FilmFailure.self) { try plan(project, settings) }
        settings.digits = 3; project.frames[0].name = "../bad"
        #expect(throws: FilmFailure.self) { try plan(project, settings) }
        settings.naming = .sequence
        #expect(try plan(project, settings).items[0].fileName == "scan_001.tiff")
    }

    @Test func sheetPreservesDocumentAndRefreshesEditedCrops() async throws {
        try await withStore { store, directory in
            let controller = store.exportController
            store.selection = [store.project.frames[0].id, store.project.frames[2].id]
            store.select(store.project.frames[1].id); store.zoom = 3
            store.rememberCanvasCenter(CGPoint(x: 0.3, y: 0.6), strip: true)
            let original = store.project, selected = store.selected, checked = store.selection
            store.openExportSettings()
            #expect(controller.isPresented && store.hasPresentedSheet && !store.canImportScan)
            #expect(controller.settings.scope == .checked && controller.preview?.items.count == 2)
            controller.settings.prefix = "Edited"; controller.settings.format = .jpeg
            controller.setDirectory(directory)
            store.updateFrame { $0.name = "blocked" }
            store.setFrameChecked(store.project.frames[1].id, checked: true)
            store.openProject(); store.undo()
            #expect(store.project == original && store.undoStack.isEmpty)
            #expect(store.selected == selected && store.selection == checked && store.zoom == 3)
            controller.dismiss()
            #expect(controller.isDismissing && store.hasPresentedSheet)
            controller.didDismiss()
            store.select(store.project.frames[0].id)
            store.updateFrame { $0.crop.width = 0.25 }
            store.openExportSettings()
            #expect(controller.settings.prefix == "Edited" && controller.directory == directory)
            #expect(controller.preview?.items[0].frame?.crop.width == 0.25)
            #expect(controller.preview?.items[0].pixelSize.width == 32)
            #expect(store.canvasCenter == CGPoint(x: 0.3, y: 0.6))
            controller.dismiss(); controller.didDismiss()
            store.selection = []
            store.openExportSettings()
            #expect(controller.settings.scope == .current && controller.preview?.items.count == 1)
            controller.dismiss(); controller.didDismiss()
        }
    }

    @Test func cancelAndResumeKeepGeometryNamesAndEncodingSnapshot() async throws {
        try await withStore { store, directory in
            let controller = store.exportController
            store.openExportSettings()
            controller.settings.scope = .all
            controller.setDirectory(directory)
            let expectedNames = try #require(controller.preview).items.map(\.fileName)
            controller.confirm()
            #expect(controller.isDismissing && !controller.isRunning)
            controller.didDismiss()
            #expect(store.exporting && store.canZoom && !store.canImportScan)
            let original = store.project
            store.zoomIn(); store.select(store.project.frames[1].id)
            #expect(store.zoom == 1.5 && store.selected == store.project.frames[1].id)
            store.updateFrame { $0.name = "blocked" }
            store.removeFrame()
            store.addFrame()
            #expect(!store.importDroppedScans([directory.appending(path: "scan.tiff")]))
            store.loadSource(directory.appending(path: "must-not-load.tiff"), restoring: nil)
            #expect(store.project == original && !store.busy)
            controller.cancel()
            await controller.task?.value
            #expect(controller.job?.phase == .cancelled && controller.canResume)
            #expect(controller.job?.completedCount == 0)
            controller.settings.prefix = "new-name"; controller.settings.format = .jpeg
            store.updateFrame { $0.crop.width = 0.25 }
            controller.resume()
            await controller.task?.value
            let job = try #require(controller.job)
            #expect(job.completedCount == 3 && job.pendingCount == 0 && job.failedCount == 0)
            #expect(job.results.map(\.item.fileName) == expectedNames)
            for url in job.completedURLs {
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.width == 64 && image.height == 32 && image.bitsPerComponent == 16)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }.isEmpty)
        }
    }

    @Test func lateCollisionFailsSafelyAndRetryOnlyWritesFailedFile() async throws {
        try await withStore { store, directory in
            let controller = store.exportController
            store.openExportSettings(); controller.settings.scope = .all
            controller.setDirectory(directory)
            let items = try #require(controller.preview).items
            controller.confirm()
            // Another file appears after confirmation, before the queued renderer runs.
            let blocked = directory.appendingPathComponent(items[1].fileName)
            let sentinel = Data("do not overwrite".utf8)
            try sentinel.write(to: blocked)
            controller.didDismiss()
            await controller.task?.value
            #expect(controller.job?.completedCount == 2 && controller.job?.failedCount == 1)
            #expect(try Data(contentsOf: blocked) == sentinel)
            store.openExportSettings()
            #expect(!controller.canRetry)
            controller.retryFailed()
            #expect(controller.job?.failedCount == 1)
            controller.dismiss(); controller.didDismiss()
            let firstURL = directory.appendingPathComponent(items[0].fileName)
            let originalBytes = try Data(contentsOf: firstURL)
            let originalDate = try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try FileManager.default.removeItem(at: blocked)
            controller.settings.prefix = "different"
            store.updateFrame { $0.name = "different"; $0.rotation = 90 }
            controller.retryFailed()
            await controller.task?.value
            #expect(controller.job?.completedCount == 3 && controller.job?.failedCount == 0)
            #expect(controller.job?.results.map(\.item.fileName) == items.map(\.fileName))
            #expect(try Data(contentsOf: firstURL) == originalBytes)
            #expect(try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
            let source = try #require(CGImageSourceCreateWithURL(blocked as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 64 && image.height == 32)
        }
    }

    @Test func rendererRejectsExportAgainstReplacementSource() async throws {
        try await withStore { store, directory in
            let controller = store.exportController
            store.openExportSettings(); controller.setDirectory(directory)
            controller.confirm()
            // Exercise the renderer boundary even if a caller bypasses the document gate.
            await store.renderer.close()
            controller.didDismiss()
            await controller.task?.value
            #expect(controller.job?.completedCount == 0 && controller.job?.failedCount == 1)
            store.loadSource(directory.appending(path: "missing.tiff"), restoring: nil)
            #expect(controller.job == nil)
            for _ in 0..<500 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!store.busy && store.error != nil)
        }
    }

    @Test func cancellationAfterPublishingKeepsCompletedFiles() async throws {
        try await withStore { store, directory in
            store.project.frames = (1...48).map {
                FilmFrame(name: String($0), crop: FilmRect(x: 0, y: 0, width: 0.5, height: 0.5))
            }
            store.selected = store.project.frames[0].id
            let controller = store.exportController
            store.openExportSettings(); controller.settings.scope = .all; controller.setDirectory(directory)
            controller.confirm(); controller.didDismiss()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while controller.isRunning, controller.job?.completedCount == 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            controller.cancel()
            await controller.task?.value
            let partial = try #require(controller.job)
            #expect(partial.completedCount > 0 && partial.completedCount < 48)
            #expect(partial.phase == .cancelled && partial.failedCount == 0)
            let saved = try partial.completedURLs.map { try Data(contentsOf: $0) }
            controller.resume()
            await controller.task?.value
            #expect(controller.job?.completedCount == 48 && controller.job?.pendingCount == 0)
            #expect(try partial.completedURLs.map { try Data(contentsOf: $0) } == saved)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }.isEmpty)
        }
    }

    private func plan(_ project: FilmProject, _ settings: FilmExportSettings,
                      checked: Set<UUID> = [], directory: URL? = nil) throws -> FilmExportPlan {
        try FilmExportPlan.make(project: project, selected: project.frames.first?.id, checked: checked,
                                sourceSize: CGSize(width: 128, height: 64), settings: settings, directory: directory)
    }

    /// Real ImageIO/Core Image fixtures exercise the same renderer and file publishing
    /// used by the app. Every invocation owns a separate disposable source/destination.
    private func withStore(_ body: (FilmStore, URL) async throws -> Void) async throws {
        let directory = try FilmTestFiles.directory().appending(path: "FilmExport-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "scan.tiff")
        let image = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        try CIContext().writeTIFFRepresentation(of: image, to: input, format: .RGBA16,
                                              colorSpace: FilmRenderer.colorSpace("sRGB"), options: [:])
        let store = FilmStore()
        store.loadSource(input, restoring: nil)
        for _ in 0..<500 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!store.busy && store.info != nil && store.error == nil)
        store.project.frames = (1...3).map { FilmFrame(name: String(format: "%02d", $0), crop: FilmRect(x: 0, y: 0, width: 0.5, height: 0.5)) }
        store.selected = store.project.frames[0].id
        do { try await body(store, directory) }
        catch {
            store.renderTask?.cancel()
            await store.renderer.close()
            throw error
        }
        store.renderTask?.cancel()
        await store.renderer.close()
    }
}
#endif

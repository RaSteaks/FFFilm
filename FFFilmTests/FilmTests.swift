#if os(macOS)
import Testing
import Foundation
import CoreImage
import ImageIO
@testable import FFFilm

struct FilmTests {
    @Test @MainActor func sourceLocationUsesHomeRelativePath() {
        let store = FilmStore()
        store.project.sourcePath = "/Users/photographer/Scans/Roll 01/007.fff"
        #expect(store.sourceFileName == "007.fff")
        #expect(FilmStore.relativeSourcePath(store.project.sourcePath, from: "/Users/photographer") == "Scans/Roll 01/007.fff")
        #expect(FilmStore.relativeSourcePath("/Volumes/Archive/007.fff", from: "/Users/photographer") == "../../Volumes/Archive/007.fff")
    }

    @Test func cropCoordinates() async {
        let rect = FilmRenderer.pixelRect(FilmRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3), extent: CGRect(x: 0, y: 0, width: 1000, height: 2000))
        #expect(rect == CGRect(x: 100, y: 1000, width: 400, height: 600))
    }

    /// Each side moves independently, stays valid, and keeps its opposite side anchored.
    @Test func cropEdgesResizeWithinSource() {
        let crop = FilmRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let left = crop.resizing(.left, by: 0.1)
        #expect(abs(left.x - 0.3) < 0.000001 && abs(left.width - 0.4) < 0.000001)
        let right = crop.resizing(.right, by: 0.1)
        #expect(abs(right.width - 0.6) < 0.000001 && right.x == crop.x)
        let top = crop.resizing(.top, by: -0.1)
        #expect(abs(top.y - 0.2) < 0.000001 && abs(top.height - 0.5) < 0.000001)
        let bottom = crop.resizing(.bottom, by: -0.1)
        #expect(abs(bottom.height - 0.3) < 0.000001 && bottom.y == crop.y)
        #expect(left.valid && right.valid && top.valid && bottom.valid)
        for edge in [FilmCropEdge.left, .right, .top, .bottom] {
            #expect(crop.resizing(edge, by: -10).valid)
            #expect(crop.resizing(edge, by: 10).valid)
        }
        #expect(abs(crop.resizing(.left, by: 10).width - 0.002) < 0.000001)
        #expect(abs(crop.resizing(.right, by: -10).width - 0.002) < 0.000001)
        let narrow = FilmRect(x: 0.9985, y: 0, width: 0.0015, height: 1)
        #expect(narrow.resizing(.right, by: -10).valid)
        let full = FilmRect()
        #expect(abs(full.resizing(.left, by: 0.1).width - 0.9) < 0.000001)
        #expect(abs(full.resizing(.right, by: -0.1).width - 0.9) < 0.000001)
    }

    @Test @MainActor func cropBorderHitTesting() {
        let crop = FilmRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let size = CGSize(width: 1000, height: 1000)
        #expect(FilmCanvas.edge(at: CGPoint(x: 197, y: 500), of: crop, in: size) == .left)
        #expect(FilmCanvas.edge(at: CGPoint(x: 703, y: 500), of: crop, in: size) == .right)
        #expect(FilmCanvas.edge(at: CGPoint(x: 400, y: 297), of: crop, in: size) == .top)
        #expect(FilmCanvas.edge(at: CGPoint(x: 400, y: 703), of: crop, in: size) == .bottom)
        #expect(FilmCanvas.edge(at: CGPoint(x: 400, y: 500), of: crop, in: size) == nil)
        #expect(FilmCanvas.edge(at: CGPoint(x: 215, y: 500), of: crop, in: size) == nil)
        // Full-size crops need an inner hit band because the outer half is outside the canvas.
        let full = FilmRect()
        #expect(FilmCanvas.edge(at: CGPoint(x: 16, y: 500), of: full, in: size) == .left)
        #expect(FilmCanvas.edge(at: CGPoint(x: 984, y: 500), of: full, in: size) == .right)
        #expect(FilmCanvas.edge(at: CGPoint(x: 500, y: 16), of: full, in: size) == .top)
        #expect(FilmCanvas.edge(at: CGPoint(x: 500, y: 984), of: full, in: size) == .bottom)
        #expect(FilmCanvas.edge(at: CGPoint(x: 30, y: 500), of: full, in: size) == nil)
    }

    @Test func gapDetectionAndUniformFallback() async {
        var signal = [Double](repeating: 100, count: 600)
        for index in 196..<204 { signal[index] = 250 }
        for index in 396..<404 { signal[index] = 250 }
        let frames = FilmRenderer.split(signal: signal, horizontal: true)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.valid })
        let uniform = FilmRenderer.split(signal: Array(repeating: 100, count: 600), horizontal: false)
        #expect(uniform.isEmpty)
    }

    @Test func previewPreservesWideGamutBeforeDisplayConversion() async throws {
        let input = FileManager.default.temporaryDirectory.appending(path: "FilmP3-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: input) }
        let space = FilmRenderer.colorSpace("Display P3")
        let color = try #require(CIColor(red: 0, green: 1, blue: 0, alpha: 1, colorSpace: space))
        let source = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        try context.writeTIFFRepresentation(of: source, to: input, format: .RGBA16, colorSpace: space, options: [:])
        let renderer = FilmRenderer()
        #expect(try await renderer.probe(input).hasProfile)
        _ = try await renderer.load(input, inputSpace: "sRGB")
        let preview = try await renderer.render(project: FilmProject(), frame: nil)
        // The initial strip uses the already materialized high-precision preview.
        #expect(preview === (try await renderer.render(project: FilmProject(), frame: nil)))
        var pixel = [Float](repeating: 0, count: 4)
        context.render(CIImage(cgImage: preview), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        #expect(abs(pixel[0]) < 0.01 && abs(pixel[1] - 1) < 0.01 && abs(pixel[2]) < 0.01)
        await renderer.close()
    }

    @Test func untaggedScanAcceptsPersistedCustomICC() async throws {
        let input = FileManager.default.temporaryDirectory.appending(path: "FilmUntagged-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: input) }
        var data = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        func short(_ v: UInt16) { data.append(UInt8(v & 255)); data.append(UInt8(v >> 8)) }
        func long(_ v: UInt32) { short(UInt16(v & 65535)); short(UInt16(v >> 16)) }
        short(10)
        for (tag, type, count, value): (UInt16, UInt16, UInt32, UInt32) in [(256,3,1,1),(257,3,1,1),(258,3,3,134),(259,3,1,1),(262,3,1,2),(273,4,1,140),(277,3,1,3),(278,4,1,1),(279,4,1,6),(284,3,1,1)] {
            short(tag); short(type); long(count); long(value)
        }
        long(0); short(16); short(16); short(16); short(13107); short(26214); short(45875)
        try data.write(to: input)
        let renderer = FilmRenderer()
        let space = FilmRenderer.colorSpace("Adobe RGB")
        let profile = try #require(space.copyICCData()) as Data
        var project = FilmProject(); project.inputSpace = "Custom ICC"; project.inputProfile = profile
        let restored = try JSONDecoder().decode(FilmProject.self, from: JSONEncoder().encode(project))
        #expect(restored == project && restored.valid)
        #expect(try await !renderer.probe(input).hasProfile)
        let info = try await renderer.load(input, inputSpace: restored.inputSpace, inputProfile: restored.inputProfile)
        #expect(!info.hasProfile)
        let preview = try await renderer.render(project: restored, frame: nil)
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: preview), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        for (actual, expected) in zip(pixel.prefix(3), [Float(0.2), 0.4, 0.7]) { #expect(abs(actual - expected) < 0.005) }
        do {
            _ = try await renderer.load(input, inputSpace: "Custom ICC", inputProfile: Data([1, 2, 3]))
            Issue.record("Invalid ICC must not fall back silently")
        } catch { #expect(error is FilmFailure) }
        await renderer.close()
        do {
            _ = try await renderer.render(project: restored, frame: nil)
            Issue.record("Closing the scan must discard its materialized preview")
        } catch { #expect(error is FilmFailure) }
    }

    @Test @MainActor func firstImportSharesPreviewAndRestoredRotationUsesCachedPixels() async throws {
        let input = FileManager.default.temporaryDirectory.appending(path: "FilmImportPreview-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: input) }
        let space = FilmRenderer.colorSpace("Display P3")
        let color = try #require(CIColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1, colorSpace: space))
        let source = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 4096))
        try CIContext().writeTIFFRepresentation(of: source, to: input, format: .RGBA16, colorSpace: space, options: [:])
        let store = FilmStore()
        store.loadSource(input, restoring: nil)
        for _ in 0..<500 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.busy && store.error == nil)
        #expect(store.info?.width == 512 && store.info?.height == 4096 && store.info?.depth == 16)
        #expect(store.image != nil && store.image === store.overview)
        let base = try #require(store.overview)
        #expect(base.height == 1800)

        var restored = store.project
        restored.frames[0].crop = FilmRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
        restored.frames[0].rotation = 90
        store.loadSource(input, restoring: restored)
        for _ in 0..<500 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.busy && store.error == nil)
        #expect(store.project == restored)
        #expect(store.overview != nil && store.image != nil && store.image !== store.overview)
        #expect(store.image?.height == 1800)
        await store.renderer.close()
        do {
            _ = try await store.renderer.render(project: restored, frame: nil)
            Issue.record("Close must release cached preview pixels")
        } catch { #expect(error is FilmFailure) }
    }

    @Test @MainActor func projectDiskSaveAndFailedWritePreserveDirtyState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FilmSaveTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilmStore()
        store.project.frames = [FilmFrame(name: "01")]
        let destination = directory.appending(path: "project.fffilm")
        #expect(store.writeProject(to: destination))
        #expect(!store.dirty)
        #expect(try JSONDecoder().decode(FilmProject.self, from: Data(contentsOf: destination)) == store.project)
        store.project.frames[0].rotation = 90
        #expect(!store.writeProject(to: directory.appending(path: "missing/project.fffilm")))
        #expect(store.dirty)
        #expect(store.projectURL == destination)
    }

    @Test @MainActor func failedImportCannotReportUnsavedProjectAsSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FilmFailedImport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilmStore()
        store.project.frames = [FilmFrame(name: "01")]
        let destination = directory.appending(path: "project.fffilm")
        #expect(store.writeProject(to: destination))
        let savedData = try Data(contentsOf: destination)
        store.change { $0.frames[0].rotation = 90 }
        let editedProject = store.project
        store.loadSource(directory.appending(path: "missing.tiff"), restoring: nil)
        for _ in 0..<500 where store.busy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.busy)
        #expect(store.error != nil)
        #expect(store.info == nil)
        var accepted: Bool?
        store.saveProject { accepted = $0 }
        #expect(accepted == false)
        #expect(store.dirty)
        #expect(store.project == editedProject)
        #expect(try Data(contentsOf: destination) == savedData)
    }

    @Test @MainActor func activeSheetRejectsCompetingDocumentActions() {
        let store = FilmStore()
        store.project.frames = [FilmFrame(name: "01")]
        store.presentingSheet = true
        var accepted: Bool?
        store.requestDiscard { accepted = $0 }
        #expect(accepted == false)
        store.saveProject { accepted = $0 }
        #expect(accepted == false)
        store.openScan(); store.openProject(); store.export(scope: 3)
        #expect(store.presentingSheet && !store.busy && !store.exporting)
        let project = store.project
        store.undo(); store.redo()
        #expect(store.project == project)
    }

    @Test func rotatedJPEGFlattensTransparentCornersAndThumbnailRotates() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FilmJPEG-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "source.tiff")
        let space = FilmRenderer.colorSpace("sRGB")
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        try CIContext().writeTIFFRepresentation(of: source, to: input, format: .RGBA16, colorSpace: space, options: [:])
        let renderer = FilmRenderer()
        _ = try await renderer.load(input, inputSpace: "sRGB")
        let quarterTurn = FilmFrame(name: "01", rotation: 90)
        let thumbnail = try await renderer.thumbnail(frame: quarterTurn)
        #expect(thumbnail.width == 30 && thumbnail.height == 60)
        var project = FilmProject(); project.exportJPEG = true
        let output = directory.appending(path: "rotated.jpg")
        try await renderer.export(project: project, frame: FilmFrame(name: "01", rotation: 45), to: output)
        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let jpeg = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let context = CIContext()
        var corner = [UInt8](repeating: 0, count: 4)
        context.render(CIImage(cgImage: jpeg), toBitmap: &corner, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: space)
        #expect(corner[0] > 235 && corner[1] > 235 && corner[2] > 235)
        await renderer.close()
    }

    /// Old grading data is ignored on decode and never reaches preview/export.
    @Test func legacyProjectLoadsGeometryAndExportsUnadjustedPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FilmSlicing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        let color = try #require(CIColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1, colorSpace: space))
        let source = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        let input = directory.appending(path: "source.tiff")
        let context = CIContext()
        try context.writeTIFFRepresentation(of: source, to: input, format: .RGBA16, colorSpace: space, options: [:])
        var clean = FilmProject()
        clean.sourcePath = input.path
        clean.frames = [FilmFrame(name: "01", crop: FilmRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), rotation: 90)]
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clean)) as? [String: Any])
        old["kind"] = "colorNegative"; old["editingSpace"] = "adobeRGB"
        old["mask"] = ["enabled": true, "red": 0.2, "green": 0.5, "blue": 0.8]
        var frames = try #require(old["frames"] as? [[String: Any]])
        frames[0]["adjustments"] = ["exposure": 5, "contrast": 2, "saturation": 0, "curves": ["channels": []]]
        frames[0]["maskOverride"] = old["mask"]; old["frames"] = frames
        let project = try JSONDecoder().decode(FilmProject.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(project == clean && project.valid)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        #expect(saved["kind"] == nil && saved["mask"] == nil && saved["editingSpace"] == nil)
        let renderer = FilmRenderer()
        let info = try await renderer.load(input, inputSpace: "sRGB")
        #expect(info.width == 128 && info.height == 64 && info.depth == 16 && info.hasProfile)
        let preview = try await renderer.render(project: project, frame: project.frames[0])
        #expect(preview.width == 32 && preview.height == 64)
        var pixel = [Float](repeating: 0, count: 4)
        context.render(CIImage(cgImage: preview), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 16, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        for (actual, expected) in zip(pixel.prefix(3), [Float(0.8), 0.5, 0.2]) { #expect(abs(actual - expected) < 0.01) }
        for jpeg in [false, true] {
            var export = project; export.exportJPEG = jpeg
            let output = directory.appending(path: jpeg ? "frame.jpg" : "frame.tiff")
            try await renderer.export(project: export, frame: export.frames[0], to: output)
            let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            #expect(image.width == 32 && image.height == 64)
            #expect(image.bitsPerComponent == (jpeg ? 8 : 16))
            #expect(image.colorSpace != nil)
            context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 16, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: space)
            for (actual, expected) in zip(pixel.prefix(3), [Float(0.8), 0.5, 0.2]) { #expect(abs(actual - expected) < 0.02) }
        }
        let strip = try await renderer.render(project: project, frame: nil)
        #expect(strip.width == 128 && strip.height == 64)
        let previewFFF = directory.appending(path: "preview.fff")
        try context.writeTIFFRepresentation(of: source, to: previewFFF, format: .RGBA8, colorSpace: space, options: [:])
        do {
            _ = try await renderer.load(previewFFF, inputSpace: "sRGB")
            Issue.record("An 8-bit FFF thumbnail must not be accepted")
        } catch { #expect(error is FilmFailure) }
        await renderer.close()
    }

    @Test @MainActor func frameGeometrySupportsGroupedUndoAndBatchRemoval() {
        let store = FilmStore()
        store.addFrame(); store.addFrame()
        let original = store.project
        store.beginEdit()
        store.updateFrame { $0.crop.x = 0.15 }
        store.updateFrame { $0.rotation = 90 }
        store.endEdit()
        let edited = store.project
        #expect(edited != original)
        store.undo(); #expect(store.project == original)
        store.redo(); #expect(store.project == edited)
        store.moveFrame(-1)
        #expect(store.project.frames.first?.id == store.selected)
        store.selection = Set(store.project.frames.map(\.id))
        store.removeFrame(); #expect(store.project.frames.isEmpty)
        store.undo(); #expect(store.project.frames.count == 2)
    }
}
#endif

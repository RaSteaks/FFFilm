#if os(macOS)
import Testing
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import FFFilm

@Suite(.serialized)
struct FilmFormatTests {
    /// Read actual TIFF metadata through ImageIO, including EXIF axis swaps.
    @Test func physicalScanDimensionsIdentifyAllFormats() async throws {
        for (width, height, format) in [(525, 2160, FilmFormat.film135), (930, 3360, .film120), (1500, 1875, .largeFormat)] {
            let url = try scan(width: width, height: height, dpiX: 381, dpiY: 381)
            defer { try? FileManager.default.removeItem(at: url) }
            let renderer = FilmRenderer()
            let info = try await renderer.load(url, inputSpace: "sRGB")
            #expect(info.layout.format == format)
            #expect(!info.layout.horizontal)
            #expect(info.layout.nextCrop(after: nil, width: info.width, height: info.height, override: nil)?.valid == true)
            await renderer.close()
        }
        let rotated = try scan(width: 360, height: 1680, dpiX: 381, dpiY: 762, orientation: 6)
        defer { try? FileManager.default.removeItem(at: rotated) }
        let renderer = FilmRenderer()
        let info = try await renderer.load(rotated, inputSpace: "sRGB")
        #expect(info.width == 1680 && info.height == 360)
        #expect(info.layout.horizontal && info.layout.format == .film135)
        #expect(abs((info.layout.frameLength ?? 0) - 36.0 / 56) < 0.000001)
        await renderer.close()
    }

    @Test func insufficientMetadataDoesNotGuessFromAspectRatio() {
        let examples: [[String: Any]] = [[:], [kCGImagePropertyDPIWidth as String: 72, kCGImagePropertyDPIHeight as String: 72],
                                       [kCGImagePropertyDPIWidth as String: Double.nan, kCGImagePropertyDPIHeight as String: 4000]]
        for properties in examples {
            let layout = FilmScanAnalysis.layout(width: 600, height: 400, properties: properties,
                pixels: [], previewWidth: 0, previewHeight: 0, frames: [])
            #expect(layout.format == nil)
        }
    }

    @Test func pairedPeriodicSprocketsIdentify135WithoutDPI() {
        for horizontal in [false, true] {
            let width = horizontal ? 1200 : 300, height = horizontal ? 300 : 1200
            let pixels = sprocketPixels(width: width, height: height, horizontal: horizontal)
            let layout = FilmScanAnalysis.layout(width: width, height: height, properties: [:],
                pixels: pixels, previewWidth: width, previewHeight: height, frames: [])
            #expect(layout.format == .film135 && layout.horizontal == horizontal)
            #expect(abs(layout.crossSize - 24.0 / 35) < 0.000001)
            // One row of repeating scene detail is insufficient; both film edges must match.
            let singleEdge = sprocketPixels(width: width, height: height, horizontal: horizontal, bothEdges: false)
            #expect(!FilmScanAnalysis.hasSprockets(singleEdge, width: width, height: height, horizontal: horizontal))
        }
    }

    @Test func reliableGapsSetFirst120FrameLength() {
        let frames = (0..<3).map { FilmRect(x: 0, y: Double($0) / 3, width: 1, height: 1.0 / 3) }
        let layout = FilmScanAnalysis.layout(width: 840, height: 3360,
            properties: [kCGImagePropertyDPIWidth as String: 381, kCGImagePropertyDPIHeight as String: 381],
            pixels: [], previewWidth: 0, previewHeight: 0, frames: frames)
        #expect(layout.format == .film120)
        #expect(layout.nextCrop(after: nil, width: 840, height: 3360, override: nil)?.height == 1.0 / 3)
        // A manually refined 6×7 boundary is carried into the next frame rather than reset to 6×6.
        let previous = FilmRect(x: 0.05, y: 0.1, width: 0.9, height: 0.29)
        let next = layout.nextCrop(after: previous, width: 840, height: 3360, override: nil)
        #expect(next?.height == previous.height && next?.y == previous.y + previous.height)
    }

    @Test @MainActor func add135FramesShareBoundariesAndRejectInsufficientSpace() async throws {
        let url = try scan(width: 525, height: 2160, dpiX: 381, dpiY: 381)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FilmStore()
        store.loadSource(url, restoring: nil)
        try await waitForImport(store)
        let initial = store.project
        store.selection = Set([try #require(store.selected)])
        store.addFrame()
        #expect(store.project.frames.count == 1 && store.frame?.name == "01")
        #expect(store.selection.isEmpty)
        let first = try #require(store.frame)
        #expect(first.crop.y == 0 && abs(first.crop.height - 0.25) < 0.000001)
        #expect(abs(first.crop.width - 24.0 / 35) < 0.000001)
        store.undo(); #expect(store.project == initial)
        store.redo(); #expect(store.project.frames == [first])
        for _ in 0..<3 {
            let previous = try #require(store.project.frames.last)
            store.selected = first.id // Selection does not change which frame precedes an append.
            store.addFrame()
            let next = try #require(store.frame)
            #expect(next.crop.y == previous.crop.y + previous.crop.height)
            #expect(next.crop.x == previous.crop.x && next.crop.width == previous.crop.width)
            #expect(abs(next.crop.height - 0.25) < 0.000001)
        }
        let full = store.project, selected = store.selected, undoCount = store.undoStack.count
        store.addFrame()
        #expect(store.project == full && store.selected == selected && store.undoStack.count == undoCount)
        #expect(!store.notice.isEmpty)
        await store.renderer.close()
    }

    @Test @MainActor func unmeasured120UsesSquareThenPreviousHeightAndPersistsOverride() async throws {
        let url = try scan(width: 930, height: 3360, dpiX: 381, dpiY: 381)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FilmStore()
        store.loadSource(url, restoring: nil)
        try await waitForImport(store)
        store.addFrame()
        #expect(abs((store.frame?.crop.height ?? 0) - 0.25) < 0.000001)
        store.updateFrame { $0.crop.height = 0.3 }
        store.addFrame()
        #expect(store.frame?.crop.y == 0.3 && store.frame?.crop.height == 0.3)
        let frames = store.project.frames
        store.change { $0.filmFormat = .film135 }
        #expect(store.project.frames == frames) // Correction affects future additions only.
        let restored = try JSONDecoder().decode(FilmProject.self, from: JSONEncoder().encode(store.project))
        #expect(restored == store.project && restored.filmFormat == .film135)
        store.addFrame()
        #expect(abs((store.frame?.crop.height ?? 0) - 0.375) < 0.000001)
        store.loadSource(url, restoring: restored)
        try await waitForImport(store)
        #expect(store.project == restored && !store.dirty)
        await store.renderer.close()
    }

    @Test func horizontalAppendAndOldProjectsRemainSupported() throws {
        let layout = FilmLayout(format: .film135, horizontal: true, frameLength: 0.2)
        let previous = FilmRect(x: 0.1, y: 0.2, width: 0.2, height: 0.6)
        let next = try #require(layout.nextCrop(after: previous, width: 1200, height: 300, override: nil))
        #expect(next.x == previous.x + previous.width && next.width == 0.2)
        #expect(next.y == previous.y && next.height == previous.height && next.valid)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(FilmProject())) as? [String: Any])
        old.removeValue(forKey: "filmFormat")
        let decoded = try JSONDecoder().decode(FilmProject.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.valid && decoded.filmFormat == nil)
    }

    @Test @MainActor func fullSheetDoesNotRepeatedlyReplaceItsFrame() async throws {
        let url = try scan(width: 1500, height: 1875, dpiX: 381, dpiY: 381)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FilmStore()
        store.loadSource(url, restoring: nil)
        try await waitForImport(store)
        #expect(store.info?.layout.format == .largeFormat)
        let project = store.project, selected = store.selected
        // The imported 4×5 sheet already occupies the entire scan; there is no next slot.
        store.addFrame(); store.addFrame()
        #expect(store.project == project && store.selected == selected && store.undoStack.isEmpty)
        #expect(!store.notice.isEmpty)
        await store.renderer.close()
    }

    @Test @MainActor func invalidDropsAndBusyActionsPreserveCurrentWork() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FilmDrop-\(UUID()).tiff")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilmStore()
        store.project.frames = [FilmFrame(name: "01", crop: FilmRect(x: 0, y: 0, width: 1, height: 0.2))]
        store.selected = store.project.frames[0].id
        let previous = store.project, selected = store.selected
        for urls in [[], [directory], [URL(string: "https://example.com/scan.tiff")!],
                     [directory.appending(path: "image.jpg")], [directory, directory]] {
            #expect(!store.importDroppedScans(urls))
            #expect(store.project == previous && store.selected == selected && !store.busy)
        }
        for gate in [\FilmStore.busy, \FilmStore.exporting, \FilmStore.presentingSheet] {
            store[keyPath: gate] = true
            #expect(!store.importDroppedScans([directory]))
            store.addFrame()
            #expect(store.project == previous && store.undoStack.isEmpty)
            store[keyPath: gate] = false
        }
        store.addFrame(FilmRect(x: -1))
        #expect(store.project == previous && store.selected == selected && store.undoStack.isEmpty)
    }

    @Test @MainActor func validDropImportsAndDirtyProjectWithoutWindowIsKept() async throws {
        let url = try scan(width: 525, height: 2160, dpiX: 381, dpiY: 381)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FilmStore()
        #expect(store.importDroppedScans([url]) && store.busy)
        try await waitForImport(store)
        #expect(store.project.sourcePath == url.path && store.info?.layout.format == .film135)
        #expect(store.image != nil && store.dirty)
        let previous = store.project, generation = store.sourceGeneration
        #expect(store.importDroppedScans([url]))
        #expect(!store.busy && store.project == previous && store.sourceGeneration == generation)
        await store.renderer.close()
    }

    @MainActor private func waitForImport(_ store: FilmStore) async throws {
        for _ in 0..<500 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!store.busy && store.error == nil && store.info != nil)
    }

    /// Tagged, neutral pixels exercise import without requiring native profile sheets.
    private func scan(width: Int, height: Int, dpiX: Double, dpiY: Double, orientation: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "FilmFormat-\(UUID()).tiff")
        let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(CIContext().createCGImage(image, from: image.extent, format: .RGBA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyDPIWidth: dpiX, kCGImagePropertyDPIHeight: dpiY,
                                                   kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    private func sprocketPixels(width: Int, height: Int, horizontal: Bool, bothEdges: Bool = true) -> [UInt8] {
        var pixels = [UInt8](repeating: 80, count: width * height * 4)
        let cross = horizontal ? height : width, length = horizontal ? width : height
        for i in 0..<length where i % 40 < 12 {
            for j in 0..<cross where (15..<39).contains(j) || (bothEdges && (261..<287).contains(j)) {
                let offset = horizontal ? (j * width + i) * 4 : (i * width + j) * 4
                pixels[offset] = 250; pixels[offset + 1] = 250; pixels[offset + 2] = 250
            }
        }
        return pixels
    }
}
#endif

#if os(macOS)
import Testing
import Foundation
import SwiftUI
import AppKit
import CoreImage
import ImageIO
@testable import FFFilm

struct FilmZoomTests {
    /// The report's asymmetric ×1.5 path must become reversible, including gesture-to-button transitions.
    @Test @MainActor func zoomStopsModesAndOperationGates() {
        let store = FilmStore()
        store.info = FilmRenderer.SourceInfo(width: 4096, height: 512, depth: 16, hasProfile: true,
            isFFF: false, profileName: "sRGB", layout: FilmLayout(horizontal: true))
        store.project.frames = [FilmFrame(name: "01"), FilmFrame(name: "02")]
        let project = store.project
        defer { store.renderTask?.cancel() }
        for level in FilmZoom.levels.dropFirst() {
            store.zoomIn()
            #expect(store.zoom == level)
        }
        store.zoomIn(); #expect(store.zoom == 8)
        for level in FilmZoom.levels.dropLast().reversed() {
            store.zoomOut()
            #expect(store.zoom == level)
        }
        store.zoomOut(); #expect(store.zoom == 1)
        store.zoom = 2.25; store.zoomIn(); #expect(store.zoom == 3)
        store.zoom = 2.25; store.zoomOut(); #expect(store.zoom == 2)
        store.zoom = 4
        store.rememberCanvasCenter(CGPoint(x: 0.3, y: 0.7), strip: true)
        store.showStrip = false
        #expect(store.zoom == 1)
        store.zoom = 3
        store.rememberCanvasCenter(CGPoint(x: 0.6, y: 0.2), strip: false)
        store.select(store.project.frames[1].id)
        #expect(store.zoom == 3 && store.canvasCenter == CGPoint(x: 0.6, y: 0.2))
        store.showStrip = true
        #expect(store.zoom == 4 && store.canvasCenter == CGPoint(x: 0.3, y: 0.7))
        store.busy = true; store.zoomIn(); store.zoomOut(); store.fitCanvas()
        #expect(store.zoom == 4)
        store.busy = false; store.presentingSheet = true; store.zoomIn()
        #expect(store.zoom == 4)
        store.presentingSheet = false; store.exporting = true; store.fitCanvas()
        #expect(store.zoom == 4)
        #expect(store.project == project && store.undoStack.isEmpty)
        #expect(FilmZoom.clamped(.nan) == 1 && FilmZoom.clamped(100) == 8)
    }

    /// Fit, Retina demand and memory limits are independent of the initial preview's pixel dimensions.
    @Test func displayGeometryAndBudget() {
        let source = CGSize(width: 6000, height: 4000)
        let fit = FilmZoom.fittedSize(source: source, viewport: CGSize(width: 900, height: 700), zoom: 1)
        #expect(fit == CGSize(width: 900, height: 600))
        let zoomed = FilmZoom.fittedSize(source: source, viewport: CGSize(width: 900, height: 700), zoom: 4)
        #expect(zoomed == CGSize(width: 3600, height: 2400))
        let limit = FilmRenderer.displayLimit(max(zoomed.width, zoomed.height) * 2, size: source)
        #expect(limit > 5016 && limit < 5017)
        let square = FilmRenderer.displayLimit(100_000, size: CGSize(width: 20_000, height: 20_000))
        #expect(square == 4096 && square * square == 16_777_216)
        #expect(FilmRenderer.displayLimit(100_000, size: CGSize(width: 50_000, height: 1000)) == 8192)
        #expect(FilmRenderer.displayLimit(4096, size: CGSize(width: 80, height: 60)) == 80)
        #expect(FilmRenderer.displayLimit(.nan, size: source) == 0)
        let rotated = FilmZoom.sourceSize(width: 4096, height: 512,
            frame: FilmFrame(name: "01", crop: FilmRect(width: 0.0625), rotation: 90))
        #expect(abs(rotated.width - 512) < 0.000001 && abs(rotated.height - 256) < 0.000001)
    }

    /// Exercise the actual NSClipView, not just the anchoring formula, including a tier swap and recreation.
    @Test @MainActor func nativeCanvasPreservesPointerCenterAndRememberedRegion() {
        let viewport = CGSize(width: 800, height: 600)
        let old = FilmCanvasLayout(imageSize: CGSize(width: 1600, height: 2400), viewport: viewport)
        let identity = FilmCanvasIdentity(sourceGeneration: 1, showStrip: true, frameID: nil)
        let view = FilmZoomScrollView()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var remembered = CGPoint(x: 0.5, y: 0.5)
        view.centerChanged = { remembered = $0 }
        view.update(content: AnyView(Color.clear), layout: old, zoom: 2, identity: identity, center: remembered)
        view.layoutSubtreeIfNeeded()
        view.contentView.scroll(to: CGPoint(x: 300, y: 700))
        let anchor = CGPoint(x: 170, y: 210)
        let point = old.normalizedPoint(at: CGPoint(x: view.contentView.bounds.minX + anchor.x,
                                                  y: view.contentView.bounds.minY + anchor.y))
        var reportedZoom = 0.0
        view.zoomChanged = { reportedZoom = $0 }
        view.changeZoom(to: 4, at: anchor)
        #expect(reportedZoom == 4)
        let enlarged = FilmCanvasLayout(imageSize: CGSize(width: 3200, height: 4800), viewport: viewport)
        view.update(content: AnyView(Color.clear), layout: enlarged, zoom: 4, identity: identity, center: remembered)
        let after = enlarged.normalizedPoint(at: CGPoint(x: view.contentView.bounds.minX + anchor.x,
                                                        y: view.contentView.bounds.minY + anchor.y))
        #expect(abs(after.x - point.x) < 0.000001 && abs(after.y - point.y) < 0.000001)
        let offset = view.contentView.bounds.origin
        view.update(content: AnyView(Color.black), layout: enlarged, zoom: 4, identity: identity, center: remembered)
        #expect(view.contentView.bounds.origin == offset)
        let savedCenter = remembered
        view.update(content: AnyView(EmptyView()), layout: FilmCanvasLayout(imageSize: .zero, viewport: .zero),
                    zoom: 4, identity: identity, center: remembered)
        #expect(remembered == savedCenter && view.contentView.bounds.origin == offset)
        let recreated = FilmZoomScrollView()
        recreated.update(content: AnyView(EmptyView()), layout: FilmCanvasLayout(imageSize: .zero, viewport: .zero),
                         zoom: 4, identity: identity, center: remembered)
        recreated.update(content: AnyView(Color.clear), layout: enlarged, zoom: 4, identity: identity, center: remembered)
        let restoredWindow = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: .borderless,
                                      backing: .buffered, defer: false)
        restoredWindow.isReleasedWhenClosed = false
        restoredWindow.contentView = recreated
        defer { restoredWindow.close() }
        recreated.layoutSubtreeIfNeeded()
        // Normalized storage introduces sub-picometer floating-point roundoff on restoration.
        #expect(abs(recreated.contentView.bounds.minX - offset.x) < 0.000001 &&
                abs(recreated.contentView.bounds.minY - offset.y) < 0.000001)

        // Buttons use the visible center; resizing must keep that same source location.
        let center = remembered
        let resized = FilmCanvasLayout(imageSize: CGSize(width: 3600, height: 5400), viewport: CGSize(width: 900, height: 700))
        view.update(content: AnyView(Color.clear), layout: resized, zoom: 4, identity: identity, center: remembered)
        #expect(abs(remembered.x - center.x) < 0.000001 && abs(remembered.y - center.y) < 0.000001)
        view.zoomEnabled = false; view.changeZoom(to: 6, at: anchor)
        #expect(reportedZoom == 4)
    }

    /// Dispatch local NSEvent values directly; no synthetic event is posted to the user's desktop.
    @Test @MainActor func wheelZoomRequiresCommandAndEnabledCanvas() throws {
        let viewport = CGSize(width: 800, height: 600)
        let view = FilmZoomScrollView()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.update(content: AnyView(Color.clear),
            layout: FilmCanvasLayout(imageSize: CGSize(width: 1600, height: 2400), viewport: viewport), zoom: 2,
            identity: FilmCanvasIdentity(sourceGeneration: 1, showStrip: true, frameID: nil),
            center: CGPoint(x: 0.5, y: 0.5))
        view.layoutSubtreeIfNeeded()
        var zoom = 2.0
        view.zoomChanged = { zoom = $0 }
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                         wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0))
        wheel.location = CGPoint(x: 400, y: 300)
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        wheel.flags = .maskCommand
        view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        #expect(zoom > 2 && zoom < 3)
        let magnified = zoom
        wheel.flags = []
        view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        // The unshown window cannot consume AppKit's wheel event for panning;
        // this isolated check verifies zoom gating. Actual scrolling is checked in the running app.
        #expect(zoom == magnified)
        view.zoomEnabled = false
        wheel.flags = .maskCommand
        view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        #expect(zoom == magnified)
    }

    /// Alternating source pixels cannot survive an 1800px resize: dimensions alone cannot prove real detail.
    @Test func sharperPreviewReadsSourcePixelsAndCropsBeforeDownsampling() async throws {
        let input = FileManager.default.temporaryDirectory.appending(path: "FilmZoomPixels-\(UUID()).tiff")
        let output = FileManager.default.temporaryDirectory.appending(path: "FilmZoomExport-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try Self.writeScan(to: input)
        let renderer = FilmRenderer()
        _ = try await renderer.load(input, inputSpace: "sRGB")
        let project = FilmProject()
        let low = try await renderer.render(project: project, frame: nil)
        #expect(low.width == 1800)
        let high = try await renderer.render(project: project, frame: nil, displayLongSide: 4096)
        #expect(high.width == 4096 && high.height == 512 && high.bitsPerPixel == 64)
        var pixels = [Float](repeating: 0, count: 8)
        CIContext().render(CIImage(cgImage: high), toBitmap: &pixels, rowBytes: 32,
            bounds: CGRect(x: 200, y: 200, width: 2, height: 1), format: .RGBAf,
            colorSpace: FilmRenderer.colorSpace("Linear sRGB"))
        #expect(abs(pixels[0] - pixels[4]) > 0.9)
        #expect(high === (try await renderer.render(project: project, frame: nil, displayLongSide: 2000)))
        let frame = FilmFrame(name: "01", crop: FilmRect(width: 0.0625), rotation: 90)
        let crop = try await renderer.render(project: project, frame: frame, displayLongSide: 1024)
        #expect(crop.width == 512 && crop.height == 256)
        try await renderer.export(project: project, frame: frame, to: output)
        let exported = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let bitmap = try #require(CGImageSourceCreateImageAtIndex(exported, 0, nil))
        #expect(bitmap.width == 512 && bitmap.height == 256 && bitmap.bitsPerComponent == 16)
        await renderer.close()
        do {
            _ = try await renderer.render(project: project, frame: nil, displayLongSide: 4096)
            Issue.record("Closing a source must release every display tier")
        } catch { #expect(error is FilmFailure) }
    }

    /// Zoom-out preserves quality; import cancels an old demand and resets both modes even for equal-size files.
    @Test @MainActor func displayDemandAndImportReset() async throws {
        let input = FileManager.default.temporaryDirectory.appending(path: "FilmZoomStore-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: input) }
        try Self.writeScan(to: input)
        let store = FilmStore()
        store.loadSource(input, restoring: nil)
        for _ in 0..<500 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!store.busy && store.error == nil && store.info != nil)
        store.zoom = 4
        store.displayNeeds(4000)
        await store.renderTask?.value
        let high = try #require(store.image)
        #expect(high.width == 4096)
        store.displayNeeds(2000)
        #expect(store.image === high)
        store.showStrip = false; store.zoom = 3
        store.displayNeeds(4096)
        await store.renderTask?.value
        #expect(store.image?.width == 4096)
        store.rememberCanvasCenter(CGPoint(x: 0.2, y: 0.8), strip: false)
        store.showStrip = true
        let generation = store.sourceGeneration
        store.displayNeeds(4096)
        store.loadSource(input, restoring: nil)
        for _ in 0..<500 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!store.busy && store.error == nil)
        #expect(store.sourceGeneration == generation + 1 && store.showStrip && store.zoom == 1)
        #expect(store.image?.width == 1800 && store.canvasCenter == CGPoint(x: 0.5, y: 0.5))
        store.showStrip = false
        #expect(store.zoom == 1 && store.canvasCenter == CGPoint(x: 0.5, y: 0.5))
        store.renderTask?.cancel()
        await store.renderer.close()
    }

    private nonisolated static func writeScan(to url: URL) throws {
        let width = 4096, height = 512
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 2) {
                let offset = (y * width + x) * 4
                pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0
            }
        }
        let space = FilmRenderer.colorSpace("sRGB")
        let source = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                             format: .RGBA8, colorSpace: space)
        try CIContext().writeTIFFRepresentation(of: source, to: url, format: .RGBA16, colorSpace: space, options: [:])
    }
}
#endif

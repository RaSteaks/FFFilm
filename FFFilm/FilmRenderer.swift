#if os(macOS)
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// All decoding and rendering runs off the main actor. Only immutable snapshots cross this boundary.
/// Error messages read the saved language instead of accessing the observable UI preference.
actor FilmRenderer {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    private var source: CIImage?
    private var preview: CIImage?
    private var basePreview: CGImage?
    private var accessURL: URL?
    private var hasAccess = false

    struct SourceInfo: Sendable {
        let width: Int, height: Int, depth: Int
        let hasProfile: Bool
        let isFFF: Bool
        let profileName: String
        let layout: FilmLayout
    }

    struct ScanProbe: Sendable {
        let hasProfile: Bool
    }

    /// Read only image-directory metadata before asking for an untagged scan's input profile.
    func probe(_ url: URL) throws -> ScanProbe {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let imageSource = try Self.openImageSource(url)
        let (_, properties) = try Self.largestImage(in: imageSource)
        return ScanProbe(hasProfile: properties[kCGImagePropertyProfileName as String] != nil)
    }

    private static func openImageSource(_ url: URL) throws -> CGImageSource {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary) else {
            throw FilmFailure(message: filmText("无法读取扫描文件。", "Cannot read the scan file.", language: AppLanguage.initial()))
        }
        return imageSource
    }

    /// FFF files can expose several IFDs, including a small embedded preview.
    private static func largestImage(in imageSource: CGImageSource) throws -> (Int, [String: Any]) {
        guard CGImageSourceGetCount(imageSource) > 0 else {
            throw FilmFailure(message: filmText("无法读取扫描文件。", "Cannot read the scan file.", language: AppLanguage.initial()))
        }
        var bestIndex = 0, bestArea = 0
        var bestProperties: [String: Any] = [:]
        for index in 0..<CGImageSourceGetCount(imageSource) {
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [String: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let (area, overflow) = width.multipliedReportingOverflow(by: height)
            if !overflow && area > bestArea { bestIndex = index; bestArea = area; bestProperties = properties }
        }
        return (bestIndex, bestProperties)
    }

    func load(_ url: URL, inputSpace: String, inputProfile: Data? = nil) throws -> SourceInfo {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let imageSource = try Self.openImageSource(url)
        let (bestIndex, properties) = try Self.largestImage(in: imageSource)
        // Give users a supported recovery format instead of requesting developer samples.
        guard let cg = CGImageSourceCreateImageAtIndex(imageSource, bestIndex, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FilmFailure(message: filmText("无法读取完整扫描图像，请从扫描软件导出 16 位 RGB TIFF 后重试。", "Cannot read the full scan. Export a 16-bit RGB TIFF from your scanning software and try again.", language: AppLanguage.initial()))
        }
        let isFFF = url.pathExtension.lowercased() == "fff"
        // ImageIO accepting a file is insufficient: reject preview-only and non-RGB RAW decoding.
        if isFFF && (cg.bitsPerComponent < 16 || cg.colorSpace?.model != .rgb) {
            throw FilmFailure(message: filmText("无法从此 FFF 读取完整的 16 位 RGB 图像，请改用 16 位 RGB TIFF。", "This FFF cannot be read as a full 16-bit RGB image. Use a 16-bit RGB TIFF instead.", language: AppLanguage.initial()))
        }
        let profiled = properties[kCGImagePropertyProfileName as String] != nil
        // Embedded profiles describe the actual stored pixels and take precedence over
        // a fallback assignment. A generic RGB color space alone is not proof of an ICC.
        let space: CGColorSpace
        if profiled, let embedded = cg.colorSpace {
            space = embedded
        } else if let inputProfile {
            guard let custom = CGColorSpace(iccData: inputProfile as CFData), custom.model == .rgb else {
                throw FilmFailure(message: filmText("输入 ICC 必须是有效的 RGB 配置文件。", "The input ICC must be a valid RGB profile.", language: AppLanguage.initial()))
            }
            space = custom
        } else {
            guard ["sRGB", "Adobe RGB", "Linear sRGB", "Display P3"].contains(inputSpace) else {
                throw FilmFailure(message: filmText("缺少有效的输入色彩配置。", "A valid input color profile is required.", language: AppLanguage.initial()))
            }
            space = Self.colorSpace(inputSpace)
        }
        let decoded = CIImage(cgImage: cg, options: [.colorSpace: space])
            .oriented(forExifOrientation: Int32(properties[kCGImagePropertyOrientation as String] as? Int ?? 1))
        let oriented = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
        // ImageIO samples the selected full-size IFD, retaining its 16-bit RGB data.
        // Never use an FFF container's separate low-resolution preview IFD.
        let maxDimension = max(cg.width, cg.height)
        let factor = maxDimension >= 14_400 ? 8 : maxDimension >= 7_200 ? 4 : maxDimension >= 3_600 ? 2 : 1
        let previewSource: CGImage
        if factor > 1,
           let sampled = CGImageSourceCreateImageAtIndex(imageSource, bestIndex,
                [kCGImageSourceShouldCache: false, kCGImageSourceSubsampleFactor: factor] as CFDictionary),
           sampled.bitsPerComponent == cg.bitsPerComponent,
           sampled.width >= max(1, cg.width / factor - 1),
           sampled.height >= max(1, cg.height / factor - 1),
           sampled.colorSpace?.model == .rgb {
            previewSource = sampled
        } else { previewSource = cg }
        let previewDecoded = CIImage(cgImage: previewSource, options: [.colorSpace: space])
            .oriented(forExifOrientation: Int32(properties[kCGImagePropertyOrientation as String] as? Int ?? 1))
        let normalized = previewDecoded.transformed(by: CGAffineTransform(translationX: -previewDecoded.extent.minX, y: -previewDecoded.extent.minY))
        let scale = min(1, 1800 / max(normalized.extent.width, normalized.extent.height))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let previewSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let materialized = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh, colorSpace: previewSpace) else {
            throw FilmFailure(message: filmText("预览渲染失败。", "Preview rendering failed.", language: AppLanguage.initial()))
        }
        // Commit only after decoding succeeds; later edits now read bounded preview pixels.
        if hasAccess { accessURL?.stopAccessingSecurityScopedResource() }
        accessURL = url
        hasAccess = url.startAccessingSecurityScopedResource()
        source = oriented
        basePreview = materialized
        preview = CIImage(cgImage: materialized, options: [.colorSpace: previewSpace])
        // Classify from the bounded, oriented preview; no full-resolution analysis copy.
        let (pixels, width, height) = previewPixels()
        let frames = Self.frameRects(pixels: pixels, width: width, height: height)
        let layout = FilmScanAnalysis.layout(width: Int(oriented.extent.width), height: Int(oriented.extent.height),
            properties: properties, pixels: pixels, previewWidth: width, previewHeight: height, frames: frames)
        // A custom ICC can have no CGColorSpace name; retain its selected label then.
        return SourceInfo(width: Int(oriented.extent.width), height: Int(oriented.extent.height), depth: cg.bitsPerComponent, hasProfile: profiled, isFFF: isFFF, profileName: space.name as String? ?? inputSpace, layout: layout)
    }

    static func colorSpace(_ name: String) -> CGColorSpace {
        CGColorSpace(name: name == "Adobe RGB" ? CGColorSpace.adobeRGB1998 : name == "Linear sRGB" ? CGColorSpace.linearSRGB : name == "Display P3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
    }

    func close() {
        source = nil; preview = nil; basePreview = nil
        context.clearCaches()
        if hasAccess { accessURL?.stopAccessingSecurityScopedResource() }
        accessURL = nil; hasAccess = false
    }

    /// Normalized rectangles use top-left coordinates, unlike Core Image's bottom-left origin.
    static func pixelRect(_ crop: FilmRect, extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + crop.x * extent.width, y: extent.minY + (1 - crop.y - crop.height) * extent.height,
               width: crop.width * extent.width, height: crop.height * extent.height).integral.intersection(extent)
    }

    /// Slicing changes geometry only; removed tone/curve fields cannot affect output.
    private func cropped(_ input: CIImage, frame: FilmFrame) -> CIImage {
        var image = input.cropped(to: Self.pixelRect(frame.crop, extent: input.extent))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if frame.rotation != 0 { image = image.transformed(by: CGAffineTransform(rotationAngle: frame.rotation * .pi / 180)) }
        return image
    }

    /// Strip previews and exports place rotated crops in their original slots.
    /// Rotated frame edges are clipped by that slot; individual exports keep the full rotated frame.
    private func rendered(_ input: CIImage, project: FilmProject, frame: FilmFrame?) -> CIImage {
        if let frame { return cropped(input, frame: frame) }
        var strip = input
        for item in project.frames {
            // Unchanged frames already match the strip; compositing them again can
            // resample fractional preview edges and alter otherwise untouched pixels.
            if item.rotation == 0 { continue }
            let slot = Self.pixelRect(item.crop, extent: input.extent)
            let rotated = cropped(input, frame: item)
            let placed = rotated.transformed(by: CGAffineTransform(translationX: slot.midX - rotated.extent.midX, y: slot.midY - rotated.extent.midY)).cropped(to: slot)
            strip = placed.composited(over: strip)
        }
        return strip.cropped(to: input.extent)
    }

    func render(project: FilmProject, frame: FilmFrame?) throws -> CGImage {
        guard let preview, let basePreview else { throw FilmFailure(message: filmText("请先导入扫描。", "Import a scan first.", language: AppLanguage.initial())) }
        // The untouched strip is already rendered; reuse it for the canvas and thumbnails.
        if frame == nil && !project.frames.contains(where: { $0.rotation != 0 }) { return basePreview }
        let image = rendered(preview, project: project, frame: frame)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else {
            throw FilmFailure(message: filmText("预览渲染失败。", "Preview rendering failed.", language: AppLanguage.initial()))
        }
        return result
    }

    /// Render rotated frame thumbnails from the cached preview at their display size.
    func thumbnail(frame: FilmFrame) throws -> CGImage {
        guard let preview else { throw FilmFailure(message: filmText("请先导入扫描。", "Import a scan first.", language: AppLanguage.initial())) }
        let image = cropped(preview, frame: frame)
        let scale = min(1, 96 / image.extent.width, 60 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Keep the same extended-linear display path as the main preview.
        guard let result = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else {
            throw FilmFailure(message: filmText("预览渲染失败。", "Preview rendering failed.", language: AppLanguage.initial()))
        }
        return result
    }

    /// Detect sustained gaps across the center band; exclude sprockets near the strip edges.
    func detectFrames() throws -> [FilmRect] {
        let (pixels, width, height) = previewPixels()
        return Self.frameRects(pixels: pixels, width: width, height: height)
    }

    /// Import classification and explicit gap detection use the same sampled pixels.
    private func previewPixels() -> ([UInt8], Int, Int) {
        guard let preview else { return ([], 0, 0) }
        let width = Int(preview.extent.width), height = Int(preview.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(preview, toBitmap: &pixels, rowBytes: width * 4, bounds: preview.extent, format: .RGBA8, colorSpace: Self.colorSpace("sRGB"))
        return (pixels, width, height)
    }

    private static func frameRects(pixels: [UInt8], width: Int, height: Int) -> [FilmRect] {
        let horizontal = width >= height
        let length = horizontal ? width : height, cross = horizontal ? height : width
        guard length > 10, cross > 4 else { return [] }
        var signal = [Double](repeating: 0, count: length)
        for i in 0..<length {
            var total = 0.0, count = 0.0
            for j in (cross / 4)..<(cross * 3 / 4) {
                let offset = horizontal ? (j * width + i) * 4 : (i * width + j) * 4
                total += Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2]); count += 3
            }
            signal[i] = total / max(1, count)
        }
        return split(signal: signal, horizontal: horizontal)
    }

    static func split(signal: [Double], horizontal: Bool) -> [FilmRect] {
        guard let low = signal.min(), let high = signal.max(), high - low > 12 else { return [] }
        let count = signal.count
        let threshold = (high - low) * 0.06
        // Evaluate dark and clear gaps separately; combining both extrema would mark
        // a two-tone test strip as one continuous gap.
        var candidates: [[Int]] = []
        for bright in [false, true] {
            var gaps: [Int] = [], start: Int?
            for i in 0...count {
                let isGap = i < count && (bright ? signal[i] >= high - threshold : signal[i] <= low + threshold)
                if isGap && start == nil { start = i }
                if !isGap, let beginning = start {
                    let span = i - beginning
                    if span >= max(2, count / 500), span < count / 8, beginning > count / 50, i < count * 49 / 50 {
                        gaps.append((beginning + i) / 2)
                    }
                    start = nil
                }
            }
            candidates.append(gaps)
        }
        let gaps = candidates.max(by: { $0.count < $1.count }) ?? []
        var boundaries = [0]
        for gap in gaps where gap - boundaries.last! > max(4, count / 200) { boundaries.append(gap) }
        boundaries.append(count)
        guard boundaries.count > 2 else { return [] }
        return zip(boundaries, boundaries.dropFirst()).compactMap { a, b in
            guard b - a > max(3, count / 250) else { return nil }
            let origin = Double(a) / Double(count), size = Double(b - a) / Double(count)
            return horizontal ? FilmRect(x: origin, y: 0, width: size, height: 1) : FilmRect(x: 0, y: origin, width: 1, height: size)
        }
    }

    func export(project: FilmProject, frame: FilmFrame?, to url: URL) throws {
        guard let source else { throw FilmFailure(message: filmText("请先导入扫描。", "Import a scan first.", language: AppLanguage.initial())) }
        let image = rendered(source, project: project, frame: frame)
        let space = Self.colorSpace(project.exportJPEG ? "sRGB" : "Adobe RGB")
        if project.exportJPEG {
            // JPEG has no alpha: flatten the rotated crop onto white in linear light
            // before encoding, so transparent corners and antialiased edges stay clean.
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: image.extent)
            let opaque = image.composited(over: white)
            try context.writeJPEGRepresentation(of: opaque, to: url, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: project.jpegQuality])
        } else {
            try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: space, options: [:])
        }
    }
}
#endif

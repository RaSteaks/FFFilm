#if os(macOS)
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd

/// All decoding and rendering runs off the main actor. Only immutable snapshots cross this boundary.
/// Error messages read the saved language instead of accessing the observable UI preference.
actor FilmRenderer {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    private var source: CIImage?
    private var preview: CIImage?
    private var basePreview: CGImage?
    private var detection: FilmDetectionResult?
    private var detectionPixels: (pixels: [UInt8], width: Int, height: Int)?
    private var sourcePixels: NegativeFilePixels?
    private var sourceOrientation: Int32 = 1
    private var preparedSource = false
    private var refinedDetection: (options: FilmDetectionOptions, result: FilmDetectionResult)?
    private(set) var sourceIdentifier = UUID()
    private(set) var performance = FilmPerformance()
    // Retain one display tier only; thumbnails/detection keep using the bounded base preview.
    private var displayCache: (project: FilmProject, frame: FilmFrame?, limit: CGFloat, image: CGImage)?
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
        let previewStart = ContinuousClock.now
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
        sourceOrientation = Int32(properties[kCGImagePropertyOrientation as String] as? Int ?? 1)
        sourcePixels = NegativeFilePixels(cg: cg, space: space, orientation: sourceOrientation)
        preparedSource = false
        refinedDetection = nil
        sourceIdentifier = UUID()
        performance = FilmPerformance()
        performance.record(.preview, since: previewStart)
        displayCache = nil
        basePreview = materialized
        preview = CIImage(cgImage: materialized, options: [.colorSpace: previewSpace])
        // Classify from the bounded, oriented preview; no full-resolution analysis copy.
        let (pixels, width, height) = previewPixels()
        detectionPixels = (pixels, width, height)
        let analysis = FilmFrameDetection.analyze(pixels: pixels, width: width, height: height, performance: &performance)
        detection = analysis
        let layout = FilmScanAnalysis.layout(width: Int(oriented.extent.width), height: Int(oriented.extent.height),
            properties: properties, pixels: pixels, previewWidth: width, previewHeight: height, frames: analysis.splitFrames)
        // A custom ICC can have no CGColorSpace name; retain its selected label then.
        return SourceInfo(width: Int(oriented.extent.width), height: Int(oriented.extent.height), depth: cg.bitsPerComponent, hasProfile: profiled, isFFF: isFFF, profileName: space.name as String? ?? inputSpace, layout: layout)
    }

    static func colorSpace(_ name: String) -> CGColorSpace {
        CGColorSpace(name: name == "Adobe RGB" ? CGColorSpace.adobeRGB1998 : name == "Linear sRGB" ? CGColorSpace.linearSRGB : name == "Display P3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
    }

    func close() {
        source = nil; preview = nil; basePreview = nil; displayCache = nil; detection = nil
        detectionPixels = nil; sourcePixels = nil; refinedDetection = nil; preparedSource = false
        sourceIdentifier = UUID()
        context.clearCaches()
        if hasAccess { accessURL?.stopAccessingSecurityScopedResource() }
        accessURL = nil; hasAccess = false
    }

    /// Normalized rectangles use top-left coordinates, unlike Core Image's bottom-left origin.
    nonisolated static func pixelRect(_ crop: FilmRect, extent: CGRect) -> CGRect {
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

    /// Bound RGBAh display output to 128 MiB and 8192 pixels per side, never enlarging the source.
    /// Rounded tiers avoid rendering for every small trackpad change; exports remain unrestricted.
    nonisolated static func displayLimit(_ requested: CGFloat, size: CGSize) -> CGFloat {
        guard requested.isFinite, requested > 0, size.width > 0, size.height > 0 else { return 0 }
        let longest = max(size.width, size.height)
        let tier = requested <= 1800 ? requested : (requested / 512).rounded(.up) * 512
        let budget = sqrt(16_777_216 / (size.width * size.height)) * longest
        return min(tier, longest, 8192, budget)
    }

    func render(project: FilmProject, frame: FilmFrame?, displayLongSide: CGFloat? = nil) throws -> CGImage {
        guard let preview, let basePreview else { throw FilmFailure(message: filmText("请先导入扫描。", "Import a scan first.", language: AppLanguage.initial())) }
        try Task.checkCancellation()
        if let requested = displayLongSide, let source {
            let size = FilmZoom.sourceSize(width: Int(source.extent.width), height: Int(source.extent.height), frame: frame)
            let limit = Self.displayLimit(requested, size: size)
            if let cache = displayCache, cache.project == project, cache.frame == frame, cache.limit >= limit {
                return cache.image
            }
            let lowResolution = rendered(preview, project: project, frame: frame)
            if limit > max(lowResolution.extent.width, lowResolution.extent.height) + 1 {
                // Crop/rotate from the full source BEFORE downsampling: a short frame must
                // not inherit the entire strip's 1800px limit or upscale already blurred pixels.
                let image = rendered(source, project: project, frame: frame)
                let scale = min(1, limit / max(image.extent.width, image.extent.height))
                let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                // Integral output dimensions enforce the pixel budget while retaining the full bounds.
                let width = max(1, floor(image.extent.width * scale + 0.000001))
                let height = max(1, floor(image.extent.height * scale + 0.000001))
                let scaled = normalized.transformed(by: CGAffineTransform(
                    scaleX: width / normalized.extent.width, y: height / normalized.extent.height))
                guard let result = context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAh,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else {
                    throw FilmFailure(message: filmText("预览渲染失败。", "Preview rendering failed.", language: AppLanguage.initial()))
                }
                try Task.checkCancellation()
                displayCache = (project, frame, limit, result)
                return result
            }
        }
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

    /// Compatibility API keeps transport intervals distinct from effective image crops.
    func detectFrames() throws -> [FilmRect] {
        try detectFrameCandidates().splitFrames
    }

    func detectFrameCandidates() throws -> FilmDetectionResult {
        try Task.checkCancellation()
        return detection ?? FilmDetectionResult()
    }

    func sampleFilmBase(at point: CGPoint) throws -> FilmBaseSample {
        guard let source, let region = NegativePixels.sampleRect(point: point, extent: source.extent) else {
            throw NegativeFailure(key: "negative.error.sampleBounds")
        }
        let rect = FilmRect(x: region.minX / source.extent.width,
            y: 1 - region.maxY / source.extent.height,
            width: region.width / source.extent.width, height: region.height / source.extent.height)
        let pixels = try readRegion(rect, maxWidth: 128, maxHeight: 128)
        guard let sample = FilmBaseSample.estimate(pixels.colors,
            position: source.extent.width >= source.extent.height ? point.x : point.y) else {
            throw NegativeFailure(key: "negative.error.sampleClipped")
        }
        return sample
    }

    /// All options and intermediate samples are session-local. Only accepted crop rectangles
    /// enter the document; cancellation never commits a partially refined detection cache.
    func refineFrames(options: FilmDetectionOptions,
                      progress: @Sendable (FilmDetectionProgress) async -> Void) async throws -> FilmDetectionResult {
        try Task.checkCancellation()
        if let cache = refinedDetection, cache.options == options { return cache.result }
        guard let extent = source?.extent, let previewData = detectionPixels, let original = detection else { return FilmDetectionResult() }
        let identifier = sourceIdentifier
        let started = ContinuousClock.now
        defer { performance.record(.refinement, since: started) }
        try prepareSourcePixels()
        let horizontal = extent.width >= extent.height
        let length = horizontal ? extent.width : extent.height
        var result = original
        if let sampled = options.base {
            result = FilmFrameDetection.analyze(pixels: previewData.pixels, width: previewData.width,
                height: previewData.height, performance: &performance, baseColor: sampled.encoded)
        }
        if length > 3600 {
            // Include several frame-widths of context and preserve pixel aspect ratio.
            // Anisotropic 1800×256 tiles made physical gaps too wide for the detector's
            // width/flank rules on high-resolution scans; tile ends never become cuts.
            var gaps = result.gaps
            let cross = horizontal ? extent.height : extent.width
            let tileLength = min(length, max(1800, cross * 3.5)), stride = tileLength * 0.75
            let count = Int(ceil(max(0, length - tileLength) / stride)) + 1
            for index in 0..<count {
                try Task.checkCancellation()
                guard identifier == sourceIdentifier else { throw CancellationError() }
                let start = min(Double(index) * stride, max(0, length - tileLength))
                let span = min(tileLength, length)
                let rect = horizontal ? FilmRect(x: start / length, width: span / length)
                    : FilmRect(y: start / length, height: span / length)
                let tilePixels = try segmentPixels(rect, horizontal: horizontal)
                let tile = FilmFrameDetection.analyze(pixels: tilePixels.pixels, width: tilePixels.width, height: tilePixels.height,
                    performance: &performance, baseColor: options.base?.encoded)
                // A tile boundary is arbitrary; only the whole scan may extrapolate pitch.
                for gap in tile.gaps where !gap.inferred {
                    let mapped = FilmDetectedGap(start: (start + gap.start * span) / length,
                        end: (start + gap.end * span) / length, color: gap.color, corroborated: gap.corroborated, inferred: gap.inferred)
                    let reference = options.base?.encoded ?? original.gaps.min {
                        abs($0.center - mapped.center) < abs($1.center - mapped.center)
                    }?.color
                    // A tile can contain only a scene stripe, even when the full strip has
                    // reliable gaps. Require compatible global base or independent local evidence.
                    if let reference {
                        guard simd_distance(reference, gap.color) / sqrt(3) <= 20 else { continue }
                    } else if !gap.corroborated { continue }
                    if let match = gaps.firstIndex(where: {
                        max($0.start, mapped.start) <= min($0.end, mapped.end)
                            || abs($0.center - mapped.center) * length <= 3
                    }) {
                        // Source-resolution measurements replace blurred whole-strip intervals.
                        gaps[match] = mapped
                    } else { gaps.append(mapped) }
                }
                await progress(FilmDetectionProgress(phase: .segments, completed: index + 1, total: count))
            }
            gaps.sort { $0.center < $1.center }
            result = FilmFrameDetection.assemble(gaps: gaps, marginColor: options.base?.encoded,
                pixels: previewData.pixels, width: previewData.width, height: previewData.height)
            // A tightly cropped single frame may have no gaps at any scale.
            if result.candidates.isEmpty { result = original }
        }
        var samples: [FilmBaseSample] = []
        if let base = options.base { samples = [base] }
        else {
            for gap in result.gaps {
                try Task.checkCancellation()
                let span = max(1 / length, (gap.end - gap.start) * 0.4)
                let rect = horizontal
                    ? FilmRect(x: gap.center - span / 2, y: 0.4, width: span, height: 0.2)
                    : FilmRect(x: 0.4, y: gap.center - span / 2, width: 0.2, height: span)
                let region = try readRegion(rect, maxWidth: 64, maxHeight: 64)
                if let sample = FilmBaseSample.estimate(region.colors, position: gap.center) { samples.append(sample) }
            }
        }
        let model = FilmBaseModel(samples: samples.sorted { $0.position < $1.position })
        await progress(FilmDetectionProgress(phase: .base, completed: samples.count, total: samples.count))
        let scaleX = extent.width / Double(previewData.width)
        let scaleY = extent.height / Double(previewData.height)
        for index in result.candidates.indices {
            try Task.checkCancellation()
            guard identifier == sourceIdentifier else { throw CancellationError() }
            var candidate = result.candidates[index]
            let position = horizontal ? candidate.slot.x + candidate.slot.width / 2 : candidate.slot.y + candidate.slot.height / 2
            let base = model.sample(at: position, fallback: candidate.base)
            for edge in FilmCropEdge.allCases {
                try Task.checkCancellation()
                let vertical = edge == .left || edge == .right
                let lower = edge == .left || edge == .top
                let dimension = vertical ? extent.width : extent.height
                let scale = vertical ? scaleX : scaleY
                let evidence = candidate.edges[edge] ?? .insufficient
                guard evidence != .inferred else { continue }
                guard evidence != .reliable || scale > 1.01 || options.base != nil || options.calibration != nil else { continue }
                let slotOrigin = vertical ? candidate.slot.x : candidate.slot.y
                let slotSize = vertical ? candidate.slot.width : candidate.slot.height
                let cropOrigin = vertical ? candidate.crop.x : candidate.crop.y
                let cropSize = vertical ? candidate.crop.width : candidate.crop.height
                let boundary = lower ? cropOrigin : cropOrigin + cropSize
                let scannerEdge = candidate.scannerEdges.contains(edge)
                let sharedScannerEdge = scannerEdge && vertical != horizontal
                let acrossSize = vertical ? candidate.slot.height * extent.height : candidate.slot.width * extent.width
                var radius = max(8 * scale, acrossSize * 0.04) / dimension
                if let calibration = options.calibration {
                    let crossEdge = vertical != horizontal
                    let hintOrigin = vertical ? calibration.x : calibration.y
                    let hintSize = vertical ? calibration.width : calibration.height
                    let expected = crossEdge ? (lower ? hintOrigin : hintOrigin + hintSize)
                        : slotOrigin + slotSize / 2 + (lower ? -hintSize / 2 : hintSize / 2)
                    radius = max(radius, abs(expected - boundary) + 4 * scale / dimension,
                                 abs(sin(options.calibrationAngle * .pi / 180)) * acrossSize / dimension)
                }
                let searchStart: Double, searchEnd: Double
                if evidence == .insufficient {
                    let depth = min(slotSize * 0.45, max(slotSize * 0.24, radius))
                    searchStart = lower ? slotOrigin : slotOrigin + slotSize - depth
                    searchEnd = lower ? slotOrigin + depth : slotOrigin + slotSize
                } else {
                    searchStart = max(0, boundary - radius)
                    searchEnd = min(1, boundary + radius)
                }
                let across = scannerEdge ? candidate.crop : candidate.slot
                let rect = vertical
                    ? FilmRect(x: searchStart, y: across.y, width: searchEnd - searchStart, height: across.height)
                    : FilmRect(x: across.x, y: searchStart, width: across.width, height: searchEnd - searchStart)
                let region = try readRegion(rect, maxWidth: vertical ? 2048 : 129, maxHeight: vertical ? 129 : 2048)
                let edgeBase: FilmBaseSample
                if scannerEdge, let background = result.scannerBackground {
                    edgeBase = FilmBaseSample(position: position, color: FilmBaseSample.linear(background), noise: SIMD3(repeating: 0.0001))
                } else { edgeBase = base }
                var found = FilmEdgeRefinement.boundary(in: region, edge: edge, base: edgeBase, scannerBackground: scannerEdge)
                if sharedScannerEdge, evidence != .insufficient, let boundaryResult = found {
                    // Refine within the shared aperture's preview uncertainty. A black subject
                    // occupying an entire local edge must not pull the crop deep into that frame.
                    let inward = lower ? boundaryResult.position - boundary : boundary - boundaryResult.position
                    let allowance: Double
                    if let limit = candidate.scannerLimits[edge] {
                        allowance = max(0, lower ? limit - boundary : boundary - limit) + scale / dimension
                    } else { allowance = (evidence == .needsRefinement ? 5.0 : 3.0) * scale / dimension }
                    if inward > allowance { found = nil }
                }
                if let found {
                    var refined = candidate.crop
                    switch edge {
                    case .left: refined.width += refined.x - found.position; refined.x = found.position
                    case .right: refined.width = found.position - refined.x
                    case .top: refined.height += refined.y - found.position; refined.y = found.position
                    case .bottom: refined.height = found.position - refined.y
                    }
                    if refined.valid { candidate.crop = refined; candidate.edges[edge] = found.evidence }
                } else if evidence != .insufficient {
                    candidate.edges[edge] = .needsRefinement
                    // The shared scanner aperture already retains its outer envelope. A dark
                    // local subject should preserve that bound, not add a second preview margin.
                    if sharedScannerEdge { continue }
                    // Quantized preview boundaries are uncertain by a source-scaled pixel.
                    let padding = scale / dimension
                    switch edge {
                    case .left: let amount = min(padding, candidate.crop.x); candidate.crop.x -= amount; candidate.crop.width += amount
                    case .right: candidate.crop.width = min(1 - candidate.crop.x, candidate.crop.width + padding)
                    case .top: let amount = min(padding, candidate.crop.y); candidate.crop.y -= amount; candidate.crop.height += amount
                    case .bottom: candidate.crop.height = min(1 - candidate.crop.y, candidate.crop.height + padding)
                    }
                }
            }
            result.candidates[index] = candidate
            await progress(FilmDetectionProgress(phase: .edges, completed: index + 1, total: result.candidates.count))
        }
        try Task.checkCancellation()
        guard identifier == sourceIdentifier else { throw CancellationError() }
        refinedDetection = (options, result)
        return result
    }

    /// ImageIO may decode a compressed strip again for every cropped CGImage. Share one
    /// raw provider only inside a fixed CPU budget; oversized scans keep the lazy path.
    private func prepareSourcePixels() throws {
        guard !preparedSource, let original = sourcePixels else { return }
        let budget = min(UInt64(256 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 8)
        let cg = original.cg
        guard UInt64(cg.bytesPerRow) <= budget / UInt64(cg.height) else { preparedSource = true; return }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        defer { performance.record(.sourceDecode, since: started) }
        guard let bytes = cg.dataProvider?.data, CFDataGetLength(bytes) >= cg.bytesPerRow * cg.height,
              let provider = CGDataProvider(data: bytes),
              let decoded = CGImage(width: cg.width, height: cg.height, bitsPerComponent: cg.bitsPerComponent,
                bitsPerPixel: cg.bitsPerPixel, bytesPerRow: cg.bytesPerRow, space: cg.colorSpace ?? original.space,
                bitmapInfo: cg.bitmapInfo, provider: provider, decode: cg.decode,
                shouldInterpolate: false, intent: cg.renderingIntent) else { preparedSource = true; return }
        try Task.checkCancellation()
        let pixels = NegativeFilePixels(cg: decoded, space: original.space, orientation: sourceOrientation)
        sourcePixels = pixels; source = pixels.image; preparedSource = true
    }

    /// Gap classification needs encoded RGB only. Avoid a float readback plus per-pixel
    /// Swift arrays/pow operations; edge fitting still reads linear source-precision floats.
    private func segmentPixels(_ rect: FilmRect, horizontal: Bool) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let started = ContinuousClock.now
        defer { performance.record(.segmentConversion, since: started) }
        return try autoreleasepool {
            guard let source, let sourcePixels else { throw NegativeFailure(key: "negative.error.decode") }
            let native = Self.pixelRect(rect, extent: source.extent)
            let along = horizontal ? native.width : native.height
            let cross = horizontal ? native.height : native.width
            let scale = min(1, 1800 / along, 512 / cross)
            let width = max(1, Int((native.width * scale).rounded(.down)))
            let height = max(1, Int((native.height * scale).rounded(.down)))
            let image = sourcePixels.region(native)
                .transformed(by: CGAffineTransform(translationX: -native.minX, y: -native.minY))
                .transformed(by: CGAffineTransform(scaleX: Double(width) / native.width, y: Double(height) / native.height))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &pixels, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: Self.colorSpace("sRGB"))
            return (pixels, width, height)
        }
    }

    /// Bound float readback to at most 2048 × 129 pixels for edge work. Cropping the
    /// CGImage first avoids uploading the whole scan for each small Core Image request.
    private func readRegion(_ rect: FilmRect, maxWidth: Int, maxHeight: Int) throws -> FilmPixelRegion {
        let started = ContinuousClock.now
        defer { performance.record(.regionRead, since: started) }
        return try autoreleasepool {
            guard let source, let sourcePixels else { throw NegativeFailure(key: "negative.error.decode") }
            let native = Self.pixelRect(rect, extent: source.extent)
            guard native.width >= 1, native.height >= 1 else { throw NegativeFailure(key: "negative.error.sampleBounds") }
            let width = min(maxWidth, Int(native.width)), height = min(maxHeight, Int(native.height))
            let image = sourcePixels.region(native)
                .transformed(by: CGAffineTransform(translationX: -native.minX, y: -native.minY))
                .transformed(by: CGAffineTransform(scaleX: Double(width) / native.width, y: Double(height) / native.height))
            var pixels = [Float](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &pixels, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: NegativePixels.linear)
            let colors = try stride(from: 0, to: pixels.count, by: 4).map { offset in
                let value = SIMD3<Double>(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
                guard (0..<3).allSatisfy({ value[$0].isFinite }) else { throw NegativeFailure(key: "negative.error.decode") }
                return value
            }
            return FilmPixelRegion(rect: FilmRect(x: Double(native.minX / source.extent.width),
                y: 1 - Double(native.maxY / source.extent.height), width: Double(native.width / source.extent.width),
                height: Double(native.height / source.extent.height)), width: width, height: height, colors: colors)
        }
    }

    /// Import classification and explicit gap detection use the same sampled pixels.
    private func previewPixels() -> ([UInt8], Int, Int) {
        guard let preview else { return ([], 0, 0) }
        let start = ContinuousClock.now
        defer { performance.record(.pixels, since: start) }
        let width = Int(preview.extent.width), height = Int(preview.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(preview, toBitmap: &pixels, rowBytes: width * 4, bounds: preview.extent, format: .RGBA8, colorSpace: Self.colorSpace("sRGB"))
        return (pixels, width, height)
    }

    func export(project: FilmProject, frame: FilmFrame?, to url: URL, sourceIdentifier expectedSource: UUID? = nil) throws {
        let start = ContinuousClock.now
        defer { performance.record(.export, since: start) }
        try Task.checkCancellation()
        // A queued retry must never apply an old crop snapshot to a replacement scan.
        if let expectedSource, expectedSource != sourceIdentifier {
            throw FilmFailure(message: filmText("原始扫描已改变，请重新设置导出。", "The source scan changed. Configure a new export.", language: AppLanguage.initial()))
        }
        try prepareSourcePixels()
        try autoreleasepool {
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
}
#endif

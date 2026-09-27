import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import os
#endif

/// Kept platform-neutral for pixel/codec regression tests; only the iOS UI exposes it.
nonisolated enum NegativeFormat: String, CaseIterable, Identifiable, Sendable {
    case tiff, png, jpg
    var id: Self { self }
    var title: String { rawValue.uppercased() }
}

nonisolated struct NegativeFailure: LocalizedError, Sendable {
    let key: String
    var errorDescription: String? { NSLocalizedString(key, comment: "Negative preview error") }
}

nonisolated struct NegativeBase: Sendable, Equatable {
    let red: Float, green: Float, blue: Float
    let uneven: Bool
}

/// A source owns a private file copy until every preview/export job releases it.
nonisolated final class NegativeAsset: @unchecked Sendable {
    let image: CIImage
    let preview: CGImage
    let width: Int, height: Int
    let assumesSRGB: Bool
    let fileURL: URL?
    let filePixels: NegativeFilePixels?
    init(image: CIImage, preview: CGImage, assumesSRGB: Bool = false, fileURL: URL? = nil, filePixels: NegativeFilePixels? = nil) {
        self.image = image; self.preview = preview
        width = Int(image.extent.width); height = Int(image.extent.height)
        self.assumesSRGB = assumesSRGB; self.fileURL = fileURL; self.filePixels = filePixels
    }
    func region(_ rect: CGRect) -> CIImage {
        filePixels?.region(rect) ?? image.cropped(to: rect)
    }
    deinit { if let fileURL { try? FileManager.default.removeItem(at: fileURL) } }
}

/// Crop the ImageIO image before giving pixels to CI, so a small request does not
/// upload the entire scan as a GPU texture. The decoder itself may cache CPU pixels.
nonisolated final class NegativeFilePixels: @unchecked Sendable {
    let cg: CGImage
    let space: CGColorSpace
    let transform: CGAffineTransform
    let image: CIImage
    init(cg: CGImage, space: CGColorSpace, orientation: Int32) {
        self.cg = cg; self.space = space
        let raw = CIImage(cgImage: cg, options: [.colorSpace: space])
        let rotation = raw.orientationTransform(forExifOrientation: orientation)
        let oriented = raw.transformed(by: rotation)
        let translation = CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
        transform = rotation.concatenating(translation)
        image = raw.transformed(by: transform)
    }
    func region(_ rect: CGRect) -> CIImage {
        let rawRect = rect.applying(transform.inverted()).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let topRect = CGRect(x: rawRect.minX, y: CGFloat(cg.height) - rawRect.maxY, width: rawRect.width, height: rawRect.height)
        guard let crop = cg.cropping(to: topRect) else { return CIImage.empty() }
        return CIImage(cgImage: crop, options: [.colorSpace: space])
            .transformed(by: CGAffineTransform(translationX: rawRect.minX, y: rawRect.minY))
            .transformed(by: transform).cropped(to: rect)
    }
    func preview(base: NegativeBase? = nil, context: CIContext) throws -> CGImage {
        let scale = min(1, 1800 / max(image.extent.width, image.extent.height))
        let width = max(1, Int((image.extent.width * scale).rounded()))
        let height = max(1, Int((image.extent.height * scale).rounded()))
        let sx = CGFloat(width) / image.extent.width, sy = CGFloat(height) / image.extent.height
        let rowBytes = width * 8
        var data = Data(count: rowBytes * height)
        try data.withUnsafeMutableBytes { bytes in
            for start in stride(from: 0, to: height, by: 64) {
                try Task.checkCancellation()
                let rows = min(64, height - start)
                let target = CGRect(x: 0, y: height - start - rows, width: width, height: rows)
                // Include source neighbors for the reduction filter at stripe boundaries.
                let sourceRect = target.applying(CGAffineTransform(scaleX: 1 / sx, y: 1 / sy))
                    .insetBy(dx: -2 / sx, dy: -2 / sy).integral.intersection(image.extent)
                autoreleasepool {
                    let tile = region(sourceRect)
                    let converted = base.map { NegativePixels.positive(tile, base: $0) } ?? tile
                    context.render(converted.transformed(by: CGAffineTransform(scaleX: sx, y: sy)),
                                   toBitmap: bytes.baseAddress!.advanced(by: start * rowBytes), rowBytes: rowBytes,
                                   bounds: target, format: .RGBAh, colorSpace: NegativePixels.linear)
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                                   bytesPerRow: rowBytes, space: NegativePixels.linear,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                    .union([.floatComponents, .byteOrder16Little]),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw NegativeFailure(key: "negative.error.render")
        }
        return result
    }
}

nonisolated enum NegativePixels {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let display = CGColorSpace(name: CGColorSpace.sRGB)!
    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }

    /// Core Image's sRGB tone-curve filters make the inversion domain explicit.
    /// RGB normalization happens in linear light, inversion in encoded sRGB.
    static func positive(_ image: CIImage, base: NegativeBase) -> CIImage {
        let normalized = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / CGFloat(max(base.red, 0.000001)), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / CGFloat(max(base.green, 0.000001)), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / CGFloat(max(base.blue, 0.000001)), w: 0)
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        let inverted = normalized.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorInvert").applyingFilter("CISRGBToneCurveToLinear")
        return inverted.composited(over: CIImage(color: .white).cropped(to: image.extent))
            .cropped(to: image.extent)
    }

    static func preview(_ image: CIImage, base: NegativeBase? = nil, context: CIContext, limit: CGFloat = 1800) throws -> CGImage {
        let scale = min(1, limit / max(image.extent.width, image.extent.height))
        // Convert before scaling so display and export sample the same nonlinear operation.
        let converted = base.map { positive(image, base: $0) } ?? image
        let small = converted.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let result = context.createCGImage(small, from: small.extent.integral, format: .RGBAh, colorSpace: linear) else {
            throw NegativeFailure(key: "negative.error.render")
        }
        return result
    }

    /// UI coordinates are top-left normalized; CI coordinates are bottom-left pixels.
    static func sampleRect(point: CGPoint, extent: CGRect) -> CGRect? {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let side = max(8, min(extent.width, extent.height) * 0.01).rounded(.up)
        let x = extent.minX + point.x * extent.width - side / 2
        let y = extent.minY + (1 - point.y) * extent.height - side / 2
        let rect = CGRect(x: x.rounded(), y: y.rounded(), width: side, height: side)
        return extent.contains(rect) ? rect : nil
    }

    static func sample(_ image: CIImage, point: CGPoint, context: CIContext, entireRegion: Bool = false) throws -> NegativeBase {
        guard let rect = entireRegion ? image.extent : sampleRect(point: point, extent: image.extent) else { throw NegativeFailure(key: "negative.error.sampleBounds") }
        // Only a small source-precision region is read back, never screenshot pixels.
        let region = image.cropped(to: rect)
        let scale = min(1, 128 / rect.width)
        let small = region.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = small.extent.integral
        let count = Int(bounds.width * bounds.height)
        var pixels = [Float](repeating: 0, count: count * 4)
        context.render(small, toBitmap: &pixels, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf, colorSpace: linear)
        var channels = [[Float](), [Float](), [Float]()]
        var clipped = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[index + 3]
            guard alpha > 0.99 else { continue }
            let values = (0..<3).map { pixels[index + $0] / alpha }
            guard values.allSatisfy({ $0.isFinite }) else { continue }
            if values.contains(where: { $0 >= 0.995 || $0 <= 0.00001 }) { clipped += 1 }
            for c in 0..<3 { channels[c].append(values[c]) }
        }
        guard channels[0].count >= 32, channels[0].count >= count * 3 / 4 else { throw NegativeFailure(key: "negative.error.sampleBounds") }
        guard clipped < max(1, channels[0].count / 50) else { throw NegativeFailure(key: "negative.error.sampleClipped") }
        var means: [Float] = [], uneven = false
        for values in channels {
            let sorted = values.sorted(), trim = values.count / 10
            let middle = sorted[trim..<(sorted.count - trim)]
            let mean = middle.reduce(0, +) / Float(middle.count)
            guard mean > 0.0001 else { throw NegativeFailure(key: "negative.error.sampleClipped") }
            uneven = uneven || (sorted[sorted.count * 9 / 10] - sorted[sorted.count / 10]) / mean > 0.25
            means.append(mean)
        }
        return NegativeBase(red: means[0], green: means[1], blue: means[2], uneven: uneven)
    }
}

/// Serial file work prevents concurrent full-resolution decoding and export jobs.
actor NegativeRenderer {
    private let context = NegativePixels.context()

    nonisolated static func copiedFile(_ url: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("negative-\(UUID().uuidString).\(url.pathExtension)")
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try FileManager.default.copyItem(at: url, to: target); return target }
        catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    /// Reject a known-unaffordable decode before ImageIO allocates it. Available
    /// memory is a changing snapshot, so this is a guard, not a size guarantee.
    private func checkMemory(width: Int, height: Int, decoding: Bool) throws {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels > 0, pixels < (Int.max - 64 * 1024 * 1024) / 12 else {
            throw NegativeFailure(key: "negative.error.size")
        }
        #if os(iOS) && !targetEnvironment(simulator)
        let estimated = pixels * (decoding ? 12 : 4) + 64 * 1024 * 1024
        guard os_proc_available_memory() > estimated else { throw NegativeFailure(key: "negative.error.memory") }
        #endif
    }

    func load(_ url: URL) throws -> NegativeAsset {
        try Task.checkCancellation()
        return try load(owned: Self.copiedFile(url))
    }

    /// Takes ownership immediately; failures and cancellation remove the copy,
    /// while a successful asset retains it until the asset is released.
    func load(owned: URL) throws -> NegativeAsset {
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: owned) } }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(owned as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.tiff.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = metadata[kCGImagePropertyPixelWidth as String] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight as String] as? Int, width > 0, height > 0 else {
            throw NegativeFailure(key: "negative.error.decode")
        }
        try checkMemory(width: width, height: height, decoding: true)
        if type == UTType.tiff.identifier && CGImageSourceGetCount(source) != 1 { throw NegativeFailure(key: "negative.error.pages") }
        let depth = metadata[kCGImagePropertyDepth as String] as? Int ?? 8
        guard type != UTType.tiff.identifier || depth == 8 || depth == 16 else { throw NegativeFailure(key: "negative.error.depth") }
        let model = metadata[kCGImagePropertyColorModel as String] as? String
        guard model == nil || model == kCGImagePropertyColorModelRGB as String || model == kCGImagePropertyColorModelGray as String else {
            throw NegativeFailure(key: "negative.error.depth")
        }
        // Lazy ImageIO/CI sources retain the file, not a second whole-file Data copy.
        // CI performs source-precision region sampling and stripe rendering for exports.
        // Decode into the shared raw provider below, without retaining another
        // decoder-side pixel cache. Request SDR for gain-map HEIF/JPEG inputs.
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false,
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary) else {
            throw NegativeFailure(key: "negative.error.decode")
        }
        guard cg.bitsPerComponent == 8 || cg.bitsPerComponent == 16,
              type != UTType.tiff.identifier || !cg.bitmapInfo.contains(.floatComponents) else {
            throw NegativeFailure(key: "negative.error.depth")
        }
        let assumed = metadata[kCGImagePropertyProfileName as String] == nil
        // A custom ICC may have no profile-name metadata. Preserve the decoder's
        // calibrated space; only uncalibrated device RGB receives the sRGB fallback.
        let decodedSpace = cg.colorSpace ?? NegativePixels.display
        let space = CFEqual(decodedSpace, CGColorSpaceCreateDeviceRGB()) ? NegativePixels.display : decodedSpace
        let orientation = Int32(metadata[kCGImagePropertyOrientation as String] as? Int ?? 1)
        // ImageIO can re-run LZW/PackBits decoding for each cropped CGImage even
        // with caching enabled. An explicit raw provider shares one decoded buffer.
        guard let bytes = cg.dataProvider?.data,
              CFDataGetLength(bytes) >= cg.bytesPerRow * cg.height,
              let provider = CGDataProvider(data: bytes),
              let decoded = CGImage(width: cg.width, height: cg.height, bitsPerComponent: cg.bitsPerComponent,
                                    bitsPerPixel: cg.bitsPerPixel, bytesPerRow: cg.bytesPerRow,
                                    space: cg.colorSpace ?? space, bitmapInfo: cg.bitmapInfo, provider: provider,
                                    decode: cg.decode, shouldInterpolate: false, intent: cg.renderingIntent) else {
            throw NegativeFailure(key: "negative.error.decode")
        }
        try Task.checkCancellation()
        let filePixels = NegativeFilePixels(cg: decoded, space: space, orientation: orientation)
        let image = filePixels.image
        let preview = try filePixels.preview(context: context)
        try Task.checkCancellation()
        committed = true
        return NegativeAsset(image: image, preview: preview, assumesSRGB: assumed, fileURL: owned, filePixels: filePixels)
    }

    func sample(_ asset: NegativeAsset, point: CGPoint) throws -> NegativeBase {
        try Task.checkCancellation()
        guard let rect = NegativePixels.sampleRect(point: point, extent: asset.image.extent) else { throw NegativeFailure(key: "negative.error.sampleBounds") }
        // Sample the source region at its native precision; crop-local center avoids a second coordinate transform.
        let crop = asset.region(rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return try NegativePixels.sample(crop, point: CGPoint(x: 0.5, y: 0.5), context: context, entireRegion: true)
    }

    func render(_ asset: NegativeAsset, base: NegativeBase) throws -> CGImage {
        try Task.checkCancellation()
        if let pixels = asset.filePixels { return try pixels.preview(base: base, context: context) }
        return try NegativePixels.preview(asset.image, base: base, context: context)
    }

    func export(_ asset: NegativeAsset, base: NegativeBase, format: NegativeFormat) throws -> URL {
        try Task.checkCancellation()
        try checkMemory(width: asset.width, height: asset.height, decoding: false)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Positive-\(UUID().uuidString).\(format.rawValue)")
        do {
            let converted = NegativePixels.positive(asset.image, base: base)
            // A disk-backed raster avoids allocating one giant output bitmap/GPU surface.
            // The encoder reads this immutable provider; 256-row renders bound working tiles.
            try NegativeRaster.write(converted, context: context, format: format, to: output) { rect in
                NegativePixels.positive(asset.region(rect), base: base)
            }
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

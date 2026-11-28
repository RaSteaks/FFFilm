import Foundation
import CoreGraphics

/// Use disk-backed pixels only for an ordinary, contiguous, uncompressed TIFF raster.
/// ImageIO still selects the color profile and orientation. Tiled, compressed, packed,
/// alpha and vendor-specific layouts keep the general ImageIO decoder.
nonisolated enum MappedTIFF {
    static func image(at url: URL, matching image: CGImage, space: CGColorSpace) -> CGImage? {
        guard let mapped = try? NSData(contentsOf: url, options: .alwaysMapped), mapped.length >= 8 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: mapped.bytes, count: mapped.length)
        // Apple platforms are little-endian. Let ImageIO normalize opposite-endian samples;
        // a big-endian bitmap hint alone does not preserve their CI render values.
        guard bytes[0] == 0x49, bytes[1] == 0x49 else { return nil }

        // All offsets belong to the private, immutable import copy. Check ranges before reads.
        func word(_ offset: Int, _ size: Int) -> Int? {
            guard offset >= 0, offset <= bytes.count - size else { return nil }
            var value = 0
            for i in 0..<size {
                value = (value << 8) | Int(bytes[offset + size - i - 1])
            }
            return value
        }
        guard word(2, 2) == 42, let directory = word(4, 4), let count = word(directory, 2),
              directory + 2 + count * 12 + 4 <= bytes.count else { return nil }
        var tags: [Int: Int] = [:]
        for i in 0..<count {
            let field = directory + 2 + i * 12
            guard let tag = word(field, 2), tags.updateValue(field, forKey: tag) == nil else { return nil }
        }
        func values(_ tag: Int, count expected: Int) -> [Int]? {
            guard let field = tags[tag], let type = word(field + 2, 2), type == 3 || type == 4,
                  word(field + 4, 4) == expected else { return nil }
            let size = type == 3 ? 2 : 4
            guard let start = expected * size <= 4 ? field + 8 : word(field + 8, 4),
                  start <= bytes.count - expected * size else { return nil }
            return (0..<expected).compactMap { word(start + $0 * size, size) }
        }
        func scalar(_ tag: Int, default fallback: Int? = nil) -> Int? {
            tags[tag] == nil ? fallback : values(tag, count: 1)?.first
        }
        let width = image.width, height = image.height, depth = image.bitsPerComponent
        guard scalar(256) == width, scalar(257) == height, depth == 8 || depth == 16,
              scalar(259, default: 1) == 1, scalar(284, default: 1) == 1,
              scalar(266, default: 1) == 1, scalar(317, default: 1) == 1,
              tags[320] == nil, tags[324] == nil, tags[338] == nil, tags[301] == nil,
              let channels = scalar(277, default: 1),
              (channels == 3 && scalar(262) == 2 && space.model == .rgb) ||
              (channels == 1 && scalar(262) == 1 && space.model == .monochrome),
              values(258, count: channels) == Array(repeating: depth, count: channels),
              tags[339] == nil || values(339, count: channels) == Array(repeating: 1, count: channels),
              let rows = scalar(278, default: height), rows > 0 else { return nil }
        let strips = (height - 1) / rows + 1
        guard let offsets = values(273, count: strips), let lengths = values(279, count: strips),
              let first = offsets.first else { return nil }
        let rowBytes = width * channels * (depth / 8)
        var end = first
        for i in offsets.indices {
            let length = min(rows, height - i * rows) * rowBytes
            guard offsets[i] == end, lengths[i] == length, end <= bytes.count - length else { return nil }
            end += length
        }
        let owner = Unmanaged.passRetained(mapped)
        guard let provider = CGDataProvider(dataInfo: owner.toOpaque(), data: mapped.bytes.advanced(by: first), size: end - first,
                releaseData: { info, _, _ in if let info { Unmanaged<NSData>.fromOpaque(info).release() } }) else {
            owner.release()
            return nil
        }
        let order: CGBitmapInfo = depth == 16 ? .byteOrder16Little : []
        return CGImage(width: width, height: height, bitsPerComponent: depth, bitsPerPixel: channels * depth,
                       bytesPerRow: rowBytes, space: space, bitmapInfo: order, provider: provider, decode: image.decode,
                       shouldInterpolate: false, intent: image.renderingIntent)
    }
}

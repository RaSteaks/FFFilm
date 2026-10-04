#if os(macOS)
import Foundation
import ImageIO

/// Bounded preview analysis combines physical metadata with paired sprocket evidence.
/// Pixel dimensions or a 3:2 image alone cannot distinguish 135 from a cropped 120 scan.
nonisolated enum FilmScanAnalysis {
    static func layout(width: Int, height: Int, properties: [String: Any],
                       pixels: [UInt8], previewWidth: Int, previewHeight: Int,
                       frames: [FilmRect]) -> FilmLayout {
        let horizontal = width >= height
        let cross = Double(horizontal ? height : width)
        let length = Double(horizontal ? width : height)
        var result = FilmLayout(horizontal: horizontal)
        let physical = physicalSize(properties: properties, width: width, height: height)
        let crossMM = physical.map { horizontal ? $0.height : $0.width }
        let lengthMM = physical.map { horizontal ? $0.width : $0.height }
        let sprockets = hasSprockets(pixels, width: previewWidth, height: previewHeight, horizontal: horizontal)

        // DPI describes the scan's actual size only when both axes are explicitly tagged.
        if let crossMM {
            switch crossMM {
            case 22...38: result.format = .film135
            case 50...66: result.format = .film120
            case 85...550: result.format = .largeFormat
            default: break
            }
        }
        if sprockets { result.format = .film135 }
        if result.format == .film135 {
            let scannedWidth = sprockets ? (crossMM.flatMap { (30...38).contains($0) ? $0 : nil } ?? 35) : crossMM ?? 24
            result.crossSize = min(1, 24 / scannedWidth)
            result.crossOrigin = (1 - result.crossSize) / 2
        } else if result.format == .film120, let crossMM {
            result.crossSize = min(1, 56 / crossMM)
            result.crossOrigin = (1 - result.crossSize) / 2
        }

        // Interior gap intervals avoid a leader/trailer changing the suggested frame size.
        let measuredFrames = frames.count > 2 ? Array(frames.dropFirst().dropLast()) : frames
        let spans = measuredFrames.map { horizontal ? $0.width : $0.height }.sorted()
        if let middle = spans.dropFirst(spans.count / 2).first,
           spans.allSatisfy({ abs($0 - middle) <= middle * 0.18 }),
           (0.55...1.8).contains(middle * length / (cross * result.crossSize)) {
            result.frameLength = middle
        }
        if result.frameLength == nil, let format = result.format {
            if format == .film135, let lengthMM { result.frameLength = min(1, 36 / lengthMM) }
            else { result.frameLength = min(1, cross * result.crossSize / length * format.defaultAspectRatio) }
        }
        return result
    }

    /// EXIF orientation swaps the physical axes along with the source pixels.
    static func physicalSize(properties: [String: Any], width: Int, height: Int) -> CGSize? {
        guard let rawX = properties[kCGImagePropertyDPIWidth as String] as? NSNumber,
              let rawY = properties[kCGImagePropertyDPIHeight as String] as? NSNumber else { return nil }
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let dpiX = (swapsAxes ? rawY : rawX).doubleValue
        let dpiY = (swapsAxes ? rawX : rawY).doubleValue
        guard dpiX.isFinite, dpiY.isFinite, dpiX >= 300, dpiY >= 300 else { return nil }
        return CGSize(width: Double(width) / dpiX * 25.4, height: Double(height) / dpiY * 25.4)
    }

    /// Repeated holes must match on both edges and remain absent from the image center.
    /// Either polarity is accepted for positive scans and negatives on a dark holder.
    static func hasSprockets(_ pixels: [UInt8], width: Int, height: Int, horizontal: Bool) -> Bool {
        let cross = horizontal ? height : width, length = horizontal ? width : height
        guard cross >= 24, length >= 80, pixels.count == width * height * 4 else { return false }
        func signal(_ lower: Double, _ upper: Double) -> [Double] {
            (0..<length).map { position in
                let start = Int(Double(cross) * lower), end = Int(Double(cross) * upper)
                var sum = 0.0
                for j in start..<max(start + 1, end) {
                    let offset = horizontal ? (j * width + position) * 4 : (position * width + j) * 4
                    sum += (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / 3
                }
                return sum / Double(max(1, end - start))
            }
        }
        let first = signal(0.045, 0.13), last = signal(0.87, 0.955), center = signal(0.4, 0.6)
        guard let low = first.min(), let high = first.max(), high - low > 45 else { return false }
        for bright in [true, false] {
            let threshold = bright ? high - (high - low) * 0.25 : low + (high - low) * 0.25
            func isHole(_ value: Double) -> Bool { bright ? value >= threshold : value <= threshold }
            var runs: [(start: Int, end: Int)] = [], start: Int?
            for i in 0...length {
                if i < length, isHole(first[i]), isHole(last[i]), abs(center[i] - first[i]) > 25 {
                    if start == nil { start = i }
                } else if let beginning = start {
                    if i - beginning >= 2 { runs.append((beginning, i)) }
                    start = nil
                }
            }
            guard runs.count >= 5 else { continue }
            let centers = runs.map { Double($0.start + $0.end) / 2 }
            let distances = zip(centers, centers.dropFirst()).map { $1 - $0 }.sorted()
            let pitch = distances[distances.count / 2]
            // 35 mm stock has ~4.75 mm perforation pitch; require consistent repetition.
            let ratio = pitch / Double(cross)
            if (0.105...0.18).contains(ratio),
               distances.allSatisfy({ abs($0 - pitch) < pitch * 0.2 }),
               runs.allSatisfy({ (0.15...0.65).contains(Double($0.end - $0.start) / pitch) }) {
                return true
            }
        }
        return false
    }
}
#endif

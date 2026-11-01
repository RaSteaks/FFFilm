#if os(macOS)
import Foundation
import simd

/// Linear-light samples remain separate from the 8-bit display/gap-classification path.
nonisolated struct FilmBaseSample: Equatable, Sendable {
    var position: Double
    var color: SIMD3<Double>
    var noise: SIMD3<Double>

    static func estimate(_ colors: [SIMD3<Double>], position: Double) -> FilmBaseSample? {
        let usable = colors.filter { color in
            (0..<3).allSatisfy { color[$0].isFinite && color[$0] > 0.00001 && color[$0] < 0.995 }
        }
        guard usable.count >= 16, usable.count * 10 >= colors.count * 9 else { return nil }
        var center = SIMD3<Double>(), noise = SIMD3<Double>()
        for channel in 0..<3 {
            let values = usable.map { $0[channel] }.sorted()
            center[channel] = values[values.count / 2]
            let deviations = values.map { abs($0 - center[channel]) }.sorted()
            noise[channel] = max(0.0001, deviations[deviations.count / 2] * 1.4826)
            // Text, perforations and scene detail are not stable base samples.
            guard values[values.count * 9 / 10] - values[values.count / 10]
                    <= max(0.004, center[channel] * 0.15) else { return nil }
        }
        return FilmBaseSample(position: position, color: center, noise: noise)
    }

    static func linear(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>((0..<3).map {
            let value = encoded[$0] / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        })
    }

    var encoded: SIMD3<Double> {
        SIMD3<Double>((0..<3).map {
            let value = color[$0]
            return 255 * (value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055)
        })
    }
}

nonisolated struct FilmBaseModel: Sendable {
    var samples: [FilmBaseSample]

    func sample(at position: Double, fallback: SIMD3<Double>) -> FilmBaseSample {
        guard let first = samples.first else {
            return FilmBaseSample(position: position, color: FilmBaseSample.linear(fallback), noise: SIMD3(repeating: 0.001))
        }
        guard position > first.position else { return first }
        for (left, right) in zip(samples, samples.dropFirst()) where position <= right.position {
            let amount = (position - left.position) / max(0.000001, right.position - left.position)
            return FilmBaseSample(position: position, color: left.color + (right.color - left.color) * amount,
                                  noise: left.noise + (right.noise - left.noise) * amount)
        }
        return samples.last!
    }
}

nonisolated struct FilmDetectionOptions: Equatable, Sendable {
    var base: FilmBaseSample?
    var calibration: FilmRect?
    var calibrationAngle = 0.0
}

nonisolated struct FilmDetectionProgress: Sendable {
    nonisolated enum Phase: Sendable { case segments, base, edges }
    var phase: Phase
    var completed: Int
    var total: Int
}

nonisolated struct FilmPixelRegion: Sendable {
    var rect: FilmRect
    var width: Int
    var height: Int
    var colors: [SIMD3<Double>]
}

nonisolated enum FilmEdgeRefinement {
    struct Boundary: Sendable {
        var position: Double
        var evidence: FilmEdgeEvidence
        var inwardLimit: Double? = nil
    }

    /// Fit the frame aperture, not scene contours: every ray must start in matching film base.
    /// A fitted line is extrapolated to both corners; its outer envelope preserves tilted images.
    static func boundary(in region: FilmPixelRegion, edge: FilmCropEdge, base: FilmBaseSample, scannerBackground: Bool = false) -> Boundary? {
        let vertical = edge == .left || edge == .right
        let lower = edge == .left || edge == .top
        let alongCount = vertical ? region.width : region.height
        let crossCount = vertical ? region.height : region.width
        guard alongCount >= 6, crossCount >= 3 else { return nil }
        func color(_ along: Int, _ cross: Int) -> SIMD3<Double> {
            region.colors[vertical ? cross * region.width + along : along * region.width + cross]
        }
        func distance(_ value: SIMD3<Double>, from reference: SIMD3<Double>, noise: SIMD3<Double>) -> Double {
            (0..<3).map { abs(value[$0] - reference[$0]) / max(0.002, noise[$0] * 4, reference[$0] * 0.018) }.max()!
        }
        var points: [SIMD2<Double>] = []
        for ray in 0..<17 {
            let fraction = 0.08 + 0.84 * (Double(ray) + 0.5) / 17
            let cross = min(crossCount - 1, Int(Double(crossCount) * fraction))
            var outside: [SIMD3<Double>] = []
            var baseStart: Int?
            // Limited holder skipping must still find a sustained, color-compatible base plateau.
            for step in 0..<min(alongCount / 3, 64) {
                let value = color(lower ? step : alongCount - 1 - step, cross)
                let compatible = (0..<3).allSatisfy {
                    abs(value[$0] - base.color[$0]) <= max(0.008, base.color[$0] * 0.18, base.noise[$0] * 6)
                }
                if compatible {
                    if baseStart == nil { baseStart = step }
                    outside.append(value)
                    if outside.count == 4 { break }
                } else { outside.removeAll(); baseStart = nil }
            }
            guard outside.count == 4, let start = baseStart else { continue }
            var local = SIMD3<Double>()
            for channel in 0..<3 { local[channel] = outside.map { $0[channel] }.sorted()[2] }
            if scannerBackground {
                // Scanner masks often have a faint halo before the actual aperture. Fit the
                // sustained black-to-image step, not the first few nonzero noise values.
                let line = (0..<alongCount).map { color(lower ? $0 : alongCount - 1 - $0, cross) }
                var sums = [SIMD3<Double>(repeating: 0)]
                sums.reserveCapacity(alongCount + 1)
                for value in line { sums.append(sums.last! + value) }
                let window = max(2, min(16, alongCount / 32))
                guard start + 4 + window < alongCount - window else { continue }
                var bestStep = 0, bestChannel = 0, strength = 0.0, plateau = 0.0
                for step in (start + 4 + window)..<(alongCount - window) {
                    let before = (sums[step] - sums[step - window]) / Double(window)
                    let after = (sums[step + window] - sums[step]) / Double(window)
                    for channel in 0..<3 where after[channel] - before[channel] > strength {
                        strength = after[channel] - before[channel]
                        bestStep = step; bestChannel = channel; plateau = after[channel]
                    }
                }
                guard strength >= 0.01 else { continue }
                let threshold = local[bestChannel] + (plateau - local[bestChannel]) * 0.1
                let beginning = max(start + 4, bestStep - window * 2)
                var changed = 0
                // Even a two-pixel averaging window needs three post-edge samples to
                // confirm a sharp transition; otherwise clean masks fall back to coarse bounds.
                for step in beginning..<min(alongCount, bestStep + window + 2) {
                    changed = line[step][bestChannel] > threshold ? changed + 1 : 0
                    if changed == 3 {
                        let offset = step - 2
                        points.append(SIMD2(fraction, lower ? Double(offset) : Double(alongCount - offset)))
                        break
                    }
                }
                continue
            }
            var changed = 0
            for step in (start + 4)..<alongCount {
                let value = color(lower ? step : alongCount - 1 - step, cross)
                if distance(value, from: local, noise: base.noise) > 1 {
                    changed += 1
                    if changed == 3 {
                        let offset = step - 2
                        let position = lower ? Double(offset) : Double(alongCount - offset)
                        points.append(SIMD2(fraction, position))
                        break
                    }
                } else { changed = 0 }
            }
        }
        guard points.count >= 13 else { return nil }
        func line(_ points: [SIMD2<Double>]) -> (slope: Double, intercept: Double) {
            let center = points.reduce(SIMD2<Double>(repeating: 0), +) / Double(points.count)
            let numerator = points.reduce(0) { $0 + ($1.x - center.x) * ($1.y - center.y) }
            let denominator = points.reduce(0) { $0 + pow($1.x - center.x, 2) }
            let slope = denominator > 0 ? numerator / denominator : 0
            return (slope, center.y - slope * center.x)
        }
        let initial = line(points)
        let residuals = points.map { abs($0.y - initial.intercept - initial.slope * $0.x) }.sorted()
        let tolerance = max(1.5, residuals[residuals.count / 2] * 3)
        let supported = points.filter { abs($0.y - initial.intercept - initial.slope * $0.x) <= tolerance }
        guard supported.count >= 13 else { return nil }
        let fitted = line(supported)
        let error = supported.map { abs($0.y - fitted.intercept - fitted.slope * $0.x) }.max()! + 1
        // Large residuals indicate scene contours or a curved/ambiguous border; do not trim them.
        guard error <= max(3, Double(alongCount) * 0.04) else { return nil }
        let end = fitted.intercept + fitted.slope
        let fittedBound = lower ? min(fitted.intercept, end) - error : max(fitted.intercept, end) + error
        let bound: Double
        if scannerBackground {
            // On a scanner surround, an early transition may be real protruding image
            // content. Keep it even if the straight-line fit treats it as an outlier.
            bound = lower ? min(fittedBound, points.map(\.y).min()! - 1)
                : max(fittedBound, points.map(\.y).max()! + 1)
        } else { bound = fittedBound }
        guard bound > 0, bound < Double(alongCount) else { return nil }
        let origin = vertical ? region.rect.x : region.rect.y
        let extent = vertical ? region.rect.width : region.rect.height
        let inner = lower ? max(fitted.intercept, end) + error : min(fitted.intercept, end) - error
        return Boundary(position: origin + extent * bound / Double(alongCount), evidence: .reliable,
                        inwardLimit: scannerBackground ? origin + extent * inner / Double(alongCount) : nil)
    }
}
#endif

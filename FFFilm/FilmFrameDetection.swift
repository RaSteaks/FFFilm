#if os(macOS)
import Foundation
import simd

/// Finds film-base bands in bounded, top-left RGBA previews without altering source pixels.
/// Color, transverse texture and two-sided transitions retain evidence lost by a luminance average.
nonisolated enum FilmFrameDetection {
    private typealias Color = SIMD3<Double>
    private struct Row {
        var lanes: [Color]
        var color: Color
        var texture: Double
    }
    private struct Gap {
        var center: Int
        var color: Color
        var quality: Double
        var edgeSupport: Double
    }

    static func frames(pixels: [UInt8], width: Int, height: Int) -> [FilmRect] {
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, area <= Int.max / 4,
              pixels.count == area * 4 else { return [] }
        let horizontal = width >= height
        let length = horizontal ? width : height, cross = horizontal ? height : width
        guard length > 10, cross > 4 else { return [] }
        func pixel(_ position: Int, _ transverse: Int) -> Color {
            let offset = horizontal ? (transverse * width + position) * 4 : (position * width + transverse) * 4
            return Color(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
        }

        // Seven independent bands cover the image area, leaving edge markings and sprockets out.
        // Medians of five samples tolerate isolated dust without scanning every preview pixel.
        let rows: [Row] = (0..<length).map { position in
            var lanes: [Color] = [], textures: [Double] = []
            for lane in 0..<7 {
                let samples = (0..<5).map { sample in
                    let fraction = 0.2 + 0.6 * (Double(lane) + (Double(sample) + 0.5) / 5) / 7
                    return pixel(position, min(cross - 1, Int(Double(cross) * fraction)))
                }
                let color = median(samples)
                lanes.append(color)
                textures.append(percentile(samples.map { difference($0, color) }, 0.75))
            }
            let color = median(lanes)
            let spread = percentile(lanes.map { difference($0, color) }, 0.8)
            return Row(lanes: lanes, color: color, texture: max(spread, percentile(textures, 0.7)))
        }
        // Adapt to scan grain, but cap tolerance so textured scenes cannot teach us to ignore texture.
        let noise = min(10, max(3, percentile(rows.map(\.texture), 0.15) * 1.5 + 2))
        let colorTolerance = noise * 1.75
        let sceneColor = median(rows.map(\.color))
        var marginColor: Color?
        // Prefer the innermost stable pair of margins. An outer black scanner holder must
        // not make black objects inside a negative look more convincing than the orange base.
        for fraction in [0.04, 0.09, 0.14] {
            let first = (0..<24).map { pixel(min(length - 1, (2 * $0 + 1) * length / 48), Int(Double(cross) * fraction)) }
            let last = (0..<24).map { pixel(min(length - 1, (2 * $0 + 1) * length / 48), min(cross - 1, Int(Double(cross) * (1 - fraction)))) }
            let firstColor = median(first), lastColor = median(last)
            let color = (firstColor + lastColor) / 2
            if difference(firstColor, lastColor) <= colorTolerance,
               difference(color, sceneColor) > max(6, noise),
               first.filter({ difference($0, firstColor) <= colorTolerance }).count >= 20,
               last.filter({ difference($0, lastColor) <= colorTolerance }).count >= 20 {
                marginColor = color
            }
        }
        let minimumWidth = max(2, length / 900)
        let maximumWidth = min(length / 8, max(12, Int(Double(cross) * 0.18)))
        let flankWidth = max(3, min(12, cross / 30))
        let minimumFrame = max(6, Int(Double(cross) * 0.35))
        var gaps: [Gap] = []
        var index = 0
        while index < length {
            guard rows[index].texture <= noise else { index += 1; continue }
            let start = index, reference = rows[index].color
            // Use the candidate's own noise floor for color changes. Texture elsewhere in the
            // scene must not merge a faint, clean base band into its neighboring frame.
            let localTolerance = min(colorTolerance, max(4, rows[start].texture * 1.5 + 3))
            var goodRows = 0
            func matches(_ position: Int) -> Bool {
                position < length && rows[position].texture <= noise
                    && difference(rows[position].color, reference) <= localTolerance
            }
            while index < length {
                if matches(index) { goodRows += 1; index += 1 }
                // Bridge one damaged scan line only when the same base color resumes immediately.
                else if matches(index + 1) { index += 1 }
                else { break }
            }
            let end = index, span = end - start
            guard goodRows >= minimumWidth, span <= maximumWidth,
                  start >= minimumFrame, end <= length - minimumFrame else { continue }
            let color = median(rows[start..<end].map(\.color))
            let minimumContrast = max(6, percentile(rows[start..<end].map(\.texture), 0.5) * 2 + 3)
            var contrasts: [Double] = []
            for lane in 0..<7 {
                let before = median(rows[(start - flankWidth)..<start].map { $0.lanes[lane] })
                let after = median(rows[end..<(end + flankWidth)].map { $0.lanes[lane] })
                let left = color - before, right = color - after
                let contrast = min(difference(color, before), difference(color, after))
                // Different scenes may change different RGB channels relative to the same base.
                // Reject significant reversals within a channel (an intermediate scene color),
                // rather than requiring the two scene-to-base vectors to have similar hues.
                let reversesChannel = (0..<3).contains { channel in
                    min(left[channel], right[channel]) < -minimumContrast
                        && max(left[channel], right[channel]) > minimumContrast
                }
                if contrast >= minimumContrast, !reversesChannel {
                    contrasts.append(contrast)
                }
            }
            guard contrasts.count >= 6 else { continue }
            let contrast = percentile(contrasts, 0.5)
            let quality = Double(contrasts.count) / 7 * (0.5 + 0.5 * min(1, contrast / 24))
                * (1 - 0.5 * Double(span) / Double(maximumWidth))
            // Persistent matching color on BOTH film margins helps distinguish base from sky/shadows.
            // It is supporting evidence only: tightly cropped scans may have no visible margins.
            let support = marginColor.map { max(0, 1 - difference($0, color) / colorTolerance) } ?? 0
            gaps.append(Gap(center: (start + end) / 2, color: color, quality: quality,
                            edgeSupport: support))
        }
        guard !gaps.isEmpty else { return [] }

        // Learn one base color from compatible gaps; never mix unrelated dark and bright scene bands.
        // Repetition has a capped bonus, so numerous weak scene candidates cannot win by count alone.
        let baseTolerance = max(14, noise * 2.5)
        let separation = max(8, Int(Double(cross) * 0.45))
        var best: [Gap] = [], bestScore = 0.0
        var bestCorroborated = false
        for seed in gaps {
            let compatible = gaps.filter { difference($0.color, seed.color) <= baseTolerance }
                .sorted { $0.quality > $1.quality }
            var group: [Gap] = []
            for gap in compatible where group.allSatisfy({ abs($0.center - gap.center) >= separation }) {
                group.append(gap)
            }
            let quality = group.map(\.quality).reduce(0, +) / Double(group.count)
            let support = group.map(\.edgeSupport).reduce(0, +) / Double(group.count)
            guard quality >= 0.5 else { continue }
            // Independent matching gaps or matching film margins corroborate a base color.
            // An isolated, unsupported scene stripe remains a fallback even if its narrow
            // width gives it a higher local score. Groups must pass the quality floor above;
            // additional repeats beyond the second do not raise this priority.
            let corroborated = group.count > 1 || support >= 0.5
            let score = quality + 0.45 * support + (group.count > 1 ? 0.15 : 0)
            if (corroborated && !bestCorroborated) || (corroborated == bestCorroborated && score > bestScore) {
                best = group; bestScore = score; bestCorroborated = corroborated
            }
        }
        guard !best.isEmpty else { return [] }
        // Preserve the existing conservative crop convention: split at gap centers, keeping edge pixels.
        let boundaries = [0] + best.map(\.center).sorted() + [length]
        return zip(boundaries, boundaries.dropFirst()).map { start, end in
            let origin = Double(start) / Double(length), size = Double(end - start) / Double(length)
            return horizontal ? FilmRect(x: origin, y: 0, width: size, height: 1)
                : FilmRect(x: 0, y: origin, width: 1, height: size)
        }
    }

    private static func difference(_ lhs: Color, _ rhs: Color) -> Double {
        simd_distance(lhs, rhs) / sqrt(3)
    }

    private static func median(_ colors: [Color]) -> Color {
        Color(percentile(colors.map(\.x), 0.5), percentile(colors.map(\.y), 0.5), percentile(colors.map(\.z), 0.5))
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}
#endif

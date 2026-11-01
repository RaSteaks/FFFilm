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
        var start: Int
        var end: Int
        var center: Int { (start + end) / 2 }
        var color: Color
        var quality: Double
        var edgeSupport: Double
        var strong: Bool
    }

    /// Compatibility entry point: callers measuring pitch still receive gap-center intervals.
    static func frames(pixels: [UInt8], width: Int, height: Int) -> [FilmRect] {
        analyze(pixels: pixels, width: width, height: height).splitFrames
    }

    static func analyze(pixels: [UInt8], width: Int, height: Int) -> FilmDetectionResult {
        var performance = FilmPerformance()
        return analyze(pixels: pixels, width: width, height: height, performance: &performance)
    }

    static func analyze(pixels: [UInt8], width: Int, height: Int,
                        performance: inout FilmPerformance, baseColor: SIMD3<Double>? = nil) -> FilmDetectionResult {
        let started = ContinuousClock.now
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, area <= Int.max / 4,
              pixels.count == area * 4 else { return FilmDetectionResult() }
        let horizontal = width >= height
        let length = horizontal ? width : height, cross = horizontal ? height : width
        guard length > 10, cross > 4 else { return FilmDetectionResult() }
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
        var marginColor: Color? = baseColor
        // Prefer the innermost stable pair of margins. An outer black scanner holder must
        // not make black objects inside a negative look more convincing than the orange base.
        for fraction in [0.04, 0.09, 0.14] where baseColor == nil {
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
            guard contrasts.count >= 3 else { continue }
            let contrast = percentile(contrasts, 0.5)
            let quality = Double(contrasts.count) / 7 * (0.5 + 0.5 * min(1, contrast / 24))
                * (1 - 0.5 * Double(span) / Double(maximumWidth))
            // Persistent matching color on BOTH film margins helps distinguish base from sky/shadows.
            // It is supporting evidence only: tightly cropped scans may have no visible margins.
            let support = marginColor.map { max(0, 1 - difference($0, color) / colorTolerance) } ?? 0
            gaps.append(Gap(start: start, end: end, color: color, quality: quality,
                            edgeSupport: support, strong: contrasts.count >= 6))
        }

        // Learn one base color from compatible gaps; never mix unrelated dark and bright scene bands.
        // Repetition has a capped bonus, so numerous weak scene candidates cannot win by count alone.
        let baseTolerance = max(14, noise * 2.5)
        // Use the same minimum frame extent as candidate eligibility. A stricter second
        // cutoff discards alternating valid frames after aspect-preserving resampling.
        let separation = max(8, minimumFrame)
        var best: [Gap] = [], bestScore = 0.0
        var bestCorroborated = false
        for seed in gaps where seed.strong {
            if let baseColor, difference(seed.color, baseColor) > baseTolerance { continue }
            let compatible = gaps.filter { $0.strong && difference($0.color, seed.color) <= baseTolerance }
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
        // Underexposed image edges may match the base in most lanes. Admit weaker
        // transitions only when three compatible bands independently establish a regular pitch.
        // Irregular/short strips keep the original strong-evidence path.
        var selected = best.sorted { $0.center < $1.center }
        let seeds = best.first.map { [$0.color] } ?? baseColor.map { [$0] } ?? gaps.map(\.color)
        var supportedScore = -Double.infinity
        for seed in seeds {
            let compatible = gaps.filter { difference($0.color, seed) <= baseTolerance }.sorted { $0.center < $1.center }
            guard regularPitch(compatible, cross: cross) != nil else { continue }
            let score = compatible.map { $0.quality + 0.45 * $0.edgeSupport }.reduce(0, +) / Double(compatible.count)
            if score > supportedScore { selected = compatible; supportedScore = score }
        }
        var normalizedGaps = selected.map {
            FilmDetectedGap(start: Double($0.start) / Double(length), end: Double($0.end) / Double(length),
                            color: $0.color, corroborated: selected.count > 1 || $0.edgeSupport >= 0.5,
                            inferred: !$0.strong)
        }
        if let pitch = regularPitch(selected, cross: cross), let first = selected.first {
            let phase = Double(first.center).truncatingRemainder(dividingBy: pitch)
            let tailError = abs(Double(length) - (phase + ((Double(length) - phase) / pitch).rounded() * pitch))
            // Extrapolation needs BOTH scan ends to agree with the measured lattice. This
            // prevents extending a short run of scene stripes across a leader or mixed-format strip.
            if min(phase, pitch - phase) <= pitch * 0.12, tailError <= pitch * 0.12 {
                let halfWidth = max(1, percentile(selected.map { Double($0.end - $0.start) }, 0.5) / 2)
                let base = median(selected.map(\.color))
                for center in stride(from: phase + pitch, to: Double(length) - pitch * 0.5, by: pitch) {
                    guard selected.allSatisfy({ abs(Double($0.center) - center) > pitch * 0.2 }) else { continue }
                    let start = max(0, Int((center - halfWidth).rounded()))
                    let end = min(length, Int((center + halfWidth).rounded()))
                    let matching = rows[start..<end].filter { $0.texture <= noise && difference($0.color, base) <= colorTolerance }.count
                    guard matching * 4 >= (end - start) * 3 else { continue }
                    let neighbors = [(center - pitch * 0.85, center - pitch * 0.15),
                                     (center + pitch * 0.15, center + pitch * 0.85)]
                    // A base-colored leader/trailer is not evidence of another photograph.
                    // Require some image information inside each adjacent frame, away from its edges.
                    guard neighbors.allSatisfy({ lower, upper in
                        let lo = max(0, Int(lower)), hi = min(length, Int(upper))
                        guard hi > lo else { return false }
                        let imageRows = rows[lo..<hi].filter {
                            // A small subject can disappear in the row median of an otherwise
                            // nearly transparent exposure, but survive in an individual robust lane.
                            $0.texture > noise || $0.lanes.contains { difference($0, base) > colorTolerance }
                        }.count
                        return imageRows >= max(3, (hi - lo) / 30)
                    }) else { continue }
                    normalizedGaps.append(FilmDetectedGap(start: Double(start) / Double(length), end: Double(end) / Double(length),
                        color: base, corroborated: true, inferred: true))
                }
                normalizedGaps.sort { $0.center < $1.center }
            }
        }
        performance.record(.coarseDetection, since: started)
        let boundaryStart = ContinuousClock.now
        let result = assemble(gaps: normalizedGaps, marginColor: marginColor, tolerance: colorTolerance,
                              pixels: pixels, width: width, height: height)
        performance.record(.boundaries, since: boundaryStart)
        return result
    }

    /// Segment analysis contributes gaps only; tile ends must never become artificial cuts.
    static func assemble(gaps: [FilmDetectedGap], marginColor: SIMD3<Double>?, tolerance: Double = 6,
                         pixels: [UInt8], width: Int, height: Int) -> FilmDetectionResult {
        let horizontal = width >= height
        let boundaries = [0.0] + gaps.map(\.center) + [1.0]
        let slots = zip(boundaries, boundaries.dropFirst()).map { start, end in
            horizontal ? FilmRect(x: start, y: 0, width: end - start, height: 1)
                : FilmRect(x: 0, y: start, width: 1, height: end - start)
        }
        let background = scannerBackground(pixels: pixels, width: width, height: height, horizontal: horizontal)
        let scannerBounds = background.map {
            scannerAperture(background: $0, pixels: pixels, width: width, height: height, horizontal: horizontal)
        }
        var candidates: [FilmFrameCandidate] = []
        for (index, slot) in slots.enumerated() where slot.valid {
            let neighbors = [index - 1, index].filter { gaps.indices.contains($0) }.map { gaps[$0].color }
            guard let base = neighbors.isEmpty ? marginColor : median(neighbors) else { continue }
            var candidate = fit(slot: slot, base: base, tolerance: tolerance,
                                pixels: pixels, width: width, height: height)
            if let background, let scannerBounds, difference(background, base) > 20 {
                let localBounds = fit(slot: slot, base: background, tolerance: 3,
                                      pixels: pixels, width: width, height: height)
                for edge in FilmCropEdge.allCases {
                    let atSourceEdge: Bool
                    switch edge {
                    case .left: atSourceEdge = slot.x == 0
                    case .right: atSourceEdge = abs(slot.x + slot.width - 1) < 0.000001
                    case .top: atSourceEdge = slot.y == 0
                    case .bottom: atSourceEdge = abs(slot.y + slot.height - 1) < 0.000001
                    }
                    guard atSourceEdge else { continue }
                    candidate.scannerEdges.insert(edge)
                    // Shared transverse evidence prevents a dark object touching one frame's
                    // edge from becoming that frame's aperture. Head/tail searches stay local.
                    let transverse = (edge == .left || edge == .right) != horizontal
                    let bounds = transverse ? scannerBounds : localBounds
                    candidate.scannerLimits[edge] = bounds.scannerLimits[edge]
                    guard bounds.edges[edge] != .insufficient else { continue }
                    let delta: Double
                    switch edge {
                    case .left: delta = bounds.crop.x - candidate.crop.x
                    case .right: delta = bounds.crop.x + bounds.crop.width - candidate.crop.x - candidate.crop.width
                    case .top: delta = bounds.crop.y - candidate.crop.y
                    case .bottom: delta = bounds.crop.y + bounds.crop.height - candidate.crop.y - candidate.crop.height
                    }
                    candidate.crop = candidate.crop.resizing(edge, by: delta)
                    candidate.edges[edge] = bounds.edges[edge]
                }
            }
            var lower = horizontal ? candidate.crop.x : candidate.crop.y
            var upper = horizontal ? candidate.crop.x + candidate.crop.width : candidate.crop.y + candidate.crop.height
            if index > 0, gaps[index - 1].inferred {
                lower = gaps[index - 1].start
                candidate.edges[horizontal ? .left : .top] = .inferred
            }
            if index < gaps.count, gaps[index].inferred {
                upper = gaps[index].end
                candidate.edges[horizontal ? .right : .bottom] = .inferred
            }
            // Retain the entire uncertain band on BOTH frames rather than erasing faint image
            // content. The transport slots remain non-overlapping for pitch and ordering.
            if horizontal { candidate.crop.x = lower; candidate.crop.width = upper - lower }
            else { candidate.crop.y = lower; candidate.crop.height = upper - lower }
            // A single frame needs a complete aperture, not just a scene stripe.
            if !gaps.isEmpty || candidate.edges.values.allSatisfy({ $0 != .insufficient }) {
                candidates.append(candidate)
            }
        }
        return FilmDetectionResult(gaps: gaps, splitFrames: gaps.isEmpty ? [] : slots, candidates: candidates, scannerBackground: background)
    }

    /// Look inward from a known base boundary, requiring independent rays to agree.
    /// The outermost supported transition preserves corners of slightly slanted frames.
    static func fit(slot: FilmRect, base: SIMD3<Double>, tolerance: Double,
                    pixels: [UInt8], width: Int, height: Int, minimumRays: Int = 8) -> FilmFrameCandidate {
        let x0 = Int((slot.x * Double(width)).rounded()), y0 = Int((slot.y * Double(height)).rounded())
        let x1 = min(width, Int(((slot.x + slot.width) * Double(width)).rounded()))
        let y1 = min(height, Int(((slot.y + slot.height) * Double(height)).rounded()))
        var crop = slot
        var edges: [FilmCropEdge: FilmEdgeEvidence] = [:]
        for edge in FilmCropEdge.allCases {
            let vertical = edge == .left || edge == .right
            let lower = edge == .left || edge == .top
            let span = vertical ? x1 - x0 : y1 - y0
            let across = vertical ? y1 - y0 : x1 - x0
            let limit = max(0, Int(Double(span) * 0.24))
            var offsets: [Int] = []
            for ray in 0..<9 {
                let cross = Int(Double(across) * (0.2 + 0.6 * (Double(ray) + 0.5) / 9))
                var baseRun = 0, changedRun = 0
                for step in 0..<limit {
                    let along = lower ? step : span - 1 - step
                    let x = x0 + (vertical ? along : cross), y = y0 + (vertical ? cross : along)
                    let offset = (y * width + x) * 4
                    let color = Color(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
                    if difference(color, base) <= tolerance {
                        if changedRun > 0 { break }
                        baseRun += 1
                    } else {
                        changedRun += 1
                        if changedRun == 3 {
                            if baseRun >= 2 { offsets.append(baseRun) }
                            break
                        }
                    }
                }
            }
            guard offsets.count >= minimumRays, let inset = offsets.min(), inset > 0 else {
                edges[edge] = .insufficient
                continue
            }
            let spread = (offsets.max() ?? inset) - inset
            edges[edge] = spread > 1 ? .needsRefinement : .reliable
            // Central rays do not reach the corners. Expand a slanted coarse boundary until
            // source-precision line fitting can establish its complete outer envelope.
            let conservativeInset = max(0, inset - Int(ceil(Double(spread) / 3)))
            let normalized = Double(conservativeInset) / Double(vertical ? width : height)
            switch edge {
            case .left: crop.x += normalized; crop.width -= normalized
            case .right: crop.width -= normalized
            case .top: crop.y += normalized; crop.height -= normalized
            case .bottom: crop.height -= normalized
            }
        }
        return FilmFrameCandidate(slot: slot, crop: crop.valid ? crop : slot, base: base, edges: edges)
    }

    /// A scanner surround is paired, stable and connected to the SOURCE perimeter.
    /// Interior dark objects never seed this model; dark film base keeps its existing path.
    private static func scannerBackground(pixels: [UInt8], width: Int, height: Int,
                                          horizontal: Bool) -> Color? {
        let length = horizontal ? width : height, cross = horizontal ? height : width
        guard cross >= 16, length >= 32 else { return nil }
        func pixel(_ along: Int, _ across: Int) -> Color {
            let index = (horizontal ? across * width + along : along * width + across) * 4
            return Color(Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2]))
        }
        let positions = (0..<24).map { min(length - 1, (2 * $0 + 1) * length / 48) }
        let band = max(1, min(3, cross / 100))
        let first = positions.flatMap { position in (0..<band).map { pixel(position, $0) } }
        let last = positions.flatMap { position in (0..<band).map { pixel(position, cross - 1 - $0) } }
        let color = median(first + last)
        guard max(color.x, color.y, color.z) <= 16,
              first.filter({ difference($0, color) <= 3 }).count * 10 >= first.count * 9,
              last.filter({ difference($0, color) <= 3 }).count * 10 >= last.count * 9,
              positions.filter({ difference(pixel($0, cross / 2), color) > 20 }).count >= 6 else { return nil }
        return color
    }

    /// Sparse global rays establish the common aperture without converting the full preview
    /// to floats. Use the same step detector as source refinement so low-level scanner halos
    /// do not enlarge the shared bound and block a valid per-frame refinement.
    private static func scannerAperture(background: Color, pixels: [UInt8], width: Int, height: Int,
                                        horizontal: Bool) -> FilmFrameCandidate {
        var bounds = fit(slot: FilmRect(), base: background, tolerance: 3,
                         pixels: pixels, width: width, height: height, minimumRays: 6)
        let length = horizontal ? width : height, cross = horizontal ? height : width
        let band = max(1, Int(Double(cross) * 0.24)), samples = min(length, 129)
        let base = FilmBaseSample(position: 0, color: FilmBaseSample.linear(background), noise: SIMD3(repeating: 0.0001))
        let edges: [FilmCropEdge] = horizontal ? [.top, .bottom] : [.left, .right]
        for edge in edges {
            let vertical = edge == .left || edge == .right
            let lower = edge == .left || edge == .top
            let start = lower ? 0 : cross - band
            let regionWidth = vertical ? band : samples, regionHeight = vertical ? samples : band
            var colors: [Color] = []
            colors.reserveCapacity(regionWidth * regionHeight)
            for y in 0..<regionHeight {
                for x in 0..<regionWidth {
                    let along = min(length - 1, Int((Double(vertical ? y : x) + 0.5) * Double(length) / Double(samples)))
                    let across = start + (vertical ? x : y)
                    let offset = (horizontal ? across * width + along : along * width + across) * 4
                    let encoded = Color(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
                    colors.append(FilmBaseSample.linear(encoded))
                }
            }
            let rect = vertical ? FilmRect(x: Double(start) / Double(width), width: Double(band) / Double(width))
                : FilmRect(y: Double(start) / Double(height), height: Double(band) / Double(height))
            let region = FilmPixelRegion(rect: rect, width: regionWidth, height: regionHeight, colors: colors)
            guard let found = FilmEdgeRefinement.boundary(in: region, edge: edge, base: base, scannerBackground: true) else { continue }
            let delta: Double
            switch edge {
            case .left: delta = found.position - bounds.crop.x
            case .right: delta = found.position - bounds.crop.x - bounds.crop.width
            case .top: delta = found.position - bounds.crop.y
            case .bottom: delta = found.position - bounds.crop.y - bounds.crop.height
            }
            bounds.crop = bounds.crop.resizing(edge, by: delta)
            bounds.edges[edge] = found.evidence
            bounds.scannerLimits[edge] = found.inwardLimit
        }
        return bounds
    }

    private static func regularPitch(_ gaps: [Gap], cross: Int) -> Double? {
        guard gaps.count >= 3 else { return nil }
        let distances = zip(gaps, gaps.dropFirst()).map { Double($1.center - $0.center) }
        let pitch = percentile(distances, 0.5)
        guard (0.55...1.8).contains(pitch / Double(cross)),
              distances.allSatisfy({ abs($0 - pitch) <= pitch * 0.08 }) else { return nil }
        return pitch
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

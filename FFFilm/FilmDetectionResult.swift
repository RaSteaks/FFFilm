#if os(macOS)
import Foundation

nonisolated enum FilmEdgeEvidence: String, Sendable {
    case reliable, needsRefinement, insufficient
    /// A transport estimate inside indistinguishable base/image pixels must not be tightened.
    case inferred
}

nonisolated struct FilmDetectedGap: Equatable, Sendable {
    /// Along-strip coordinates, normalized to the oriented source.
    var start: Double
    var end: Double
    var color: SIMD3<Double>
    var corroborated = false
    var inferred = false
    var center: Double { (start + end) / 2 }
}

nonisolated struct FilmFrameCandidate: Equatable, Sendable {
    var slot: FilmRect
    var crop: FilmRect
    var base: SIMD3<Double>
    var edges: [FilmCropEdge: FilmEdgeEvidence]
    var scannerEdges: Set<FilmCropEdge> = []
    /// Inner limit supported by independent rays across the strip, not a crop target.
    var scannerLimits: [FilmCropEdge: Double] = [:]
}

nonisolated struct FilmDetectionResult: Equatable, Sendable {
    var gaps: [FilmDetectedGap] = []
    /// Gap-center intervals describe transport pitch, not the trimmed image size.
    var splitFrames: [FilmRect] = []
    var candidates: [FilmFrameCandidate] = []
    var scannerBackground: SIMD3<Double>?
}

nonisolated struct FilmPerformance: Sendable {
    nonisolated enum Stage: String, Sendable {
        case preview, pixels, coarseDetection, boundaries, regionRead, sourceDecode, segmentConversion, refinement, export
    }
    nonisolated struct Measurement: Sendable {
        var stage: Stage
        var milliseconds: Double
    }
    private(set) var measurements: [Measurement] = []

    mutating func record(_ stage: Stage, since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: .now).components
        measurements.append(Measurement(stage: stage,
            milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15))
        // Session-local diagnostics contain no source paths or image data and stay bounded.
        if measurements.count > 512 { measurements.removeFirst(measurements.count - 512) }
    }
}
#endif

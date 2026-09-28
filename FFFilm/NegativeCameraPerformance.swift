#if os(iOS)
import CoreMedia
import CoreVideo

/// Keep delivery on the media timeline; callback scheduling jitter must not halve preview fps.
nonisolated struct NegativeFrameCadence {
    private var nextTimestamp: Double?
    private var previousTimestamp: Double?
    private var rate: Double = 0

    mutating func shouldDeliver(_ timestamp: CMTime, fps: Double, force: Bool = false) -> Bool {
        guard timestamp.isNumeric, fps.isFinite, fps > 0 else { return force }
        let seconds = timestamp.seconds
        let interval = 1 / fps
        // A new rate or a restarted capture clock establishes a fresh deadline.
        if rate != fps || previousTimestamp.map({ seconds < $0 }) == true { nextTimestamp = nil }
        rate = fps; previousTimestamp = seconds
        guard let next = nextTimestamp else {
            nextTimestamp = seconds + interval
            return true
        }
        // Allow sub-millisecond timestamp rounding, not an entire missed capture interval.
        guard force || seconds + 0.0005 >= next else { return false }
        if force || seconds - next >= interval {
            // A long gap starts a new phase instead of scheduling a catch-up frame immediately.
            nextTimestamp = seconds + interval
        } else {
            nextTimestamp = next + interval
        }
        return true
    }
}

nonisolated enum NegativeCapturePixelFormat {
    /// TN3121: avoid capture-side YUV→BGRA conversion when Core Image accepts native YUV.
    static func preferred(in available: [OSType]) -> OSType? {
        [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_32BGRA].first { available.contains($0) }
    }
}
#endif

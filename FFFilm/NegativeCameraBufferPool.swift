#if os(iOS)
import CoreVideo

/// Serial capture-queue owner. Native YUV costs much less than two RGBAh frame copies.
nonisolated final class NegativeCameraBufferPool {
    private var pool: CVPixelBufferPool?
    private var dimensions: [Int] = []
    private let capacity: Int

    init(capacity: Int = 6) { self.capacity = capacity }

    /// Stopping capture releases unused storage; retained sampling/export sources stay valid.
    func flush() { if let pool { CVPixelBufferPoolFlush(pool, .excessBuffers) } }

    func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let key = [width, height, Int(format)]
        if dimensions != key || pool == nil {
            var created: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else {
                throw NegativeFailure(key: "negative.error.memory")
            }
            pool = created; dimensions = key
        }
        guard let pool else { throw NegativeFailure(key: "negative.error.memory") }
        var copied: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: capacity] as CFDictionary, &copied)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let copied,
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw NegativeFailure(key: "negative.error.render")
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copied, []) == kCVReturnSuccess else {
            throw NegativeFailure(key: "negative.error.render")
        }
        defer { CVPixelBufferUnlockBaseAddress(copied, []) }
        let planes = CVPixelBufferGetPlaneCount(source)
        for plane in 0..<max(planes, 1) {
            let from = planes == 0 ? CVPixelBufferGetBaseAddress(source) : CVPixelBufferGetBaseAddressOfPlane(source, plane)
            let to = planes == 0 ? CVPixelBufferGetBaseAddress(copied) : CVPixelBufferGetBaseAddressOfPlane(copied, plane)
            let sourceStride = planes == 0 ? CVPixelBufferGetBytesPerRow(source) : CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let targetStride = planes == 0 ? CVPixelBufferGetBytesPerRow(copied) : CVPixelBufferGetBytesPerRowOfPlane(copied, plane)
            let rows = planes == 0 ? height : CVPixelBufferGetHeightOfPlane(source, plane)
            guard let from, let to else { throw NegativeFailure(key: "negative.error.render") }
            for row in 0..<rows {
                memcpy(to.advanced(by: row * targetStride), from.advanced(by: row * sourceStride), min(sourceStride, targetStride))
            }
        }
        // Recycled buffers must not keep a previous frame's profile, matrix or transfer function.
        CVBufferRemoveAllAttachments(copied)
        CVBufferPropagateAttachments(source, copied)
        return copied
    }
}
#endif

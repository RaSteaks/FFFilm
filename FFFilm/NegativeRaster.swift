import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Disk backing bounds the output working set for large 16-bit scans.
/// Source decoders can still allocate internally; their peak is measured in integration tests.
nonisolated enum NegativeRaster {
    static func write(_ image: CIImage, context: CIContext, format: NegativeFormat, to url: URL, regionImage: ((CGRect) -> CIImage)? = nil) throws {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let depth = format == .jpg ? 8 : 16
        let rowBytes = width * (depth == 16 ? 8 : 4)
        let (length, overflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !overflow, length < Int.max / 3, width > 0, height > 0 else { throw NegativeFailure(key: "negative.error.size") }
        let directory = FileManager.default.temporaryDirectory
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        // Stage + worst-case encoded output + breathing room, rather than compressed input size.
        guard available == 0 || available > Int64(length) * 2 + 64 * 1024 * 1024 else { throw NegativeFailure(key: "negative.error.disk") }
        let raster = directory.appendingPathComponent("negative-raster-\(UUID().uuidString)")
        let descriptor = open(raster.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NegativeFailure(key: "negative.error.disk") }
        defer { close(descriptor); try? FileManager.default.removeItem(at: raster) }
        // Reserve real disk blocks before mapping. A sparse ftruncate alone can
        // SIGBUS midway through rendering if another process consumes the free space.
        var allocation = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(length), fst_bytesalloc: 0)
        guard fcntl(descriptor, F_PREALLOCATE, &allocation) == 0,
              ftruncate(descriptor, off_t(length)) == 0,
              let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), memory != MAP_FAILED else {
            throw NegativeFailure(key: "negative.error.disk")
        }
        defer { munmap(memory, length) }
        let page = Int(getpagesize())
        for start in stride(from: 0, to: height, by: 256) {
            try Task.checkCancellation()
            let rows = min(256, height - start)
            let region = CGRect(x: image.extent.minX, y: image.extent.maxY - CGFloat(start + rows), width: CGFloat(width), height: CGFloat(rows))
            autoreleasepool {
                context.render(regionImage?(region) ?? image, toBitmap: memory.advanced(by: start * rowBytes), rowBytes: rowBytes,
                               bounds: region, format: depth == 16 ? .RGBA16 : .RGBA8, colorSpace: NegativePixels.display)
            }
            // Flush completed pages before advising the VM to reclaim them. Never drop dirty data.
            let offset = start * rowBytes / page * page
            let end = min(length, ((start + rows) * rowBytes / page) * page)
            if end > offset {
                guard msync(memory.advanced(by: offset), end - offset, MS_SYNC) == 0 else { throw NegativeFailure(key: "negative.error.disk") }
                madvise(memory.advanced(by: offset), end - offset, MADV_DONTNEED)
            }
        }
        try Task.checkCancellation()
        // Provider has no ownership callback: it is consumed synchronously before munmap.
        guard let provider = CGDataProvider(dataInfo: nil, data: memory, size: length, releaseData: { _, _, _ in }),
              let cg = CGImage(width: width, height: height, bitsPerComponent: depth, bitsPerPixel: depth * 4,
                               bytesPerRow: rowBytes, space: NegativePixels.display,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                                .union(depth == 16 ? .byteOrder16Little : []),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw NegativeFailure(key: "negative.error.export")
        }
        let type = format == .tiff ? UTType.tiff : format == .png ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NegativeFailure(key: "negative.error.export")
        }
        // No source metadata is copied: output pixels are oriented and GPS-free.
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NegativeFailure(key: "negative.error.export") }
    }
}

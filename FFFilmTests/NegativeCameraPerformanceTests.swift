#if os(iOS)
import Testing
import CoreImage
import CoreMedia
import CoreVideo
import Metal
@testable import FFFilm

struct NegativeCameraPerformanceTests {
    @MainActor @Test func filmLookStrengthsPersistIndependentlyAcrossSessions() throws {
        let suite = "fffilm-test-look-strengths-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FilmLookPreferences(defaults: defaults)
        first[.portra400] = 0.35
        first[.triX400] = 0
        let reopened = FilmLookPreferences(defaults: defaults)
        #expect(reopened[.portra400] == 0.35)
        #expect(reopened[.triX400] == 0)
        #expect(reopened[.ektar100] == 1)
    }

    private func makeBuffer(_ format: OSType, width: Int = 98, height: Int = 64) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &result) == kCVReturnSuccess)
        return try #require(result)
    }

    @Test func copiedCameraPlanesRemainExactAndKeepColorAttachments() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] {
            let source = try makeBuffer(format)
            CVPixelBufferLockBaseAddress(source, [])
            let planes = CVPixelBufferGetPlaneCount(source)
            for plane in 0..<max(1, planes) {
                let address = planes == 0 ? CVPixelBufferGetBaseAddress(source)! : CVPixelBufferGetBaseAddressOfPlane(source, plane)!
                let stride = planes == 0 ? CVPixelBufferGetBytesPerRow(source) : CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let height = planes == 0 ? 64 : CVPixelBufferGetHeightOfPlane(source, plane)
                for y in 0..<height { memset(address.advanced(by: y * stride), Int32(30 + y + plane * 70), stride) }
            }
            CVPixelBufferUnlockBaseAddress(source, [])
            CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let copy = try #require(try NegativeCameraBufferPool().copy(source))
            #expect(copy !== source && CVPixelBufferGetPixelFormatType(copy) == format)
            let matrix = CVBufferCopyAttachment(copy, kCVImageBufferYCbCrMatrixKey, nil)
            #expect(matrix.map { CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_709_2) } == true)
            CVPixelBufferLockBaseAddress(copy, .readOnly)
            // Check real row bytes across different allocation strides, including the chroma plane.
            for plane in 0..<max(1, planes) {
                let address = planes == 0 ? CVPixelBufferGetBaseAddress(copy)! : CVPixelBufferGetBaseAddressOfPlane(copy, plane)!
                let stride = planes == 0 ? CVPixelBufferGetBytesPerRow(copy) : CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                let height = planes == 0 ? 64 : CVPixelBufferGetHeightOfPlane(copy, plane)
                let activeBytes = planes == 0 ? 98 * 4 : 98
                for y in 0..<height {
                    let row = address.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    #expect((0..<activeBytes).allSatisfy { row[$0] == UInt8(30 + y + plane * 70) })
                }
            }
            CVPixelBufferUnlockBaseAddress(copy, .readOnly)
            // A reused capture buffer must not mutate the independently retained source.
            CVPixelBufferLockBaseAddress(source, [])
            let original = planes == 0 ? CVPixelBufferGetBaseAddress(source)! : CVPixelBufferGetBaseAddressOfPlane(source, 0)!
            original.storeBytes(of: UInt8(0), as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(source, [])
            CVPixelBufferLockBaseAddress(copy, .readOnly)
            let retained = planes == 0 ? CVPixelBufferGetBaseAddress(copy)! : CVPixelBufferGetBaseAddressOfPlane(copy, 0)!
            #expect(retained.load(as: UInt8.self) == 30)
            CVPixelBufferUnlockBaseAddress(copy, .readOnly)
        }
    }

    @Test func cameraPoolBoundsBacklogAndRecoversAfterReleaseAndRotation() throws {
        let pool = NegativeCameraBufferPool(capacity: 2)
        let source = try makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        var held: [CVPixelBuffer] = []
        for _ in 0..<2 { held.append(try #require(try pool.copy(source))) }
        #expect(try pool.copy(source) == nil)
        held.removeAll()
        #expect(try pool.copy(source) != nil)
        // Rotation/format changes create a correctly sized pool rather than stretching pixels.
        let rotated = try makeBuffer(kCVPixelFormatType_32BGRA, width: 64, height: 98)
        let copy = try #require(try pool.copy(rotated))
        #expect(CVPixelBufferGetWidth(copy) == 64 && CVPixelBufferGetHeight(copy) == 98)
    }

    @Test func metalPreviewMatchesReferenceColorAndTopLeftOrientation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: NegativePixels.linear,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        let extent = CGRect(x: 13, y: 17, width: 96, height: 64)
        let dark = CIImage(color: CIColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1, colorSpace: NegativePixels.linear)!).cropped(to: extent)
        let top = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1, colorSpace: NegativePixels.linear)!)
            .cropped(to: CGRect(x: 13, y: 49, width: 96, height: 32))
        let source = top.composited(over: dark)
        let base = NegativeBase(red: 0.6, green: 0.4, blue: 0.3, uneven: false)
        for calibration: NegativeBase? in [nil, base] {
            for size in [CGSize(width: 96, height: 64), CGSize(width: 48, height: 32)] {
                let width = Int(size.width), height = Int(size.height)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                let texture = try #require(device.makeTexture(descriptor: descriptor))
                let command = try #require(queue.makeCommandBuffer())
                try NegativeMetalRenderer.encode(source, base: calibration, texture: texture, context: context, command: command)
                command.commit(); command.waitUntilCompleted()
                #expect(command.status == .completed)
                var actual = [Float16](repeating: 0, count: width * height * 4)
                actual.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                // Independent bitmap path is top-first, as are UIKit's drawable rows.
                let normalized = source.transformed(by: CGAffineTransform(translationX: -13, y: -17))
                let reference = try NegativePixels.preview(normalized, base: calibration, context: context, limit: size.width)
                let data = try #require(reference.dataProvider?.data)
                let bytes = try #require(CFDataGetBytePtr(data))
                var maxError: Float = 0
                for y in 0..<height { for x in 0..<width * 4 {
                    let offset = y * reference.bytesPerRow + x * 2
                    let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                    maxError = max(maxError, abs(Float(actual[y * width * 4 + x]) - Float(Float16(bitPattern: bits))))
                } }
                #expect(maxError < 0.002)
                // Explicit top/bottom color anchors catch a common shared-path vertical-flip bug.
                if calibration == nil {
                    #expect(abs(Float(actual[0]) - 0.6) < 0.002)
                    #expect(abs(Float(actual[(height - 1) * width * 4]) - 0.08) < 0.002)
                } else { #expect(Float(actual[0]) < 0.002 && Float(actual[(height - 1) * width * 4]) > 0.1) }
            }
        }
    }

    @Test func previewLooksPreserveTonalOrderAndUseTheCalibratedPositive() throws {
        let context = NegativePixels.context()
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        func pixel(_ rgb: (CGFloat, CGFloat, CGFloat), look: CameraFilmLook,
                   strength: Double = 1, base: NegativeBase? = nil, monochrome: Bool = false) throws -> [Float] {
            let color = try #require(CIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1, colorSpace: NegativePixels.linear))
            let source = CIImage(color: color).cropped(to: bounds)
            let image = NegativeMetalRenderer.displayImage(source, base: base, look: look, strength: strength,
                                                          monochrome: monochrome, size: bounds.size)
            var values = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &values, rowBytes: 16, bounds: bounds, format: .RGBAf, colorSpace: NegativePixels.linear)
            return values
        }
        for look in CameraFilmLook.allCases {
            let ramp = try [0.0, 0.04, 0.18, 0.5, 1.0].map { try pixel(($0, $0, $0), look: look)[0] }
            #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 < $1 })
        }
        let colored: (CGFloat, CGFloat, CGFloat) = (0.6, 0.4, 0.3)
        let mono = try pixel(colored, look: .classicMono)
        #expect(abs(mono[0] - mono[1]) < 0.002 && abs(mono[1] - mono[2]) < 0.002)
        let soft = try pixel(colored, look: .softNegative), vivid = try pixel(colored, look: .vividSlide)
        #expect(vivid[0] - vivid[2] > soft[0] - soft[2] + 0.04)
        // A sample equal to the film base gives a black positive before the look lifts the toe.
        let base = NegativeBase(red: 0.6, green: 0.4, blue: 0.3, uneven: false)
        let calibrated = try pixel(colored, look: .softNegative, base: base)
        #expect(calibrated.prefix(3).allSatisfy { $0 < 0.015 })

        let shade: (CGFloat, CGFloat, CGFloat) = (0.12, 0.22, 0.15)
        let raw = try pixel(shade, look: .neutral)
        for look in [CameraFilmLook.portra400, .ektar100, .ektachromeE100, .triX400] {
            let zero = try pixel(shade, look: look, strength: 0)
            let half = try pixel(shade, look: look, strength: 0.5)
            let full = try pixel(shade, look: look)
            let gray = try pixel((0.18, 0.18, 0.18), look: look)
            for channel in 0..<3 {
                #expect(zero[channel] == raw[channel])
                #expect(abs(half[channel] - (raw[channel] + full[channel]) * 0.5) < 0.002)
                #expect(abs(gray[channel] - 0.18) < 0.003)
            }
        }
        // Published RGB layers diverge in the highlights. These anchors also check table
        // channel order and sRGB table decoding independently of the LUT generator.
        for (look, white) in [(CameraFilmLook.portra400, [0.868, 0.859, 0.946] as [Float]),
                              (.ektar100, [0.883, 0.888, 0.966]), (.ektachromeE100, [0.690, 0.718, 0.661])] {
            let result = try pixel((1, 1, 1), look: look)
            for channel in 0..<3 { #expect(abs(result[channel] - white[channel]) < 0.007) }
        }
        let silver = try pixel(shade, look: .triX400)
        #expect(abs(silver[0] - silver[1]) < 0.002 && abs(silver[1] - silver[2]) < 0.002)
        let grayBase = try pixel(shade, look: .neutral, base: base, monochrome: true)
        #expect(abs(grayBase[0] - grayBase[2]) < 0.002)
        #expect(try pixel(shade, look: .neutral, monochrome: true) == raw)
    }

    @Test func completedGPUFramesReleaseNativePoolStorage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: NegativePixels.linear,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        let source = try makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(source, plane), 128,
                   CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane))
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 98, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let pool = NegativeCameraBufferPool(capacity: 3)
        for _ in 0..<60 {
            try autoreleasepool {
                // CI/Metal must release old inputs; otherwise this bounded pool stalls after three frames.
                let copied = try #require(try pool.copy(source))
                let image = CIImage(cvPixelBuffer: copied)
                let command = try #require(queue.makeCommandBuffer())
                try NegativeMetalRenderer.encode(image, base: NegativeBase(red: 0.6, green: 0.4, blue: 0.3, uneven: false),
                                                 texture: texture, context: context, command: command)
                command.commit(); command.waitUntilCompleted()
                #expect(command.status == .completed)
                withExtendedLifetime(image) {}
            }
        }
        pool.flush()
        #expect(try pool.copy(source) != nil)
    }

    @Test func callbackJitterDoesNotDiscardThirtyFPSMediaFrames() {
        var cadence = NegativeFrameCadence()
        var oldLastArrival = -Double.infinity
        var oldCount = 0, delivered = 0
        for frame in 0..<300 {
            // Stable camera timestamps, but alternating one-millisecond queue latency.
            let timestamp = CMTime(value: Int64(frame), timescale: 30)
            let arrival = timestamp.seconds + (frame.isMultiple(of: 2) ? 0.001 : 0)
            if arrival - oldLastArrival >= 1.0 / 30 { oldLastArrival = arrival; oldCount += 1 }
            if cadence.shouldDeliver(timestamp, fps: 30) { delivered += 1 }
        }
        #expect(delivered == 300)
        #expect(oldCount < 200)
    }

    @Test func reducedRatesStayEvenAcrossRoundingGapsAndRateChanges() {
        for fps in [15.0, 10.0] {
            var cadence = NegativeFrameCadence()
            let accepted = (0..<300).filter { frame in
                // Slight source-clock rounding cannot shift the cadence by a whole frame.
                let seconds = Double(frame) / 30 + (frame.isMultiple(of: 2) ? 0.00001 : -0.00001)
                return cadence.shouldDeliver(CMTime(seconds: seconds, preferredTimescale: 1_000_000), fps: fps)
            }
            #expect(accepted == Array(stride(from: 0, to: 300, by: Int(30 / fps))))
        }
        var cadence = NegativeFrameCadence()
        // A fresh locked sample bypasses throttling; missing frames do not create a burst.
        let decisions = [
            cadence.shouldDeliver(CMTime(value: 0, timescale: 30), fps: 15),
            cadence.shouldDeliver(CMTime(value: 1, timescale: 30), fps: 15),
            cadence.shouldDeliver(CMTime(value: 1, timescale: 30), fps: 15, force: true),
            cadence.shouldDeliver(CMTime(value: 300, timescale: 30), fps: 15),
            cadence.shouldDeliver(CMTime(value: 301, timescale: 30), fps: 15),
            cadence.shouldDeliver(CMTime(value: 302, timescale: 30), fps: 30),
            cadence.shouldDeliver(.zero, fps: 30),
            cadence.shouldDeliver(.invalid, fps: 30)
        ]
        #expect(decisions == [true, false, true, true, false, true, true, false])
    }

    @Test func pixelFormatSelectionUsesOnlyAdvertisedFormats() {
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let bgra = kCVPixelFormatType_32BGRA
        #expect(NegativeCapturePixelFormat.preferred(in: [bgra, video, full]) == full)
        #expect(NegativeCapturePixelFormat.preferred(in: [bgra, video]) == video)
        #expect(NegativeCapturePixelFormat.preferred(in: [bgra]) == bgra)
        #expect(NegativeCapturePixelFormat.preferred(in: []) == nil)
    }

    @Test func nativeYUVKeepsLinearSamplingAndFullResolution() throws {
        let context = NegativePixels.context()
        var bases: [NegativeBase] = []
        for fullRange in [true, false] {
            var optionalBuffer: CVPixelBuffer?
            let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            #expect(CVPixelBufferCreate(nil, 96, 64, format,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optionalBuffer) == kCVReturnSuccess)
            let buffer = try #require(optionalBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            // Equivalent neutral mid-gray in full-range and video-range Y'CbCr.
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), fullRange ? 128 : 126,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 64)
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 32)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            let image = CIImage(cvPixelBuffer: buffer)
            let cg = try #require(context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: NegativePixels.linear))
            #expect(cg.width == 96 && cg.height == 64 && cg.bitsPerComponent == 16)
            let retained = CIImage(cgImage: cg)
            let base = try NegativePixels.sample(retained, point: CGPoint(x: 0.5, y: 0.5), context: context)
            #expect(abs(base.red - base.green) < 0.01 && abs(base.green - base.blue) < 0.01)
            #expect(base.red > 0.15 && base.red < 0.35)
            bases.append(base)
            let positive = try NegativePixels.preview(retained, base: base, context: context, limit: 96)
            #expect(positive.width == 96 && positive.height == 64)
        }
        #expect(abs(bases[0].red - bases[1].red) < 0.01)
    }
}
#endif

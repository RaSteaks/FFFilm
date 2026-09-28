#if os(iOS)
import Testing
import CoreImage
import CoreMedia
import CoreVideo
@testable import FFFilm

struct NegativeCameraPerformanceTests {
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

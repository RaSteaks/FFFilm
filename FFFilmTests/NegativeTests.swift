import Testing
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import FFFilm

@Suite(.serialized)
struct NegativeTests {
    @Test func ownedImportRetainsOriginalCopyAndCleansUpFailures() async throws {
        let renderer = NegativeRenderer()
        let file = temporary()
        defer { try? FileManager.default.removeItem(at: file) }
        try NegativePixels.context().writeTIFFRepresentation(of: fixture(), to: file,
            format: .RGBA16, colorSpace: NegativePixels.display)
        // The asset must retain the transferred URL rather than create another copy.
        var asset: NegativeAsset? = try await renderer.load(owned: file)
        #expect(asset?.fileURL == file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        asset = nil
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let invalid = temporary()
        try Data("invalid image".utf8).write(to: invalid)
        do {
            _ = try await renderer.load(owned: invalid)
            Issue.record("Invalid import unexpectedly succeeded")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: invalid.path))
        }

        let cancelled = temporary()
        try Data().write(to: cancelled)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await renderer.load(owned: cancelled)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled import unexpectedly succeeded")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        }
    }

    private func temporary(_ suffix: String = "tiff") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("negative-test-\(UUID().uuidString).\(suffix)")
    }
    private func fixture(width: Int = 96, height: Int = 600) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let bottom = CIImage(color: CIColor(red: 0.12, green: 0.08, blue: 0.04, alpha: 1, colorSpace: NegativePixels.linear)!).cropped(to: extent)
        let top = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1, colorSpace: NegativePixels.linear)!)
            .cropped(to: CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return top.composited(over: bottom).cropped(to: extent)
    }
    private func pixels(_ cg: CGImage) -> [UInt8] {
        let context = NegativePixels.context()
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        context.render(CIImage(cgImage: cg), toBitmap: &bytes, rowBytes: cg.width * 4,
                       bounds: CGRect(x: 0, y: 0, width: cg.width, height: cg.height), format: .RGBA8, colorSpace: NegativePixels.display)
        return bytes
    }

    @Test func sampleUsesSourceCoordinatesAndRejectsBadRegions() throws {
        let image = fixture(), context = NegativePixels.context()
        let base = try NegativePixels.sample(image, point: CGPoint(x: 0.5, y: 0.1), context: context)
        #expect(abs(base.red - 0.6) < 0.001)
        #expect(abs(base.green - 0.4) < 0.001)
        #expect(abs(base.blue - 0.2) < 0.001)
        #expect(!base.uneven)
        #expect(NegativePixels.sampleRect(point: CGPoint(x: 0, y: 0), extent: image.extent) == nil)
        #expect(throws: NegativeFailure.self) { try NegativePixels.sample(image, point: CGPoint(x: -1, y: 0.5), context: context) }
        for color in [CIColor.white, CIColor.black, CIColor.clear] {
            let invalid = CIImage(color: color).cropped(to: image.extent)
            #expect(throws: NegativeFailure.self) { try NegativePixels.sample(invalid, point: CGPoint(x: 0.5, y: 0.5), context: context) }
        }
    }

    @Test func inversionDomainAndMonotonicity() throws {
        let context = NegativePixels.context(), image = fixture()
        let base = try NegativePixels.sample(image, point: CGPoint(x: 0.5, y: 0.1), context: context)
        let result = try NegativePixels.preview(image, base: base, context: context)
        let bytes = pixels(result)
        // CI bitmap row zero is the visual top; fixture top equals the sampled base.
        #expect(bytes[0] < 3)
        let offset = (result.height - 1) * result.width * 4
        // 1 - sRGBEncode(0.2) ≈ 0.515, not 1 - 0.2 = 0.8.
        #expect(abs(Int(bytes[offset]) - 131) < 4)
        #expect(abs(Int(bytes[offset + 1]) - 131) < 4)
        #expect(abs(Int(bytes[offset + 2]) - 131) < 4)
    }

    @Test func exportAllFormatsPreservesSizeDepthProfileAndStripeOrder() async throws {
        let context = NegativePixels.context(), url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        try context.writeTIFFRepresentation(of: fixture(), to: url, format: .RGBA16, colorSpace: NegativePixels.display)
        let renderer = NegativeRenderer(), asset = try await renderer.load(url)
        let base = try await renderer.sample(asset, point: CGPoint(x: 0.5, y: 0.1))
        let preview = try await renderer.render(asset, base: base)
        let expected = pixels(preview)
        for format in NegativeFormat.allCases {
            let output = try await renderer.export(asset, base: base, format: format)
            defer { try? FileManager.default.removeItem(at: output) }
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(cg.width == 96 && cg.height == 600)
            #expect(cg.bitsPerComponent == (format == .jpg ? 8 : 16))
            #expect(cg.colorSpace?.name == CGColorSpace.sRGB)
            let metadata = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            #expect(metadata[kCGImagePropertyGPSDictionary as String] == nil)
            let actual = pixels(cg)
            for row in [0, 255, 256, 299, 300, 511, 512, 599] {
                let index = row * cg.width * 4
                #expect(abs(Int(actual[index]) - Int(expected[index])) <= (format == .jpg ? 4 : 1))
            }
        }
    }

    @Test func rejectsMultipageTIFF() async throws {
        let url = temporary(), context = NegativePixels.context()
        defer { try? FileManager.default.removeItem(at: url) }
        let cg = try NegativePixels.preview(fixture(), context: context)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, cg, nil); CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
        await #expect(throws: NegativeFailure.self) { try await NegativeRenderer().load(url) }
    }

    @Test func orientationAndGrayscaleAreDecoded() async throws {
        let url = temporary(), grayURL = temporary()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: grayURL) }
        let context = NegativePixels.context()
        let fixtureImage = fixture(width: 96, height: 128)
        let cg = try #require(context.createCGImage(fixtureImage, from: fixtureImage.extent, format: .RGBA16, colorSpace: NegativePixels.display))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let rotated = try await NegativeRenderer().load(url)
        #expect(rotated.width == 128 && rotated.height == 96)
        let bytes = Data(repeating: 128, count: 64 * 64)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let gray = try #require(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
                                       space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: [],
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let writer = try #require(CGImageDestinationCreateWithURL(grayURL as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, gray, nil); #expect(CGImageDestinationFinalize(writer))
        let renderer = NegativeRenderer(), asset = try await renderer.load(grayURL)
        let base = try await renderer.sample(asset, point: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(base.red - base.green) < 0.001 && abs(base.green - base.blue) < 0.001)
    }

    @Test(arguments: [1, 5, 32773])
    func compressedTIFFPreservesSourcePrecision(compression: Int) async throws {
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let context = NegativePixels.context()
        let image = fixture()
        let cg = try #require(context.createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: NegativePixels.display))
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, cg, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: compression]] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        let renderer = NegativeRenderer(), asset = try await renderer.load(url)
        let base = try await renderer.sample(asset, point: CGPoint(x: 0.5, y: 0.1))
        #expect(abs(base.red - 0.6) < 0.002)
        #expect(abs(base.blue - 0.2) < 0.002)
        let output = try await renderer.export(asset, base: base, format: .png)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(result, 0, nil)?.bitsPerComponent == 16)
    }

    @Test(arguments: Array(1...8))
    func croppedSourceAgreesWithFullOrientation(orientation: Int) throws {
        let context = NegativePixels.context(), source = fixture(width: 72, height: 600)
        let cg = try #require(context.createCGImage(source, from: source.extent, format: .RGBA16, colorSpace: NegativePixels.display))
        let file = NegativeFilePixels(cg: cg, space: NegativePixels.display, orientation: Int32(orientation))
        let actual = try file.preview(context: context)
        let expected = try NegativePixels.preview(file.image, context: context)
        let a = pixels(actual), b = pixels(expected)
        #expect(actual.width == expected.width && actual.height == expected.height)
        #expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @Test func embeddedP3ProfileReachesLinearSampling() async throws {
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let image = CIImage(color: CIColor(red: 0.6, green: 0.5, blue: 0.4, alpha: 1, colorSpace: p3)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let context = NegativePixels.context(), renderer = NegativeRenderer()
        let expected = try NegativePixels.sample(image, point: CGPoint(x: 0.5, y: 0.5), context: context)
        try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: p3)
        let asset = try await renderer.load(url)
        let actual = try await renderer.sample(asset, point: CGPoint(x: 0.5, y: 0.5))
        #expect(!asset.assumesSRGB)
        #expect(abs(actual.red - expected.red) < 0.001)
        #expect(abs(actual.green - expected.green) < 0.001)
        #expect(abs(actual.blue - expected.blue) < 0.001)
    }

    @Test func cancellationDoesNotPublishAnExport() async throws {
        let context = NegativePixels.context()
        let image = fixture()
        let asset = NegativeAsset(image: image, preview: try NegativePixels.preview(image, context: context))
        let renderer = NegativeRenderer()
        let task = Task {
            try Task.checkCancellation()
            return try await renderer.export(asset, base: NegativeBase(red: 0.6, green: 0.4, blue: 0.2, uneven: false), format: .png)
        }
        task.cancel()
        do { let url = try await task.value; try? FileManager.default.removeItem(at: url); Issue.record("Cancelled export unexpectedly completed") }
        catch { #expect(error is CancellationError) }
    }

    /// Opt in for resource-intensive validation; regular unit runs stay small and deterministic.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEGATIVE_LARGE_TEST"] == "1"))
    func largeTIFFRoundTrip() async throws {
        let url = temporary(), context = NegativePixels.context()
        defer { try? FileManager.default.removeItem(at: url) }
        let image = fixture(width: 5167, height: 16443)
        try NegativeRaster.write(image, context: context, format: .tiff, to: url)
        let compressed = temporary()
        defer { try? FileManager.default.removeItem(at: compressed) }
        // Exercise a large LZW source too: small codec fixtures cannot reveal decode memory behavior.
        try autoreleasepool {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
            let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
            let writer = try #require(CGImageDestinationCreateWithURL(compressed as CFURL, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, cg, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
            #expect(CGImageDestinationFinalize(writer))
        }
        for source in [url, compressed] { try await verifyLargeFile(source) }
    }

    private func verifyLargeFile(_ url: URL) async throws {
        let renderer = NegativeRenderer(), asset = try await renderer.load(url)
        #expect(asset.width == 5167 && asset.height == 16443)
        #expect(max(asset.preview.width, asset.preview.height) <= 1801)
        let base = try await renderer.sample(asset, point: CGPoint(x: 0.5, y: 0.1))
        for format in NegativeFormat.allCases {
            let output = try await renderer.export(asset, base: base, format: format)
            defer { try? FileManager.default.removeItem(at: output) }
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 5167)
            #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 16443)
            #expect(properties[kCGImagePropertyDepth as String] as? Int == (format == .jpg ? 8 : 16))
        }
    }
}

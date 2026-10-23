#if os(macOS)
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FFFilm

struct FilmFrameDetectionTests {
    private typealias RGB = SIMD3<UInt8>
    private let orange = RGB(205, 137, 83)

    @Test func clearAndDarkBaseFindAccurateBoundariesInBothDirections() {
        for horizontal in [false, true] {
            for base in [RGB(repeating: 245), RGB(repeating: 8), orange] {
                let pixels = strip(horizontal: horizontal, gaps: [196..<204, 396..<404], base: base)
                expectBoundaries(detect(pixels, horizontal: horizontal), [200, 400], horizontal: horizontal)
            }
        }
    }

    @Test func isolatedExtremesDoNotSetTheBaseThreshold() {
        // A white highlight and a black shadow used to move the global extrema away from orange base.
        let pixels = strip(gaps: [196..<204, 396..<404]) { position, transverse, color in
            if (65..<88).contains(position), transverse < 70 { return RGB(repeating: 255) }
            if (465..<488).contains(position), transverse > 70 { return RGB(repeating: 0) }
            return color
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func colorDistinguishesBaseFromEqualBrightnessContent() {
        // Both colors average to 140: no scalar luminance threshold can separate these regions.
        let pixels = strip(gaps: [196..<204, 396..<404], base: RGB(210, 140, 70), textured: false) {
            position, _, color in
            [196..<204, 396..<404].contains(where: { $0.contains(position) }) ? color : RGB(100, 140, 180)
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func differentSceneHuesDoNotHideARealGap() {
        // Both sides have the same base polarity, but their channel changes can be orthogonal.
        let examples: [(base: RGB, before: RGB, after: RGB)] = [
            (RGB(repeating: 8), RGB(200, 8, 8), RGB(8, 8, 200)),
            (orange, RGB(50, 137, 83), RGB(205, 20, 83))
        ]
        for horizontal in [false, true] {
            for example in examples {
                let pixels = strip(horizontal: horizontal, gaps: [296..<304], base: example.base) { position, _, color in
                    if (296..<304).contains(position) { return color }
                    return position < 300 ? example.before : example.after
                }
                expectBoundaries(detect(pixels, horizontal: horizontal), [300], horizontal: horizontal)
            }
        }
    }

    @Test func intermediateColorTransitionsDoNotBecomeGaps() {
        // Relaxing the hue test must still reject a narrow intermediate step between two scenes.
        let examples: [(before: RGB, middle: RGB, after: RGB)] = [
            (RGB(repeating: 40), RGB(repeating: 120), RGB(repeating: 220)),
            (RGB(200, 8, 8), RGB(104, 8, 104), RGB(8, 8, 200))
        ]
        for horizontal in [false, true] {
            for example in examples {
                let pixels = strip(horizontal: horizontal, gaps: []) { position, _, _ in
                    if (296..<304).contains(position) { return example.middle }
                    return position < 300 ? example.before : example.after
                }
                #expect(detect(pixels, horizontal: horizontal).isEmpty)
            }
        }
    }

    @Test func consistentGapsOutrankAnIsolatedSceneStripe() {
        // Two matching gaps must survive a thinner, locally higher-scoring stripe inside a frame.
        let gaps = [194..<206, 394..<406]
        for horizontal in [false, true] {
            for bright in [false, true] {
                let base = RGB(repeating: bright ? 245 : 8)
                let pixels = strip(horizontal: horizontal, gaps: gaps, base: base) { position, _, color in
                    if gaps.contains(where: { $0.contains(position) }) { return color }
                    if (280..<282).contains(position) { return RGB(repeating: bright ? 180 : 40) }
                    return RGB(repeating: 100)
                }
                expectBoundaries(detect(pixels, horizontal: horizontal), [200, 400], horizontal: horizontal)
            }
        }
    }

    @Test func visibleBaseMarginsKeepSingleGapEligible() {
        // A two-frame scan has only one gap: visible base rails corroborate it despite repeated scene bands.
        for horizontal in [false, true] {
            let pixels = strip(horizontal: horizontal, gaps: [294..<306], base: RGB(repeating: 245)) {
                position, transverse, color in
                if transverse < 25 || transverse >= 135 { return RGB(repeating: 245) }
                if (294..<306).contains(position) { return color }
                if (180..<182).contains(position) || (420..<422).contains(position) { return RGB(repeating: 180) }
                return RGB(repeating: 100)
            }
            expectBoundaries(detect(pixels, horizontal: horizontal), [300], horizontal: horizontal)
        }
    }

    @Test func brightTexturedBandsAreNotFilmBase() {
        // A constant mean hides large transverse variations; the detector must retain that texture.
        let pixels = strip(gaps: [196..<204, 396..<404], base: RGB(repeating: 220)) {
            position, transverse, color in
            if [85..<93, 285..<293, 485..<493].contains(where: { $0.contains(position) }) {
                return RGB(repeating: transverse % 20 < 10 ? 185 : 255)
            }
            return color
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func baseMarginsOutweighMoreNumerousUniformSceneBands() {
        let gaps = [196..<204, 396..<404]
        let pixels = strip(gaps: gaps, base: RGB(repeating: 18)) { position, transverse, color in
            if transverse < 25 || transverse >= 135 { return RGB(repeating: 18) }
            if [76..<84, 276..<284, 476..<484].contains(where: { $0.contains(position) }) {
                return RGB(repeating: 240)
            }
            return color
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func darkScannerHolderIsNotMistakenForNegativeBase() {
        // Both the black holder and orange film rails persist, but the rails are inside the holder.
        let pixels = strip(gaps: [196..<204, 396..<404]) { position, transverse, color in
            if transverse < 12 || transverse >= 148 { return RGB(repeating: 0) }
            if transverse < 25 || transverse >= 135 { return orange }
            if [76..<84, 276..<284, 476..<484].contains(where: { $0.contains(position) }) {
                return RGB(repeating: 0)
            }
            return color
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func dustGrainAndOneDamagedLineDoNotSplitTheGap() {
        let gaps = [196..<204, 396..<404]
        let pixels = strip(gaps: gaps) { position, transverse, color in
            guard gaps.contains(where: { $0.contains(position) }) else { return color }
            if position == 199 || (position * 17 + transverse * 13) % 29 == 0 { return RGB(repeating: 0) }
            let noise = (position * 17 + transverse * 7) % 5 - 2
            return RGB(UInt8(Int(color.x) + noise), UInt8(Int(color.y) + noise), UInt8(Int(color.z) + noise))
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func sprocketsAndEdgeLetteringDoNotCreateSlices() {
        let pixels = strip(gaps: [196..<204, 396..<404]) { position, transverse, color in
            if transverse < 28 || transverse > 132 {
                return RGB(repeating: position % 24 < 8 ? 255 : 0)
            }
            return color
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func singleGapAndUnequalFrameLengthsRemainSupported() {
        expectBoundaries(detect(strip(gaps: [276..<284])), [280])
        expectBoundaries(detect(strip(gaps: [166..<174, 386..<394])), [170, 390])
    }

    @Test func faintBaseIsNotLostToTextureElsewhereInTheScan() {
        // Low-density frames can sit only ten code values below a clean film base.
        let pixels = strip(gaps: [196..<204, 396..<404], base: RGB(repeating: 120), textured: false) {
            position, transverse, color in
            if [196..<204, 396..<404].contains(where: { $0.contains(position) }) { return color }
            if (184..<216).contains(position) || (384..<416).contains(position) { return RGB(repeating: 110) }
            return RGB(repeating: UInt8(40 + transverse % 50))
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func slightlySlantedGapsAndBaseShadingKeepTheirCenters() {
        // A small scan rotation and gradual base tint variation must not shift the cut into the image.
        let pixels = strip(gaps: []) { position, transverse, color in
            let offset = Int((Double(transverse) - 80) / 30)
            if [196..<204, 396..<404].contains(where: { $0.contains(position - offset) }) {
                let shade = transverse / 20 + (position > 300 ? 5 : 0)
                return RGB(UInt8(205 - shade), UInt8(137 - shade), UInt8(83 - shade))
            }
            return color
        }
        expectBoundaries(detect(pixels), [200, 400])
    }

    @Test func thinGapsSurviveLongStripPreview() {
        let pixels = strip(length: 1800, gaps: [599..<601, 1199..<1201])
        expectBoundaries(detect(pixels, length: 1800), [600, 1200], length: 1800)
    }

    @Test func uniformGradientsBroadSkyAndSceneEdgesDoNotInventGaps() {
        let uniform = strip(gaps: [], textured: false)
        #expect(detect(uniform).isEmpty)
        let gradient = strip(gaps: [], textured: false) { position, _, _ in
            RGB(repeating: UInt8(30 + position / 3))
        }
        #expect(detect(gradient).isEmpty)
        let sky = strip(gaps: []) { position, _, color in
            (220..<320).contains(position) ? RGB(repeating: 240) : color
        }
        #expect(detect(sky).isEmpty)
        let edge = strip(gaps: [], textured: false) { position, _, _ in
            RGB(repeating: position < 300 ? 60 : 220)
        }
        #expect(detect(edge).isEmpty)
        #expect(FilmFrameDetection.frames(pixels: [], width: 600, height: 160).isEmpty)
        #expect(FilmFrameDetection.frames(pixels: [], width: Int.max, height: 160).isEmpty)
    }

    @Test func rendererUsesTopLeftCoordinatesAndTheSameDetectionOnImport() async throws {
        // An asymmetric vertical TIFF catches accidental bottom-up Core Image bitmap interpretation.
        let width = 160, height = 600
        let pixels = strip(horizontal: false, gaps: [166..<174, 386..<394])
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory.appending(path: "FilmDetection-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let renderer = FilmRenderer()
        let info = try await renderer.load(url, inputSpace: "sRGB")
        let frames = try await renderer.detectFrames()
        expectBoundaries(frames, [170, 390], horizontal: false)
        // Import uses the same interior interval to estimate the next-frame length.
        #expect(abs((info.layout.frameLength ?? 0) - 220.0 / 600) < 0.002)
        await renderer.close()
    }

    private func detect(_ pixels: [UInt8], horizontal: Bool = true, length: Int = 600) -> [FilmRect] {
        FilmFrameDetection.frames(pixels: pixels, width: horizontal ? length : 160, height: horizontal ? 160 : length)
    }

    private func expectBoundaries(_ frames: [FilmRect], _ boundaries: [Int], horizontal: Bool = true, length: Int = 600,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(frames.count == boundaries.count + 1, sourceLocation: sourceLocation)
        #expect(frames.allSatisfy { $0.valid }, sourceLocation: sourceLocation)
        guard frames.count == boundaries.count + 1 else { return }
        for (frame, boundary) in zip(frames.dropFirst(), boundaries) {
            #expect(abs((horizontal ? frame.x : frame.y) * Double(length) - Double(boundary)) <= 1,
                    sourceLocation: sourceLocation)
        }
        #expect(abs(frames.map { horizontal ? $0.width : $0.height }.reduce(0, +) - 1) < 0.000001,
                sourceLocation: sourceLocation)
    }

    /// Deterministic top-left fixtures vary scene texture while keeping ground-truth gaps explicit.
    private func strip(horizontal: Bool = true, length: Int = 600, gaps: [Range<Int>], base: RGB? = nil,
                       textured: Bool = true, edit: ((Int, Int, RGB) -> RGB)? = nil) -> [UInt8] {
        let cross = 160, width = horizontal ? length : cross, height = horizontal ? cross : length
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for position in 0..<length {
            for transverse in 0..<cross {
                let detail = textured ? (position * 3 + transverse * 7) % 49 : 24
                var color = RGB(UInt8(70 + detail), UInt8(65 + detail), UInt8(60 + detail))
                if gaps.contains(where: { $0.contains(position) }) { color = base ?? orange }
                if let edit { color = edit(position, transverse, color) }
                let offset = horizontal ? (transverse * width + position) * 4 : (position * width + transverse) * 4
                pixels[offset] = color.x; pixels[offset + 1] = color.y; pixels[offset + 2] = color.z
            }
        }
        return pixels
    }
}
#endif

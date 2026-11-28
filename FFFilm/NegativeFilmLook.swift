#if os(iOS)
import CoreImage

/// Preview-only transforms on an original or converted positive. Stock LUTs are baked
/// from characteristic curves; the three generic looks use hand-authored tone curves.
nonisolated enum CameraFilmLook: String, CaseIterable, Sendable {
    case neutral = "negative.look.neutral"
    case softNegative = "negative.look.softNegative"
    case vividSlide = "negative.look.vividSlide"
    case classicMono = "negative.look.classicMono"

    case portra400 = "negative.look.portra400"
    case ektar100 = "negative.look.ektar100"
    case ektachromeE100 = "negative.look.ektachromeE100"
    case triX400 = "negative.look.triX400"

    var kodakDataSheet: URL? {
        switch self {
        case .portra400: URL(string: "https://kodakprofessional.com/sites/default/files/2025-07/e4050.pdf")
        case .ektar100: URL(string: "https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4046_ektar_100.pdf")
        case .ektachromeE100: URL(string: "https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4000_ektachrome_100.pdf")
        case .triX400: URL(string: "https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4017_TriX.pdf")
        case .neutral, .softNegative, .vividSlide, .classicMono: nil
        }
    }

    func applying(to image: CIImage, strength: Double = 1) -> CIImage {
        guard strength > 0 else { return image }
        let styled: CIImage
        switch self {
        case .portra400: styled = lookup(image, table: KodakFilmLookTables.portra400)
        case .ektar100: styled = lookup(image, table: KodakFilmLookTables.ektar100)
        case .ektachromeE100: styled = lookup(image, table: KodakFilmLookTables.ektachromeE100)
        case .triX400:
            // The 400TX chart specifies visual density. Approximate panchromatic exposure
            // with linear Rec. 709 luminance before mapping through its single density curve.
            let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
            let gray = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": luma, "inputGVector": luma, "inputBVector": luma
            ])
            styled = lookup(gray, table: KodakFilmLookTables.triX400)
        case .softNegative:
            styled = toneCurve(image, points: (0.055, 0.28, 0.52, 0.74, 0.955), saturation: 0.88)
        case .vividSlide:
            styled = toneCurve(image, points: (0.008, 0.17, 0.50, 0.84, 0.99), saturation: 1.16)
        case .classicMono:
            styled = toneCurve(image, points: (0.025, 0.20, 0.54, 0.82, 0.975), saturation: 0)
        case .neutral: return image
        }
        guard strength < 1 else { return styled }
        // Blend the rendered results in the linear working space, preserving the baseline at 0%.
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: styled, kCIInputTimeKey: strength
        ])
    }

    private func lookup(_ image: CIImage, table: Data) -> CIImage {
        image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table, "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": NegativePixels.display
        ])
    }

    private func toneCurve(_ image: CIImage, points: (black: CGFloat, shadow: CGFloat, middle: CGFloat, highlight: CGFloat, white: CGFloat), saturation: CGFloat) -> CIImage {
        return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: points.black), "inputPoint1": CIVector(x: 0.25, y: points.shadow),
                "inputPoint2": CIVector(x: 0.5, y: points.middle), "inputPoint3": CIVector(x: 0.75, y: points.highlight),
                "inputPoint4": CIVector(x: 1, y: points.white)
            ])
    }
}
#endif

#if os(iOS)
import AVFoundation
import CoreGraphics

/// Physical rear lenses avoid automatic virtual-camera switching after calibration.
nonisolated struct NegativeLens: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
}

nonisolated enum NegativeResolution: String, CaseIterable, Identifiable, Sendable {
    case hd = "720p", fullHD = "1080p", ultraHD = "4K"
    var id: Self { self }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd: .hd1280x720
        case .fullHD: .hd1920x1080
        case .ultraHD: .hd4K3840x2160
        }
    }
}

nonisolated struct NegativeCameraSettings: Equatable, Sendable {
    var lensID: String?
    var resolution: NegativeResolution = .hd
    var exposureBias: Float = 0
}

nonisolated struct NegativeCameraConfiguration: Sendable {
    let settings: NegativeCameraSettings
    let lenses: [NegativeLens]
    let resolutions: [NegativeResolution]
    let exposureRange: ClosedRange<Float>
    let supportsFocus: Bool
    let minimumFocusDistance: Int
}

nonisolated enum NegativeFocusCoordinates {
    /// Preview taps already account for letterboxing, pan and zoom; undo capture rotation only.
    static func sensorPoint(_ point: CGPoint, rotation: CGFloat) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        switch Int(rotation) {
        case 90: return CGPoint(x: point.y, y: 1 - point.x)
        case 180: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: return CGPoint(x: 1 - point.y, y: point.x)
        default: return point
        }
    }
}
#endif

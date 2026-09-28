#if DEBUG && os(iOS) && targetEnvironment(simulator)
import CoreImage

/// Opt-in simulator fixture exercises the camera UI through the same capture protocol.
/// It is excluded from device and release builds and never requests hardware permission.
nonisolated final class NegativeCameraFixture: NegativeCameraCapture, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FFFilm.camera.fixture")
    private var handler: (@Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void)?
    private var asset: NegativeAsset?
    func requestAccess() async -> Bool { true }
    func start(settings: NegativeCameraSettings, onConfiguration: @escaping @Sendable (NegativeCameraConfiguration) -> Void,
               onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void,
               onError: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            do {
                var effective = settings; effective.lensID = settings.lensID ?? "automatic"
                let extent = settings.resolution == .hd ? CGRect(x: 0, y: 0, width: 720, height: 1280) : CGRect(x: 0, y: 0, width: 1080, height: 1920)
                let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1, colorSpace: NegativePixels.linear)!).cropped(to: extent)
                let cg = try NegativePixels.preview(image, context: NegativePixels.context(), limit: extent.height)
                let frame = NegativeAsset(image: image, preview: cg)
                asset = frame; handler = onFrame
                onConfiguration(NegativeCameraConfiguration(settings: effective,
                    lenses: [NegativeLens(id: "automatic", titleKey: "negative.lens.automatic"), NegativeLens(id: "wide", titleKey: "negative.lens.wide"), NegativeLens(id: "ultra", titleKey: "negative.lens.ultraWide")],
                    resolutions: [.hd, .fullHD], exposureRange: -2...2, supportsFocus: true, minimumFocusDistance: 20,
                    automaticMacro: effective.lensID == "automatic"))
                onFrame(NegativeCameraFrame(asset: frame, positive: nil, frozenForSampling: false), {})
            } catch { onError("negative.error.camera") }
        }
    }
    func sampleWhenLocked() {
        queue.async { [self] in
            if let asset { handler?(NegativeCameraFrame(asset: asset, positive: nil, frozenForSampling: true), {}) }
        }
    }
    func setBase(_ value: NegativeBase?) {}
    func freeze(_ value: Bool) {}
    func stop() { queue.async { [self] in handler = nil; asset = nil } }
    func focus(_ point: CGPoint) {}
    func rotate(_ angle: CGFloat) {}
}
#endif

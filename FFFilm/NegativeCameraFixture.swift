#if DEBUG && os(iOS) && targetEnvironment(simulator)
import CoreImage

/// Opt-in simulator fixture exercises the camera UI through the same capture protocol.
/// It is excluded from device and release builds and never requests hardware permission.
nonisolated final class NegativeCameraFixture: NegativeCameraCapture, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FFFilm.camera.fixture")
    private var handler: (@Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void)?
    private var asset: NegativeAsset?
    private var timer: DispatchSourceTimer?
    private var frozen = false
    private var delivering = false
    private var generation = UUID()
    private let permissionScenario = ProcessInfo.processInfo.environment["NEGATIVE_UI_CAMERA_DENIED"]
    private var accessRequests = 0
    func requestAccess() async -> Bool {
        // Simulator-only cases cover initial denial and permission loss before restarting.
        queue.sync {
            accessRequests += 1
            return permissionScenario != "1" && (permissionScenario != "restart" || accessRequests == 1)
        }
    }
    func start(settings: NegativeCameraSettings, onConfiguration: @escaping @Sendable (NegativeCameraConfiguration) -> Void,
               onFrame: @escaping @Sendable (NegativeCameraFrame, @escaping @Sendable () -> Void) -> Void,
               onError: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            timer?.cancel(); timer = nil; frozen = false; delivering = false; generation = UUID()
            var effective = settings; effective.lensID = settings.lensID ?? "automatic"
            let extent = settings.resolution == .hd ? CGRect(x: 0, y: 0, width: 720, height: 1280) : CGRect(x: 0, y: 0, width: 1080, height: 1920)
            let background = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1, colorSpace: NegativePixels.linear)!).cropped(to: extent)
            // Unequal top/bottom patches make vertical flips and source-coordinate bugs visible.
            let top = CIImage(color: CIColor(red: 0.3, green: 0.15, blue: 0.1, alpha: 1, colorSpace: NegativePixels.linear)!)
                .cropped(to: CGRect(x: 0, y: extent.height * 0.8, width: extent.width, height: extent.height * 0.2))
            let bottom = CIImage(color: CIColor(red: 0.12, green: 0.24, blue: 0.3, alpha: 1, colorSpace: NegativePixels.linear)!)
                .cropped(to: CGRect(x: 0, y: 0, width: extent.width, height: extent.height * 0.2))
            let image = top.composited(over: bottom.composited(over: background))
            let frame = NegativeAsset(image: image)
            asset = frame; handler = onFrame
            onConfiguration(NegativeCameraConfiguration(settings: effective,
                lenses: [NegativeLens(id: "automatic", titleKey: "negative.lens.automatic"), NegativeLens(id: "wide", titleKey: "negative.lens.wide"), NegativeLens(id: "ultra", titleKey: "negative.lens.ultraWide")],
                resolutions: [.hd, .fullHD], supportsFocus: true, minimumFocusDistance: 20,
                automaticMacro: effective.lensID == "automatic"))
            onFrame(NegativeCameraFrame(asset: frame, frozenForSampling: false), {})
            if ProcessInfo.processInfo.environment["NEGATIVE_UI_CAMERA_STREAM"] == "1" {
                // Opt-in sustained traffic exercises canvas invalidation and GPU backpressure.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1.0 / 30)
                timer.setEventHandler { [weak self] in
                    guard let self, !self.frozen, !self.delivering else { return }
                    let phase = CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 2) / 2
                    let stripe = CIImage(color: CIColor(red: 0.15, green: 0.2, blue: 0.1, alpha: 1, colorSpace: NegativePixels.linear)!)
                        .cropped(to: CGRect(x: extent.width * phase, y: extent.height * 0.3, width: 8, height: extent.height * 0.4))
                    let next = NegativeAsset(image: stripe.composited(over: image))
                    self.asset = next; self.delivering = true
                    let generation = self.generation
                    self.handler?(NegativeCameraFrame(asset: next, frozenForSampling: false)) { [weak self] in
                        self?.queue.async { [weak self] in
                            if self?.generation == generation { self?.delivering = false }
                        }
                    }
                }
                self.timer = timer; timer.resume()
            }
        }
    }
    func sampleWhenLocked() {
        queue.async { [self] in
            frozen = true
            if let asset { handler?(NegativeCameraFrame(asset: asset, frozenForSampling: true), {}) }
        }
    }
    func setBase(_ value: NegativeBase?) {}
    func freeze(_ value: Bool) { queue.async { [self] in frozen = value } }
    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil; generation = UUID(); handler = nil; asset = nil
        }
    }
    deinit { timer?.cancel() }
    func focus(_ point: CGPoint) {}
    func rotate(_ angle: CGFloat) {}
}
#endif

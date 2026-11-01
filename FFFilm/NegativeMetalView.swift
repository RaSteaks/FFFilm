#if os(iOS)
import CoreImage
import MetalKit
import OSLog

/// On-demand, color-managed camera display. No timer, CGImage readback, or frame history.
final class NegativeMetalView: MTKView, MTKViewDelegate {
    private let worker: NegativeMetalRenderer?
    private var source: CIImage?
    private var base: NegativeBase?
    private var revision: UInt64 = 0
    private var inFlight = false
    private var reportedFailure = false
    var failed: (() -> Void)?

    init() {
        let metal = MTLCreateSystemDefaultDevice()
        worker = metal.flatMap { NegativeMetalRenderer(device: $0) }
        super.init(frame: .zero, device: metal)
        // A linear half-float drawable avoids a second 8-bit quantization of the negative.
        colorPixelFormat = .rgba16Float
        (layer as? CAMetalLayer)?.colorspace = NegativePixels.linear
        // One submitted job only needs double buffering, including when inspecting 4K detail.
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        framebufferOnly = false
        autoResizeDrawable = false
        isPaused = true; enableSetNeedsDisplay = true
        isUserInteractionEnabled = false
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: CIImage, base: NegativeBase?) {
        guard source !== image || self.base != base else { return }
        if source !== image { reportedFailure = false }
        source = image; self.base = base
        revision &+= 1
        setNeedsDisplay()
    }

    func updateResolution(zoom: CGFloat, displayScale: CGFloat) {
        guard let source, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(1, max(bounds.width / source.extent.width, bounds.height / source.extent.height)
                        * max(1, displayScale) * zoom)
        let size = CGSize(width: max(1, (source.extent.width * scale).rounded()),
                          height: max(1, (source.extent.height * scale).rounded()))
        guard drawableSize != size else { return }
        drawableSize = size
        revision &+= 1
        setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !inFlight, !reportedFailure, let source, window != nil,
              drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard let worker else { reportFailure(); return }
        guard let drawable = currentDrawable else { return }
        inFlight = true
        let submitted = revision
        // One GPU job plus the latest source only: a busy GPU never builds a stale-frame queue.
        worker.render(source, base: base, drawable: drawable) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                if !success { self.reportFailure() }
                else if self.revision != submitted { self.setNeedsDisplay() }
            }
        }
    }

    private func reportFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        failed?()
    }
}

/// All CI graph encoding/context initialization runs away from the UI and capture queues.
nonisolated final class NegativeMetalRenderer: @unchecked Sendable {
    /// The main actor hands this immutable drawable to one serial render job only.
    private struct Target: @unchecked Sendable { let drawable: CAMetalDrawable }
    private let queue = DispatchQueue(label: "FFFilm.negative.display", qos: .userInitiated)
    private let commands: MTLCommandQueue
    private var context: CIContext?
    #if DEBUG
    private let log = Logger(subsystem: "com.rasteaks.FFFilm", category: "NegativeCameraDisplay")
    private var logStart = CFAbsoluteTimeGetCurrent()
    private var completedFrames = 0
    private var gpuSeconds: Double = 0
    #endif

    init?(device: MTLDevice) {
        guard let commands = device.makeCommandQueue() else { return nil }
        self.commands = commands
    }

    /// Shared by onscreen and offscreen verification, with the same floating-point inversion.
    static func displayImage(_ image: CIImage, base: NegativeBase?, size: CGSize) -> CIImage {
        let converted = base.map { NegativePixels.positive(image, base: $0) } ?? image
        return converted.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
    }

    static func encode(_ image: CIImage, base: NegativeBase?, texture: MTLTexture,
                       context: CIContext, command: MTLCommandBuffer) throws {
        let size = CGSize(width: texture.width, height: texture.height)
        let output = displayImage(image, base: base, size: size)
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.colorSpace = NegativePixels.linear
        // Metal's first texture row is the top of the UIKit view.
        destination.isFlipped = true
        _ = try context.startTask(toRender: output, to: destination)
    }

    func render(_ image: CIImage, base: NegativeBase?, drawable: CAMetalDrawable,
                completion: @escaping @Sendable (Bool) -> Void) {
        let target = Target(drawable: drawable)
        queue.async { [self] in
            autoreleasepool {
                let drawable = target.drawable
                if context == nil {
                    context = CIContext(mtlCommandQueue: commands, options: [
                        .workingColorSpace: NegativePixels.linear, .workingFormat: CIFormat.RGBAf,
                        .cacheIntermediates: false
                    ])
                }
                guard let context, let command = commands.makeCommandBuffer() else { completion(false); return }
                do {
                    try Self.encode(image, base: base, texture: drawable.texture, context: context, command: command)
                    command.present(drawable)
                    command.addCompletedHandler { [self, image] command in
                        #if DEBUG
                        let elapsed = max(0, command.gpuEndTime - command.gpuStartTime)
                        queue.async { [self] in
                            completedFrames += 1; gpuSeconds += elapsed
                            let now = CFAbsoluteTimeGetCurrent(), interval = now - logStart
                            if interval >= 5 {
                                // GPU completion, not a claim of measured screen presentation latency.
                                log.debug("GPU completed_fps=\(Double(self.completedFrames) / interval, privacy: .public) gpu_ms=\(self.gpuSeconds * 1000 / Double(self.completedFrames), privacy: .public)")
                                logStart = now; completedFrames = 0; gpuSeconds = 0
                            }
                        }
                        #endif
                        // Keep the copied YUV planes alive until the GPU has finished reading them.
                        withExtendedLifetime(image) { completion(command.status == .completed) }
                    }
                    command.commit()
                } catch {
                    #if DEBUG
                    log.error("Camera display encoding failed")
                    #endif
                    completion(false)
                }
            }
        }
    }
}
#endif

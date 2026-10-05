#if os(macOS)
import SwiftUI
import AppKit

/// Zoom is relative to Fit. Buttons use reversible stops; native gestures stay continuous.
nonisolated enum FilmZoom {
    static let levels: [Double] = [1, 1.5, 2, 3, 4, 6, 8]

    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(levels.last!, max(levels.first!, value)) : 1
    }

    static func stepped(_ value: Double, direction: Int) -> Double {
        let current = clamped(value)
        return direction > 0
            ? levels.first { $0 > current + 0.000001 } ?? levels.last!
            : levels.last { $0 < current - 0.000001 } ?? levels.first!
    }

    /// Layout follows source geometry, so replacing a preview tier never moves the crop overlay.
    static func sourceSize(width: Int, height: Int, frame: FilmFrame?) -> CGSize {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard let frame else { return extent.size }
        let crop = FilmRenderer.pixelRect(frame.crop, extent: extent)
        return CGRect(origin: .zero, size: crop.size)
            .applying(CGAffineTransform(rotationAngle: frame.rotation * .pi / 180)).size
    }

    static func fittedSize(source: CGSize, viewport: CGSize, zoom: Double) -> CGSize {
        guard source.width > 0, source.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / source.width, viewport.height / source.height) * clamped(zoom)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

/// Coordinates stay in points and normalized source space, independent of the displayed bitmap.
nonisolated struct FilmCanvasLayout: Equatable {
    let imageSize: CGSize
    let viewport: CGSize
    var contentSize: CGSize {
        CGSize(width: max(imageSize.width, viewport.width), height: max(imageSize.height, viewport.height))
    }
    var imageOrigin: CGPoint {
        CGPoint(x: (contentSize.width - imageSize.width) / 2, y: (contentSize.height - imageSize.height) / 2)
    }

    func normalizedPoint(at point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - imageOrigin.x) / max(1, imageSize.width))),
                y: min(1, max(0, (point.y - imageOrigin.y) / max(1, imageSize.height))))
    }

    /// Keep the same source point under the pointer/viewport center, clamping only at scroll edges.
    func scrollOrigin(for point: CGPoint, at anchor: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, contentSize.width - viewport.width), max(0, imageOrigin.x + point.x * imageSize.width - anchor.x)),
                y: min(max(0, contentSize.height - viewport.height), max(0, imageOrigin.y + point.y * imageSize.height - anchor.y)))
    }
}

nonisolated struct FilmCanvasIdentity: Equatable {
    let sourceGeneration: Int
    let showStrip: Bool
    let frameID: UUID?
}

/// AppKit owns scroll offsets and desktop input only; FilmStore owns the zoom and remembered region.
struct FilmCanvasScrollView<Content: View>: NSViewRepresentable {
    let store: FilmStore
    let layout: FilmCanvasLayout
    let content: Content

    func makeNSView(context: Context) -> FilmZoomScrollView { FilmZoomScrollView() }

    func updateNSView(_ view: FilmZoomScrollView, context: Context) {
        let strip = store.showStrip
        view.zoomChanged = { store.zoom = $0 }
        view.centerChanged = { store.rememberCanvasCenter($0, strip: strip) }
        view.zoomEnabled = store.canZoom
        view.update(content: AnyView(content.frame(width: layout.contentSize.width, height: layout.contentSize.height)),
                    layout: layout, zoom: store.zoom,
                    identity: FilmCanvasIdentity(sourceGeneration: store.sourceGeneration, showStrip: strip,
                                                 frameID: strip ? nil : store.selected),
                    center: store.canvasCenter)
    }

    static func dismantleNSView(_ view: FilmZoomScrollView, coordinator: ()) {
        // Detaching a tab can reset AppKit bounds; that is not a user pan to remember.
        view.centerChanged = nil
        view.zoomChanged = nil
    }
}

/// Resize the hosting document instead of magnifying its layer, retaining screen-sized crop grips.
final class FilmZoomScrollView: NSScrollView {
    private let canvas = NSHostingView(rootView: AnyView(EmptyView()))
    private var canvasLayout: FilmCanvasLayout?
    private var identity: FilmCanvasIdentity?
    private var zoom = 1.0
    private var zoomAnchor: CGPoint?
    private var pendingCenter: CGPoint?
    private var adjustingLayout = false
    var zoomEnabled = true
    var zoomChanged: ((Double) -> Void)?
    var centerChanged: ((CGPoint) -> Void)?

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        canvas.isFlipped = true
        canvas.sizingOptions = []
        documentView = canvas
        canvas.autoresizingMask = []
        // Remember user scrolling, not layout-driven NSClipView bounds resets during tab removal.
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSScrollView.didLiveScrollNotification, object: self)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        // Do not delay the existing zero-distance crop drag or ordinary frame selection.
        doubleClick.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(doubleClick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func update(content: AnyView, layout: FilmCanvasLayout, zoom: Double, identity: FilmCanvasIdentity, center: CGPoint) {
        // GeometryReader can report zero while SwiftUI inserts/removes the workbench.
        // Wait for a real viewport instead of overwriting a previously saved source point.
        guard layout.viewport.width > 0, layout.viewport.height > 0,
              layout.imageSize.width > 0, layout.imageSize.height > 0 else { return }
        let changedCanvas = self.identity != identity
        let old = canvasLayout
        let anchor = zoomAnchor ?? CGPoint(x: (old?.viewport.width ?? layout.viewport.width) / 2,
                                           y: (old?.viewport.height ?? layout.viewport.height) / 2)
        let point = changedCanvas ? center : old?.normalizedPoint(at: CGPoint(
            x: contentView.bounds.minX + anchor.x, y: contentView.bounds.minY + anchor.y)) ?? center
        let needsLayout = changedCanvas || old != layout
        if changedCanvas { pendingCenter = point }
        adjustingLayout = true
        setFrameSize(layout.viewport)
        canvas.rootView = content
        canvas.frame = CGRect(origin: .zero, size: layout.contentSize)
        if needsLayout {
            let destination = changedCanvas || old?.viewport != layout.viewport
                ? CGPoint(x: layout.viewport.width / 2, y: layout.viewport.height / 2) : anchor
            contentView.scroll(to: layout.scrollOrigin(for: point, at: destination))
            reflectScrolledClipView(contentView)
        }
        canvasLayout = layout; self.identity = identity; self.zoom = zoom
        zoomAnchor = nil
        adjustingLayout = false
        if pendingCenter == nil { rememberCenter() }
        else { self.needsLayout = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, pendingCenter != nil { needsLayout = true }
    }

    override func layout() {
        adjustingLayout = true
        super.layout()
        // Attaching an NSHostingView can retile the clip view after updateNSView.
        // Apply the saved source center once the real window layout has settled.
        let restoring = pendingCenter != nil && window != nil
        if restoring, let center = pendingCenter, let canvasLayout {
            contentView.scroll(to: canvasLayout.scrollOrigin(for: center,
                at: CGPoint(x: canvasLayout.viewport.width / 2, y: canvasLayout.viewport.height / 2)))
            reflectScrolledClipView(contentView)
            pendingCenter = nil
        }
        adjustingLayout = false
        if restoring { rememberCenter() }
    }

    /// Native events share the same store value as toolbar/menu actions.
    func changeZoom(to value: Double, at anchor: CGPoint) {
        guard zoomEnabled else { return }
        let next = FilmZoom.clamped(value)
        guard next != zoom else { return }
        zoomAnchor = anchor
        zoom = next
        zoomChanged?(next)
    }

    private func anchor(for event: NSEvent) -> CGPoint {
        let point = contentView.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY)
    }

    override func magnify(with event: NSEvent) {
        changeZoom(to: zoom * (1 + Double(event.magnification)), at: anchor(for: event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            rememberCenter()
            return
        }
        let rate = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
        changeZoom(to: zoom * exp(Double(event.scrollingDeltaY) * rate), at: anchor(for: event))
    }

    @objc private func doubleClicked(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: contentView)
        changeZoom(to: zoom > 1 ? 1 : 2,
                   at: CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY))
    }

    @objc private func scrolled(_ notification: Notification) {
        guard !adjustingLayout else { return }
        rememberCenter()
    }

    private func rememberCenter() {
        guard let canvasLayout, contentView.bounds.width > 0, contentView.bounds.height > 0,
              abs(contentView.bounds.width - canvasLayout.viewport.width) < 0.001,
              abs(contentView.bounds.height - canvasLayout.viewport.height) < 0.001 else { return }
        centerChanged?(canvasLayout.normalizedPoint(at: CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)))
    }
}
#endif

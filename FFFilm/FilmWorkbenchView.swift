#if os(macOS)
import SwiftUI
import AppKit

struct FilmWorkbenchView: View {
    /// Owned by the embedding workbench (ContentView) so the film document and
    /// renderer survive workbench-tab switches; no longer a standalone window.
    @Bindable var store: FilmStore

    /// Split-pane minimums plus the divider: the narrowest window that keeps both
    /// panes visible. ContentView raises the window minimum to this while the
    /// film tab is showing, instead of the calculator's smaller default.
    static let canvasMinimumWidth: CGFloat = 500
    static let inspectorMinimumWidth: CGFloat = 300
    static var minimumWindowWidth: CGFloat { canvasMinimumWidth + inspectorMinimumWidth + 20 }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if store.info == nil {
                    ContentUnavailableView {
                        Label(filmText("胶片工作台", "Film workbench"), systemImage: "film")
                    } description: {
                        Text(filmText("导入 TIFF 或 Flextight FFF 整条扫描，分割、裁切并导出。", "Import a TIFF or Flextight FFF strip, split, crop and export frames."))
                    } actions: {
                        Button(filmText("导入扫描", "Import scan")) { store.openScan() }
                        Button(filmText("打开项目", "Open project")) { store.openProject() }
                    }
                } else {
                    canvasToolbar
                    sourceIdentity
                    FilmCanvas(store: store, drawMode: $store.drawMode)
                    frameStrip
                }
                if !store.notice.isEmpty {
                    HStack {
                        Text(store.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button { store.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(filmText("关闭提示", "Dismiss notice"))
                    }.padding(10)
                }
                if store.busy || store.exporting {
                    HStack { ProgressView().controlSize(.small); Text(store.exporting ? store.progress : filmText("正在处理…", "Processing…")); Spacer()
                        if store.exporting { Button(filmText("取消导出", "Cancel export")) { store.exportTask?.cancel() } }
                    }.padding(10)
                }
            }.frame(minWidth: Self.canvasMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
            inspector.frame(minWidth: Self.inspectorMinimumWidth, idealWidth: 330, maxWidth: 380)
        }
        .background(Palette.background)
        .toolbar { toolbar }
        .alert(filmText("操作未完成", "Operation failed"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(filmText("好", "OK")) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: store.showStrip) { _, _ in store.zoom = 1; store.refresh() }
        .focusedSceneValue(\.filmStore, store)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.openScan() } label: { Label(filmText("导入", "Import"), systemImage: "plus") }.disabled(store.busy || store.exporting || store.presentingSheet)
            Menu {
                Button(filmText("打开项目", "Open project")) { store.openProject() }
                Button(filmText("保存项目", "Save project")) { store.saveProject() }.disabled(store.info == nil)
                Button(filmText("项目另存为…", "Save project as…")) { store.saveProject(asNew: true) }.disabled(store.info == nil)
            } label: { Text(filmText("项目", "Project")) }.disabled(store.busy || store.exporting || store.presentingSheet)
            Button { store.undo() } label: { Label(filmText("撤销", "Undo"), systemImage: "arrow.uturn.backward") }.disabled(store.undoStack.isEmpty || store.busy || store.exporting || store.presentingSheet)
            Button { store.redo() } label: { Label(filmText("重做", "Redo"), systemImage: "arrow.uturn.forward") }.disabled(store.redoStack.isEmpty || store.busy || store.exporting || store.presentingSheet)
        }
    }
    private var canvasToolbar: some View {
        HStack {
            Picker(filmText("视图", "View"), selection: $store.showStrip) {
                Text(filmText("整条", "Strip")).tag(true)
                Text(filmText("单帧", "Frame")).tag(false)
            }.pickerStyle(.segmented).frame(width: 140)
            Spacer()
            Button { store.zoom = max(1, store.zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.help(filmText("缩小", "Zoom out"))
            Text("\(Int(store.zoom * 100))%").font(.caption.monospacedDigit())
            Button { store.zoom = min(8, store.zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.help(filmText("放大", "Zoom in"))
            Button(filmText("适合", "Fit")) { store.zoom = 1 }
        }.padding(10)
    }
    private var sourceIdentity: some View {
        // Keep scan identity beside the preview so frame selection never hides its source.
        VStack(alignment: .leading, spacing: 3) {
            Text(store.sourceFileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(filmText("相对主目录", "Relative to Home"))
                    .foregroundStyle(.secondary)
                Text(store.sourceRelativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.sourceRelativePath)
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel(filmText("相对主目录路径", "Path relative to Home") + ": " + store.sourceRelativePath)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
    private var frameStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.project.frames) { frame in
                    VStack(spacing: 5) {
                        Button { store.showStrip = false; store.select(frame.id) } label: {
                            VStack(spacing: 3) {
                                FilmFrameThumbnail(store: store, frame: frame)
                                Text(frame.name).font(.caption.monospacedDigit())
                            }.padding(5).background(store.selected == frame.id ? Color.white.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityLabel(filmText("选择帧", "Select frame") + " " + frame.name)
                        Toggle(filmText("批量选择", "Batch selection"), isOn: Binding(get: { store.selection.contains(frame.id) }, set: { if $0 { store.selection.insert(frame.id) } else { store.selection.remove(frame.id) } }))
                            .toggleStyle(.checkbox).font(.caption2)
                    }
                }
            }.padding(10)
        }.frame(height: 120).background(Palette.surface)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(filmText("胶片分割", "Film slicing")).font(.title2.weight(.semibold))
                if let info = store.info { Text("\(info.width) × \(info.height) · \(info.depth)-bit").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                // Source profile information remains relevant to faithful image export.
                if let info = store.info {
                    Text((info.hasProfile ? filmText("嵌入配置：", "Embedded profile: ") : filmText("指定输入：", "Assigned input: ")) + info.profileName)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(filmText("分帧与裁切", "Frames & crop")).font(.headline)
                cropControls
                Divider()
                exportControls
            }.padding(16)
        }.disabled(store.info == nil || store.busy || store.exporting || store.presentingSheet)
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(filmText("自动识别帧间隙", "Detect frame gaps")) { store.detect() }
            Picker(filmText("画布工具", "Canvas tool"), selection: $store.drawMode) {
                Text(filmText("选择", "Select")).tag(0)
                Text(filmText("框选新帧", "Draw frame")).tag(1)
            }.onChange(of: store.drawMode) { _, mode in if mode != 0 { store.showStrip = true } }
            HStack {
                Button(filmText("添加帧", "Add frame")) { store.addFrame() }
                Button(filmText("删除所选", "Remove selected")) { store.removeFrame() }.disabled(store.frame == nil)
            }
            if let frame = store.frame {
                TextField(filmText("帧名称", "Frame name"), text: Binding(get: { store.frame?.name ?? "" }, set: { name in store.updateFrame { $0.name = name } }))
                cropField("X", key: \.x, range: 0...max(0, 1 - frame.crop.width))
                cropField("Y", key: \.y, range: 0...max(0, 1 - frame.crop.height))
                cropField(filmText("宽度", "Width"), key: \.width, range: 0.002...max(0.002, 1 - frame.crop.x))
                cropField(filmText("高度", "Height"), key: \.height, range: 0.002...max(0.002, 1 - frame.crop.y))
                Menu(filmText("裁切比例", "Aspect ratio")) {
                    Button(filmText("自由（保持当前）", "Free (keep current)")) { }
                    ForEach([1.0, 1.5, 4.0 / 3.0, 16.0 / 9.0], id: \.self) { ratio in
                        Button(String(format: "%.2f:1", ratio)) {
                            guard let info = store.info else { return }
                            store.updateFrame { frame in
                                let height = frame.crop.width * Double(info.width) / (ratio * Double(info.height))
                                if height <= 1 - frame.crop.y { frame.crop.height = height }
                                else { frame.crop.width = frame.crop.height * ratio * Double(info.height) / Double(info.width) }
                            }
                        }
                    }
                }
                FilmSlider(label: filmText("旋转 / 拉直", "Rotate / straighten"), value: Binding(get: { store.frame?.rotation ?? 0 }, set: { value in store.updateFrame { $0.rotation = value } }), range: -180...180, store: store)
                HStack {
                    // Core Image uses a bottom-left origin: positive angles rotate counterclockwise.
                    Button("↶ 90°") { store.updateFrame { $0.rotation = ($0.rotation + 90).truncatingRemainder(dividingBy: 360) } }
                    Button("↷ 90°") { store.updateFrame { $0.rotation = ($0.rotation - 90).truncatingRemainder(dividingBy: 360) } }
                    Button(filmText("前移", "Earlier")) { store.moveFrame(-1) }
                    Button(filmText("后移", "Later")) { store.moveFrame(1) }
                }.controlSize(.small)
            }
        }
    }
    private func cropField(_ label: String, key: WritableKeyPath<FilmRect, Double>, range: ClosedRange<Double>) -> some View {
        FilmSlider(label: label, value: Binding(get: { store.frame?.crop[keyPath: key] ?? 0 }, set: { value in store.updateFrame { $0.crop[keyPath: key] = value } }), range: range, store: store)
    }
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(filmText("导出", "Export")).font(.headline)
            Picker(filmText("范围", "Scope"), selection: $store.exportScope) {
                Text(filmText("当前帧", "Current frame")).tag(0)
                Text(filmText("所选帧", "Selected frames")).tag(1)
                Text(filmText("全部帧", "All frames")).tag(2)
                Text(filmText("整条", "Whole strip")).tag(3)
            }
            Picker(filmText("格式", "Format"), selection: Binding(get: { store.project.exportJPEG }, set: { value in store.change { $0.exportJPEG = value } })) {
                Text("TIFF · 16-bit · Adobe RGB").tag(false)
                Text("JPEG · 8-bit · sRGB").tag(true)
            }
            if store.project.exportJPEG {
                FilmSlider(label: filmText("质量", "Quality"), value: Binding(get: { store.project.jpegQuality }, set: { value in store.change { $0.jpegQuality = value } }), range: 0.1...1, store: store)
            }
            if !store.failedExports.isEmpty {
                Button(filmText("重试失败项目…", "Retry failed exports…")) { store.export(scope: 4) }
            }
            Button(filmText("选择文件夹并导出…", "Choose folder & export…")) { store.export(scope: store.exportScope) }
                .disabled(store.exportScope != 3 && store.frame == nil)
        }
    }
}

private struct FilmThumbnailRequest: Equatable {
    let frame: FilmFrame
    let sourceGeneration: Int
}

private struct FilmFrameThumbnail: View {
    let store: FilmStore
    let frame: FilmFrame
    @State private var rotated: CGImage?

    var body: some View {
        Group {
            if frame.rotation != 0 {
                if let rotated {
                    Image(decorative: rotated, scale: 1).resizable().scaledToFit().frame(width: 96, height: 60)
                } else {
                    ProgressView().frame(width: 96, height: 60)
                }
            } else if let overview = store.overview,
                      let crop = overview.cropping(to: CGRect(x: frame.crop.x * Double(overview.width), y: frame.crop.y * Double(overview.height), width: frame.crop.width * Double(overview.width), height: frame.crop.height * Double(overview.height)).integral) {
                Image(decorative: crop, scale: 1).resizable().scaledToFit().frame(width: 96, height: 60)
            }
        }
        .task(id: FilmThumbnailRequest(frame: frame, sourceGeneration: store.sourceGeneration)) {
            // Rotated thumbnails use the same geometry as frame preview/export and
            // refresh when either the frame or underlying source changes.
            rotated = nil
            guard frame.rotation != 0, store.info != nil else { return }
            do {
                let image = try await store.renderer.thumbnail(frame: frame)
                if !Task.isCancelled { rotated = image }
            } catch { rotated = nil }
        }
    }
}

/// Native numeric fields provide a keyboard alternative to every adjustment slider.
struct FilmSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let store: FilmStore
    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                TextField(label, value: $value, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 78).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            }
            Slider(value: $value, in: range, onEditingChanged: { if $0 { store.beginEdit() } else { store.endEdit() } }).accessibilityLabel(label)
        }
    }
}

private struct FilmCanvasBorder: Equatable {
    let id: UUID
    let edge: FilmCropEdge
}

struct FilmCanvas: View {
    let store: FilmStore
    @Binding var drawMode: Int
    @State private var dragRect: CGRect?
    @State private var dragTarget: (id: UUID, crop: FilmRect, edge: FilmCropEdge?)?
    @State private var hoveredBorder: FilmCanvasBorder?

    private func target(at point: CGPoint, in size: CGSize) -> (id: UUID, crop: FilmRect, edge: FilmCropEdge?)? {
        let frames = store.project.frames
        // Give the selected frame's border priority when crops overlap.
        if let selected = frames.first(where: { $0.id == store.selected }),
           let edge = Self.edge(at: point, of: selected.crop, in: size) {
            return (selected.id, selected.crop, edge)
        }
        for frame in frames.reversed() {
            if let edge = Self.edge(at: point, of: frame.crop, in: size) {
                return (frame.id, frame.crop, edge)
            }
        }
        let normalized = CGPoint(x: point.x / size.width, y: point.y / size.height)
        guard let frame = frames.last(where: { $0.crop.cgRect.contains(normalized) }) else { return nil }
        return (frame.id, frame.crop, nil)
    }

    static func edge(at point: CGPoint, of crop: FilmRect, in size: CGSize) -> FilmCropEdge? {
        let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height,
                          width: crop.width * size.width, height: crop.height * size.height)
        // A border against the canvas edge needs a deeper inner hit band: its outer half is clipped.
        let candidates: [(FilmCropEdge, CGFloat, CGFloat)] = [
            (.left, abs(point.x - rect.minX), rect.minX <= 0.5 ? 24 : 8),
            (.right, abs(point.x - rect.maxX), rect.maxX >= size.width - 0.5 ? 24 : 8),
            (.top, abs(point.y - rect.minY), rect.minY <= 0.5 ? 24 : 8),
            (.bottom, abs(point.y - rect.maxY), rect.maxY >= size.height - 0.5 ? 24 : 8)
        ]
        return candidates.filter { edge, distance, limit in
            guard distance <= limit else { return false }
            switch edge {
            case .left, .right: return point.y >= rect.minY - 8 && point.y <= rect.maxY + 8
            case .top, .bottom: return point.x >= rect.minX - 8 && point.x <= rect.maxX + 8
            }
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private func borderFeedback(for frame: FilmFrame, in size: CGSize) -> some View {
        let rect = CGRect(x: frame.crop.x * size.width, y: frame.crop.y * size.height,
                          width: frame.crop.width * size.width, height: frame.crop.height * size.height)
        return ZStack {
            ForEach(FilmCropEdge.allCases, id: \.self) { edge in
                // Keep feedback locked to the grabbed edge throughout a drag.
                let active = dragTarget.flatMap { target -> FilmCanvasBorder? in
                    target.edge.map { FilmCanvasBorder(id: target.id, edge: $0) }
                }
                let highlighted = (active ?? hoveredBorder) == FilmCanvasBorder(id: frame.id, edge: edge)
                let vertical = edge == .left || edge == .right
                let position = Self.gripPosition(for: edge, in: rect, canvas: size)
                // The inset grips remain visible and draggable when a full-size crop meets the canvas edge.
                if rect.width >= 40 && rect.height >= 40 {
                    Capsule().fill(highlighted ? .yellow : .white)
                        .overlay(Capsule().stroke(.black.opacity(0.8), lineWidth: 1))
                        .frame(width: vertical ? 6 : 30, height: vertical ? 30 : 6)
                        .position(position)
                }
                if highlighted {
                    Path { path in
                        switch edge {
                        case .left, .right:
                            let x = min(size.width - 2, max(2, edge == .left ? rect.minX : rect.maxX))
                            path.move(to: CGPoint(x: x, y: rect.minY))
                            path.addLine(to: CGPoint(x: x, y: rect.maxY))
                        case .top, .bottom:
                            let y = min(size.height - 2, max(2, edge == .top ? rect.minY : rect.maxY))
                            path.move(to: CGPoint(x: rect.minX, y: y))
                            path.addLine(to: CGPoint(x: rect.maxX, y: y))
                        }
                    }.stroke(.yellow, lineWidth: 3)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private static func gripPosition(for edge: FilmCropEdge, in rect: CGRect, canvas: CGSize) -> CGPoint {
        let x = edge == .left ? rect.minX : edge == .right ? rect.maxX : rect.midX
        let y = edge == .top ? rect.minY : edge == .bottom ? rect.maxY : rect.midY
        return CGPoint(x: min(canvas.width - 10, max(10, x)), y: min(canvas.height - 10, max(10, y)))
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                if let image = store.image {
                    let scale = min(viewport.size.width / CGFloat(image.width), viewport.size.height / CGFloat(image.height)) * store.zoom
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                        if store.showStrip {
                            ForEach(store.project.frames) { frame in
                                Rectangle().stroke(store.selected == frame.id ? .white : .gray, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                                    .frame(width: frame.crop.width * size.width, height: frame.crop.height * size.height)
                                    .overlay(alignment: .topLeading) { Text(frame.name).font(.caption).padding(3).background(.black.opacity(0.7)) }
                                    .offset(x: frame.crop.x * size.width, y: frame.crop.y * size.height)
                                    .allowsHitTesting(false)
                            }
                            if drawMode == 0, let selected = store.frame {
                                borderFeedback(for: selected, in: size)
                            }
                        }
                        if let dragRect { Rectangle().stroke(.yellow, lineWidth: 2).frame(width: dragRect.width, height: dragRect.height).offset(x: dragRect.minX, y: dragRect.minY) }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard store.showStrip, !store.busy, !store.exporting else { return }
                        if drawMode == 0 {
                            if dragTarget == nil, let target = target(at: value.startLocation, in: size) {
                                store.select(target.id)
                                dragTarget = target
                                store.beginEdit()
                            }
                            if let target = dragTarget {
                                store.updateFrame { frame in
                                    if let edge = target.edge {
                                        let delta: CGFloat = switch edge {
                                        case .left, .right: value.translation.width / size.width
                                        case .top, .bottom: value.translation.height / size.height
                                        }
                                        frame.crop = target.crop.resizing(edge, by: delta)
                                    } else {
                                        frame.crop.x = min(1 - target.crop.width, max(0, target.crop.x + value.translation.width / size.width))
                                        frame.crop.y = min(1 - target.crop.height, max(0, target.crop.y + value.translation.height / size.height))
                                    }
                                }
                            }
                        } else {
                            let x = min(size.width, max(0, min(value.startLocation.x, value.location.x)))
                            let y = min(size.height, max(0, min(value.startLocation.y, value.location.y)))
                            dragRect = CGRect(x: x, y: y, width: min(size.width - x, abs(value.location.x - value.startLocation.x)), height: min(size.height - y, abs(value.location.y - value.startLocation.y)))
                        }
                    }.onEnded { _ in
                        defer {
                            dragRect = nil
                            dragTarget = nil
                            hoveredBorder = nil
                            NSCursor.arrow.set()
                            store.endEdit()
                        }
                        guard let rectangle = dragRect, rectangle.width >= 3, rectangle.height >= 3 else { return }
                        let crop = FilmRect(x: rectangle.minX / size.width, y: rectangle.minY / size.height, width: rectangle.width / size.width, height: rectangle.height / size.height)
                        guard crop.valid else { return }
                        if drawMode == 1 { store.addFrame(crop) }
                        drawMode = 0
                    })
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard drawMode == 0, store.showStrip, !store.busy, !store.exporting else {
                            hoveredBorder = nil
                            NSCursor.arrow.set()
                            return
                        }
                        if let edge = dragTarget?.edge {
                            switch edge {
                            case .left, .right: NSCursor.resizeLeftRight.set()
                            case .top, .bottom: NSCursor.resizeUpDown.set()
                            }
                            return
                        }
                        switch phase {
                        case .active(let point):
                            if let target = target(at: point, in: size), let edge = target.edge {
                                hoveredBorder = FilmCanvasBorder(id: target.id, edge: edge)
                                switch edge {
                                case .left, .right: NSCursor.resizeLeftRight.set()
                                case .top, .bottom: NSCursor.resizeUpDown.set()
                                }
                            } else {
                                hoveredBorder = nil
                                NSCursor.arrow.set()
                            }
                        case .ended:
                            hoveredBorder = nil
                            NSCursor.arrow.set()
                        }
                    }
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
                }
            }
        }
        .background(.black.opacity(0.4))
        .onChange(of: drawMode) { _, _ in
            hoveredBorder = nil
            NSCursor.arrow.set()
        }
    }
}

extension FocusedValues { @Entry var filmStore: FilmStore? }

struct FilmCommands: Commands {
    // The film workbench is now a tab of the main window; these commands act on
    // the focused scene's film store whenever that tab is showing.
    @FocusedValue(\.filmStore) private var store
    var body: some Commands {
        CommandMenu(filmText("胶片", "Film")) {
            Button(filmText("导入扫描…", "Import scan…")) { store?.openScan() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store == nil || store?.busy == true || store?.exporting == true || store?.presentingSheet == true)
            Button(filmText("保存项目", "Save project")) { store?.saveProject() }.keyboardShortcut("s").disabled(store?.info == nil || store?.busy == true || store?.exporting == true || store?.presentingSheet == true)
            Button(filmText("撤销胶片调整", "Undo film edit")) { store?.undo() }.keyboardShortcut("z").disabled(store?.undoStack.isEmpty != false || store?.busy == true || store?.exporting == true || store?.presentingSheet == true)
            Button(filmText("重做胶片调整", "Redo film edit")) { store?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store?.redoStack.isEmpty != false || store?.busy == true || store?.exporting == true || store?.presentingSheet == true)
        }
    }
}

/// Retain the native window delegate and forward unhandled responsibilities to SwiftUI.
struct FilmWindowGuard: NSViewRepresentable {
    let store: FilmStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            store.window = window
            if context.coordinator.original == nil && window.delegate !== context.coordinator { context.coordinator.original = window.delegate; window.delegate = context.coordinator }
            window.isDocumentEdited = store.dirty
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let store: FilmStore
        weak var original: NSWindowDelegate?
        private var confirmedClose = false
        init(store: FilmStore) { self.store = store }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // Consume one approved close without asking again when the user chose Don't Save.
            if confirmedClose { confirmedClose = false; return true }
            guard !store.presentingSheet else { return false }
            guard !store.busy, !store.exporting else { NSSound.beep(); return false }
            guard store.dirty else { return true }
            store.requestDiscard { accepted in
                if accepted { self.confirmedClose = true; sender.close() }
            }
            return false
        }
        func windowWillClose(_ notification: Notification) {
            store.renderTask?.cancel()
            Task { await store.renderer.close() }
            original?.windowWillClose?(notification)
        }
    }
}
#endif

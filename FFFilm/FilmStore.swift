#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Quit waits for every independent document's asynchronous save/discard decision.
@MainActor final class FilmAppDelegate: NSObject, NSApplicationDelegate {
    static let stores = NSHashTable<FilmStore>.weakObjects()
    private var checkingQuit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read the compiled native asset so a stale LaunchServices/Dock bitmap
        // cannot keep a removed icon active when this build starts.
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
           let icon = Bundle.main.image(forResource: name) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let documents = Self.stores.allObjects.filter { $0.window != nil }
        guard !documents.contains(where: { $0.busy || $0.exporting || $0.presentingSheet }) else { NSSound.beep(); return .terminateCancel }
        guard documents.contains(where: \.dirty) else { return .terminateNow }
        guard !checkingQuit else { return .terminateCancel }
        checkingQuit = true
        func check(_ index: Int) {
            guard index < documents.count else { checkingQuit = false; sender.reply(toApplicationShouldTerminate: true); return }
            documents[index].requestDiscard { accepted in
                if accepted { check(index + 1) }
                else { self.checkingQuit = false; sender.reply(toApplicationShouldTerminate: false) }
            }
        }
        DispatchQueue.main.async { check(0) }
        return .terminateLater
    }
}

@MainActor @Observable
final class FilmStore {
    var project = FilmProject()
    var selected: UUID?
    var selection: Set<UUID> = []
    var image: CGImage?
    var overview: CGImage?
    var info: FilmRenderer.SourceInfo?
    var showStrip = true
    // The canvas tool and export scope live here, not in the view's @State:
    // switching workbench tabs removes the film view, which would reset them.
    var drawMode = 0
    var exportScope = 0
    var busy = false
    var exporting = false
    var presentingSheet = false
    var sourceGeneration = 0
    var progress = ""
    var failedExports: [FilmFrame?] = []
    var failedExportProject: FilmProject?
    var error: String?
    var notice = ""
    var projectURL: URL?
    var savedProject = FilmProject()
    var undoStack: [FilmProject] = []
    var redoStack: [FilmProject] = []
    var zoom = 1.0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored let renderer = FilmRenderer()
    @ObservationIgnored var renderTask: Task<Void, Never>?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored private var renderRevision = 0
    @ObservationIgnored private var displayedProject: FilmProject?
    @ObservationIgnored private var displayedFrameID: UUID?
    @ObservationIgnored private var editStart: FilmProject?
    var dirty: Bool { project != savedProject }
    var canImportScan: Bool { !busy && !exporting && !presentingSheet }
    var frame: FilmFrame? { project.frames.first { $0.id == selected } }
    var targets: Set<UUID> { selection.isEmpty ? Set([selected].compactMap { $0 }) : selection }
    var sourceFileName: String { URL(fileURLWithPath: project.sourcePath).lastPathComponent }
    var sourceRelativePath: String {
        Self.relativeSourcePath(project.sourcePath, from: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Show source paths relative to the user's home, including files on other volumes.
    static func relativeSourcePath(_ sourcePath: String, from homePath: String) -> String {
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.pathComponents
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL.pathComponents
        let sharedCount = zip(source, home).prefix { $0.0 == $0.1 }.count
        let stepsUp = Array(repeating: "..", count: home.count - sharedCount)
        return (stepsUp + Array(source.dropFirst(sharedCount))).joined(separator: "/")
    }

    init() {
        // Slicing does not read or mutate the retired curve preset library.
        FilmAppDelegate.stores.add(self)
    }

    func select(_ id: UUID) { selected = id; refresh() }

    /// Coalesce direct manipulation into a single undo entry instead of one entry per pixel.
    func beginEdit() { if editStart == nil { editStart = project } }
    func endEdit() {
        if let previous = editStart, previous != project { record(previous) }
        editStart = nil
    }
    private func record(_ previous: FilmProject) {
        undoStack.append(previous)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func change(_ body: (inout FilmProject) -> Void) {
        let previous = project
        body(&project)
        guard project.valid else { project = previous; return }
        if previous != project && editStart == nil { record(previous) }
        refresh()
    }
    func updateFrame(_ body: (inout FilmFrame) -> Void) {
        guard let index = project.frames.firstIndex(where: { $0.id == selected }) else { return }
        change { body(&$0.frames[index]) }
    }
    func undo() {
        guard !busy, !exporting, !presentingSheet else { return }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project); project = previous; reconcile(); refresh()
    }
    func redo() {
        guard !busy, !exporting, !presentingSheet else { return }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project); project = next; reconcile(); refresh()
    }
    private func reconcile() {
        if !project.frames.contains(where: { $0.id == selected }) { selected = project.frames.first?.id }
        selection.formIntersection(Set(project.frames.map(\.id)))
    }

    func refresh() {
        renderTask?.cancel(); renderRevision += 1
        let revision = renderRevision, snapshot = project, target = showStrip ? nil : frame
        guard info != nil else { return }
        // Import and unchanged view state already have a completed image to display.
        if image != nil, displayedProject == snapshot, displayedFrameID == target?.id { return }
        if target == nil, !snapshot.frames.contains(where: { $0.rotation != 0 }), let overview {
            image = overview; displayedProject = snapshot; displayedFrameID = nil
            return
        }
        renderTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(70))
                try Task.checkCancellation()
                let rendered = try await renderer.render(project: snapshot, frame: target)
                guard !Task.isCancelled, revision == renderRevision else { return }
                image = rendered
                displayedProject = snapshot; displayedFrameID = target?.id
            } catch is CancellationError { } catch {
                if !Task.isCancelled, revision == renderRevision { self.error = error.localizedDescription }
            }
        }
    }

    /// A single presentation gate covers every file panel and unsaved-work prompt.
    private func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !presentingSheet else { completion(.cancel); return }
        presentingSheet = true
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            // AppKit can invoke this handler while the file sheet is still onscreen.
            // Dismiss it before decoding or presenting a follow-up sheet.
            panel.orderOut(nil)
            self.presentingSheet = false
            completion(response)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finished) }
        else { panel.begin(completionHandler: finished) }
    }

    func requestDiscard(_ completion: @escaping (Bool) -> Void) {
        guard !presentingSheet else { completion(false); return }
        guard dirty else { completion(true); return }
        guard let window else { completion(false); return }
        presentingSheet = true
        let alert = NSAlert()
        alert.messageText = filmText("保存胶片项目？", "Save film project?")
        alert.informativeText = filmText("当前调整尚未保存。", "Your current adjustments have not been saved.")
        alert.addButton(withTitle: filmText("保存", "Save"))
        alert.addButton(withTitle: filmText("取消", "Cancel"))
        alert.addButton(withTitle: filmText("不保存", "Don't Save"))
        alert.beginSheetModal(for: window) { response in
            // A Save decision can immediately open another sheet on this window.
            alert.window.orderOut(nil)
            self.presentingSheet = false
            switch response {
            case .alertFirstButtonReturn: self.saveProject(completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    func openScan() {
        guard !busy, !exporting, !presentingSheet else { return }
        requestDiscard { accepted in
            guard accepted else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.tiff, UTType(filenameExtension: "fff") ?? .data]
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            self.present(panel) { response in
                if response == .OK, let url = panel.url { self.loadSource(url, restoring: nil) }
            }
        }
    }

    /// Finder drops use the same discard/profile/import workflow as the open panel.
    @discardableResult func importDroppedScans(_ urls: [URL]) -> Bool {
        guard canImportScan else { return false }
        guard urls.count == 1 else {
            notice = filmText("请一次拖入一个扫描文件。", "Drop one scan file at a time.")
            return false
        }
        let url = urls[0]
        guard url.isFileURL, ["tif", "tiff", "fff"].contains(url.pathExtension.lowercased()) else {
            notice = filmText("请拖入 TIFF 或 Flextight FFF 扫描文件。", "Drop a TIFF or Flextight FFF scan file.")
            return false
        }
        // Keep the drop's sandbox access alive while an unsaved-project sheet is open.
        let access = url.startAccessingSecurityScopedResource()
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            if access { url.stopAccessingSecurityScopedResource() }
            notice = filmText("无法访问扫描文件，请从 Finder 重新拖入文件。", "Cannot access the scan. Drag the file from Finder again.")
            return false
        }
        requestDiscard { accepted in
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard accepted, self.canImportScan else { return }
            self.loadSource(url, restoring: nil)
        }
        return true
    }

    func loadSource(_ url: URL, restoring: FilmProject?) {
        busy = true
        renderTask?.cancel(); renderRevision += 1
        // Acquire before leaving the drop callback, then retain through probe/profile/load.
        let importAccess = url.startAccessingSecurityScopedResource()
        Task {
            defer { if importAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                var next = restoring ?? FilmProject()
                let probe = try await renderer.probe(url)
                if !probe.hasProfile && restoring == nil {
                    let alert = NSAlert()
                    alert.messageText = filmText("扫描文件没有嵌入色彩配置", "Scan has no embedded color profile")
                    alert.informativeText = filmText("请选择扫描软件实际输出的配置，或导入匹配的扫描仪 RGB ICC。仅知道扫描是线性数据，不足以选择 Linear sRGB。", "Choose the scanner software's actual output profile, or load a matching scanner RGB ICC. Linear data alone does not imply Linear sRGB.")
                    let choices = ["sRGB", "Adobe RGB", "Linear sRGB", "Display P3", filmText("选择 ICC…", "Choose ICC…"), filmText("取消", "Cancel")]
                    for name in choices { alert.addButton(withTitle: name) }
                    let decision: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                        if let window {
                            alert.beginSheetModal(for: window) { response in
                                // A custom profile opens a file panel after this choice.
                                alert.window.orderOut(nil)
                                continuation.resume(returning: response)
                            }
                        }
                        else { continuation.resume(returning: .abort) }
                    }
                    guard decision != .abort else { throw FilmFailure(message: filmText("需要选择输入色彩空间。", "An input color space must be selected.")) }
                    let response = decision.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    guard (0..<5).contains(response) else {
                        throw FilmFailure(message: filmText("导入已取消，未指定输入配置。", "Import cancelled without assigning an input profile."))
                    }
                    if response == 4 {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
                        let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                            present(panel) { continuation.resume(returning: $0) }
                        }
                        guard result == .OK, let profileURL = panel.url else {
                            throw FilmFailure(message: filmText("导入已取消，未指定输入配置。", "Import cancelled without assigning an input profile."))
                        }
                        let access = profileURL.startAccessingSecurityScopedResource()
                        defer { if access { profileURL.stopAccessingSecurityScopedResource() } }
                        next.inputProfile = try Data(contentsOf: profileURL)
                        next.inputSpace = "Custom ICC"
                    } else { next.inputSpace = choices[response] }
                }
                // A profile choice is made before the full scan is decoded.
                let decoded = try await renderer.load(url, inputSpace: next.inputSpace, inputProfile: next.inputProfile)
                next.sourcePath = url.path
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                // Some volumes cannot issue persistent bookmarks. Keep the live import usable
                // and require explicit reselection when that project is reopened.
                var bookmarkNotice = ""
                do { next.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
                catch {
                    next.bookmark = nil
                    bookmarkNotice = filmText("此位置无法保存持久访问权限；重开项目时需重新选择扫描文件。", "This location cannot retain file access; reselect the scan when reopening the project.")
                }
                if restoring == nil { next.frames = [FilmFrame(name: "01")] }
                // The base preview is already materialized; only saved rotations need
                // another render, and that render reads the bounded preview cache.
                let base = try await renderer.render(project: FilmProject(), frame: nil)
                let initial = next.frames.contains(where: { $0.rotation != 0 })
                    ? try await renderer.render(project: next, frame: nil) : base
                failedExports = []; failedExportProject = nil
                // A newly imported scan is an unsaved document even before geometry edits.
                project = next; info = decoded; savedProject = restoring == nil ? FilmProject() : next
                sourceGeneration += 1
                if restoring == nil { projectURL = nil }
                undoStack.removeAll(); redoStack.removeAll(); selection.removeAll()
                selected = next.frames.first?.id; showStrip = true; zoom = 1; drawMode = 0; exportScope = 0
                // Both views share the untouched scan preview until edits require compositing.
                overview = base; image = initial
                displayedProject = next; displayedFrameID = nil
                // Preserve the FFF compatibility caveat as actionable export guidance.
                notice = decoded.isFFF ? filmText("FFF 兼容性有限，请在导出前对照原始扫描检查图像完整性与色彩。", "FFF compatibility is limited. Check image completeness and color against the original scan before exporting.") : bookmarkNotice
                busy = false
            } catch {
                info = nil; image = nil; overview = nil
                displayedProject = nil; displayedFrameID = nil
                // Keep conflicting actions disabled until renderer cleanup has finished.
                await renderer.close()
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    func detect() {
        busy = true
        Task {
            do {
                let rectangles = try await renderer.detectFrames()
                if rectangles.isEmpty { notice = filmText("未找到可靠帧间隙，请手动框选或调整现有裁切框。", "No reliable frame gaps found. Draw frames or edit the existing crop.") }
                else if exceedsFrameLimit(adding: rectangles.count) {
                    // change() reverts the whole mutation when the project turns invalid,
                    // so an over-limit detection result must be refused up front.
                    notice = frameLimitNotice
                }
                else {
                    change { project in
                        // Preserve prior edits: detection adds candidates instead of replacing existing frames.
                        if project.hasPlaceholderFrame {
                            project.frames.removeAll()
                        }
                        // Manual and detected frames use the same numbering after deletions.
                        for rectangle in rectangles {
                            project.frames.append(FilmFrame(name: project.nextFrameName, crop: rectangle))
                        }
                    }
                    selected = project.frames.first?.id
                    notice = filmText("已生成候选帧，请检查并修正边界。", "Candidate frames added. Check and refine their boundaries.")
                }
            } catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
    /// The untouched placeholder frame is replaced, not appended to.
    private func exceedsFrameLimit(adding count: Int) -> Bool {
        let replacing = project.hasPlaceholderFrame
        return (replacing ? 0 : project.frames.count) + count > FilmProject.maximumFrames
    }
    private var frameLimitNotice: String {
        String(format: filmText("添加帧会超过 %d 帧上限，未添加。", "Adding frames would exceed the %d-frame project limit; none were added."), FilmProject.maximumFrames)
    }

    func addFrame(_ rect: FilmRect? = nil) {
        guard canImportScan else { return }
        // A full-scan placeholder has no next boundary; the first Add assigns a real slice.
        let replacing = rect == nil && info != nil && project.hasPlaceholderFrame
        // Reject before changing selection: change() would otherwise restore the project
        // while leaving a nonexistent new frame selected.
        guard replacing || project.frames.count < FilmProject.maximumFrames else { notice = frameLimitNotice; return }
        let crop: FilmRect
        if let rect {
            // Draw frame remains the precise way to place a first frame or correct detection.
            guard rect.valid else { return }
            crop = rect
        } else if let info {
            guard let next = info.layout.nextCrop(after: replacing ? nil : project.frames.last?.crop,
                width: info.width, height: info.height, override: project.filmFormat) else {
                notice = filmText("扫描剩余长度不足以添加完整帧，请调整上一帧边界或手动框选。", "Not enough scan remains for a full frame. Adjust the previous boundary or draw a frame.")
                return
            }
            crop = next
        } else { crop = FilmRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
        // A single sheet already filling the scan is a frame, not a repeatable placeholder.
        if replacing && crop == project.frames[0].crop {
            notice = filmText("扫描剩余长度不足以添加完整帧，请调整上一帧边界或手动框选。", "Not enough scan remains for a full frame. Adjust the previous boundary or draw a frame.")
            return
        }
        let frame = FilmFrame(name: replacing ? project.frames[0].name : project.nextFrameName, crop: crop)
        change {
            if replacing { $0.frames.removeAll() }
            $0.frames.append(frame)
        }
        guard project.frames.contains(where: { $0.id == frame.id }) else { return }
        reconcile(); selected = frame.id; refresh()
    }
    func removeFrame() {
        let ids = targets
        change { $0.frames.removeAll { ids.contains($0.id) } }; reconcile(); refresh()
    }
    func moveFrame(_ offset: Int) {
        guard let index = project.frames.firstIndex(where: { $0.id == selected }), project.frames.indices.contains(index + offset) else { return }
        change { $0.frames.swapAt(index, index + offset) }
    }
    func saveProject(asNew: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !busy, !exporting, !presentingSheet else { completion(false); return }
        // A failed import can leave unsaved project data without a decoded source.
        // Never let the close/quit confirmation treat that state as a successful save.
        guard info != nil else { completion(!dirty); return }
        if let destination = projectURL, !asNew { completion(writeProject(to: destination)); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.rasteaks.fffilm-project", conformingTo: .json)]
        panel.nameFieldStringValue = URL(fileURLWithPath: project.sourcePath).deletingPathExtension().lastPathComponent + ".fffilm"
        present(panel) { response in
            guard response == .OK, let destination = panel.url else { completion(false); return }
            completion(self.writeProject(to: destination))
        }
    }
    @discardableResult func writeProject(to destination: URL) -> Bool {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: destination, options: .atomic)
            projectURL = destination; savedProject = project
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func openProject() {
        guard !busy, !exporting, !presentingSheet else { return }
        requestDiscard { accepted in
            guard accepted else { return }
            let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(exportedAs: "com.rasteaks.fffilm-project", conformingTo: .json)]
            self.present(panel) { response in
                guard response == .OK, let url = panel.url else { return }
                self.readProject(url)
            }
        }
    }
    private func readProject(_ url: URL) {
        do {
            let decoded = try JSONDecoder().decode(FilmProject.self, from: Data(contentsOf: url))
            guard decoded.valid else { throw FilmFailure(message: filmText("项目版本或参数无效。", "Invalid project version or parameters.")) }
            var sourceURL = URL(fileURLWithPath: decoded.sourcePath)
            if let bookmark = decoded.bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { sourceURL = resolved }
            }
            let access = sourceURL.startAccessingSecurityScopedResource()
            let exists = FileManager.default.fileExists(atPath: sourceURL.path)
            if access { sourceURL.stopAccessingSecurityScopedResource() }
            if !exists || decoded.bookmark == nil {
                let locate = NSOpenPanel(); locate.message = filmText("请重新定位原始扫描文件", "Locate the original scan file")
                locate.allowedContentTypes = [.tiff, UTType(filenameExtension: "fff") ?? .data]
                present(locate) { response in
                    guard response == .OK, let replacement = locate.url else { return }
                    self.projectURL = url; self.loadSource(replacement, restoring: decoded)
                }
            } else { projectURL = url; loadSource(sourceURL, restoring: decoded) }
        } catch { self.error = error.localizedDescription }
    }

    func export(scope: Int) {
        guard !busy, !exporting, !presentingSheet else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        present(panel) { response in
            guard response == .OK, let directory = panel.url else { return }
            self.export(scope: scope, directory: directory)
        }
    }
    func export(scope: Int, directory: URL) {
        guard !busy, !exporting, !presentingSheet else { return }
        let snapshot = scope == 4 ? failedExportProject ?? project : project
        let frames: [FilmFrame?] = scope == 4 ? failedExports : scope == 3 ? [nil] : scope == 2 ? project.frames.map(Optional.some) : scope == 1 ? project.frames.filter { targets.contains($0.id) }.map(Optional.some) : [frame].compactMap { $0 }.map(Optional.some)
        guard !frames.isEmpty else { return }
        exporting = true
        failedExports = []; failedExportProject = snapshot
        exportTask = Task {
            let access = directory.startAccessingSecurityScopedResource()
            defer { if access { directory.stopAccessingSecurityScopedResource() }; exporting = false }
            var failures: [String] = [], completed = 0
            for (index, frame) in frames.enumerated() {
                if Task.isCancelled { break }
                progress = "\(index + 1) / \(frames.count)"
                let number = frame.flatMap { target in snapshot.frames.firstIndex { $0.id == target.id } }.map { String(format: "%02d", $0 + 1) } ?? "strip"
                let stem = URL(fileURLWithPath: snapshot.sourcePath).deletingPathExtension().lastPathComponent + "_" + number
                let ext = snapshot.exportJPEG ? "jpg" : "tiff"
                var url = directory.appendingPathComponent(stem).appendingPathExtension(ext), suffix = 2
                while FileManager.default.fileExists(atPath: url.path) { url = directory.appendingPathComponent("\(stem)_\(suffix)").appendingPathExtension(ext); suffix += 1 }
                // Write to a disposable temporary file, then publish only complete images.
                let temporary = directory.appendingPathComponent(".\(UUID().uuidString).\(ext)")
                do {
                    try await renderer.export(project: snapshot, frame: frame, to: temporary)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: url); completed += 1
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    if !(error is CancellationError) { failures.append("\(number): \(error.localizedDescription)"); failedExports.append(frame) }
                }
            }
            progress = ""
            notice = filmText("已导出 \(completed) 张", "Exported \(completed) images") + (Task.isCancelled ? filmText("（已取消）", " (cancelled)") : "")
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
}
#endif

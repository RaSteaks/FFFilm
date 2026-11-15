#if os(macOS)
import AppKit
import Observation
import UniformTypeIdentifiers

nonisolated enum FilmBatchScope: String, CaseIterable, Sendable { case current, checked, all }
nonisolated enum FilmFileOrganization: String, CaseIterable, Codable, Sendable { case folders, flat }

/// Versioned separately from the existing single-scan .fffilm format.
nonisolated struct FilmBatchDocument: Codable, Equatable {
    var version = 1
    var entries: [Entry]
    var activeID: UUID?
    var organization: FilmFileOrganization?
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        var project: FilmProject
        var checked: Bool
        var reviewed: Bool
        var profileAssigned: Bool
        var selected: UUID?
        var selection: Set<UUID>
    }
    var valid: Bool {
        version == 1 && Set(entries.map(\.id)).count == entries.count && entries.allSatisfy { $0.project.valid }
    }
}

@MainActor @Observable
final class FilmBatchItem: Identifiable {
    let id: UUID
    let store: FilmStore
    var checked = true
    var profileAssigned = false
    var needsProfile = false
    var initialized = false
    var queued = false
    // Retain the original grant for the session, even on volumes without bookmarks.
    @ObservationIgnored private var accessURL: URL?
    @ObservationIgnored private var hasAccess = false
    var name: String { store.sourceFileName }
    var status: String {
        if store.busy { return store.detecting ? filmText("正在识别", "Detecting") : filmText("正在加载", "Loading") }
        if needsProfile { return filmText("需指定输入配置", "Input profile required") }
        if store.error != nil { return filmText("处理失败", "Failed") }
        if queued { return filmText("等待处理", "Queued") }
        if !initialized { return filmText("等待加载", "Waiting to load") }
        if let controller = store.workspace?.exportController, let job = controller.job, job.sources[id] != nil {
            let results = job.results.filter { $0.item.sourceID == id }
            if controller.isRunning {
                return job.activeSourceID == id ? filmText("正在导出", "Exporting") : filmText("批次导出中", "Batch export running")
            }
            if results.contains(where: { if case .failed = $0.status { true } else { false } }) {
                return filmText("有导出失败项", "Export failures")
            }
            if results.contains(where: { $0.status == .pending }) { return filmText("导出未完成", "Export incomplete") }
            if results.contains(where: { $0.status == .succeeded }) {
                if let source = job.sources[id], source.project.frames != store.project.frames
                    || source.project.sourcePath != store.project.sourcePath || source.project.inputSpace != store.project.inputSpace
                    || source.project.inputProfile != store.project.inputProfile {
                    return filmText("已修改 · 需重新导出", "Modified · export again")
                }
                return store.reviewed ? filmText("已检查 · 已导出", "Reviewed · exported") : filmText("待检查 · 已导出", "Needs review · exported")
            }
        }
        return store.reviewed ? filmText("已检查", "Reviewed") : filmText("待检查", "Needs review")
    }
    init(id: UUID = UUID()) { self.id = id; self.store = FilmStore() }
    func retainAccess(_ url: URL) {
        if hasAccess { accessURL?.stopAccessingSecurityScopedResource() }
        accessURL = url; hasAccess = url.startAccessingSecurityScopedResource()
    }
    func releaseAccess() {
        if hasAccess { accessURL?.stopAccessingSecurityScopedResource() }
        hasAccess = false; accessURL = nil
    }
    var entry: FilmBatchDocument.Entry {
        .init(id: id, project: store.project, checked: checked, reviewed: store.reviewed,
              profileAssigned: profileAssigned, selected: store.selected, selection: store.selection)
    }
}

/// A window owns one batch. Editors retain their own history; only the active editor
/// and the sequential queue worker retain decoded sources. Export has its own renderer.
@MainActor @Observable
final class FilmBatchStore {
    static let workspaces = NSHashTable<FilmBatchStore>.weakObjects()
    var items: [FilmBatchItem] = []
    var activeID: UUID?
    let emptyStore = FilmStore()
    let exportController = FilmExportController(renderer: FilmRenderer())
    var autoDetect = true
    var onlyNeedsAttention = false
    var organization: FilmFileOrganization?
    var error: String?
    var notice = ""
    var presentingPanel = false
    var switching = false
    private(set) var queueRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var cancellationRequested = false
    var projectURL: URL?
    @ObservationIgnored weak var window: NSWindow? {
        didSet { emptyStore.window = window; items.forEach { $0.store.window = window } }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activationTask: Task<Void, Never>?
    private var savedEntries: [FilmBatchDocument.Entry] = []
    private var savedOrganization: FilmFileOrganization?
    private var queue: [(id: UUID, detect: Bool)] = []
    private var removed: (item: FilmBatchItem, index: Int)?
    var canUndoRemoval: Bool { removed != nil }
    var activeItem: FilmBatchItem? { items.first { $0.id == activeID } }
    var activeStore: FilmStore { activeItem?.store ?? emptyStore }
    var blocksDocuments: Bool { presentingPanel || exportController.blocksDocument }
    var canAdd: Bool { !blocksDocuments && !switching && !exportController.isRunning && !cancellationRequested }
    var canSave: Bool { !blocksDocuments && !queueRunning && !switching && !items.contains { $0.store.busy } }
    var busy: Bool { queueRunning || switching || exportController.isRunning || items.contains { $0.store.busy } }
    var dirty: Bool {
        // Navigation and frame checks are saved, but do not themselves create unsaved edits.
        let current = items.map(\.entry)
        return current.count != savedEntries.count || organization != savedOrganization || zip(current, savedEntries).contains {
            $0.id != $1.id || $0.project != $1.project || $0.reviewed != $1.reviewed || $0.profileAssigned != $1.profileAssigned
        }
    }
    var checkedItems: [FilmBatchItem] { items.filter(\.checked) }
    var visibleItems: [FilmBatchItem] {
        onlyNeedsAttention ? items.filter { !$0.store.reviewed || $0.store.error != nil || $0.needsProfile } : items
    }
    init() {
        emptyStore.workspace = self
        exportController.workspace = self
        Self.workspaces.add(self)
    }
    func isExporting(_ store: FilmStore) -> Bool {
        guard exportController.isRunning, let item = items.first(where: { $0.store === store }) else { return false }
        return exportController.job?.sources[item.id] != nil
    }
    func candidates(_ scope: FilmBatchScope) -> [FilmBatchItem] {
        switch scope {
        case .current: activeItem.map { [$0] } ?? []
        case .checked: checkedItems
        case .all: items
        }
    }

    func openScans() {
        guard canAdd else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tiff, UTType(filenameExtension: "fff") ?? .data]
        panel.allowsMultipleSelection = true
        present(panel) { response in
            if response == .OK { self.appendScans(panel.urls) }
        }
    }

    @discardableResult func appendScans(_ urls: [URL]) -> Bool {
        guard canAdd, !urls.isEmpty else { return false }
        var added: [FilmBatchItem] = []
        var rejected: [String] = []
        var duplicates = 0
        for url in urls {
            guard url.isFileURL, ["tif", "tiff", "fff"].contains(url.pathExtension.lowercased()) else {
                rejected.append(url.lastPathComponent); continue
            }
            if items.contains(where: { $0.store.project.resolvedSourceURL.standardizedFileURL == url.standardizedFileURL }) { duplicates += 1; continue }
            let item = FilmBatchItem()
            item.retainAccess(url)
            item.store.workspace = self; item.store.window = window
            item.store.project.sourcePath = url.path
            item.store.project.frames = [FilmFrame(name: "01")]
            do {
                item.store.project.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                notice = filmText("部分文件无法保存访问权限，重开批次时可能需要重新定位。", "Some files may need locating again when reopening this batch.")
            }
            items.append(item); added.append(item)
        }
        if duplicates > 0 { notice = String(format: filmText("已跳过 %d 个已在批次中的扫描。", "Skipped %d scans already in this batch."), duplicates) }
        if activeID == nil { activeID = added.first?.id }
        if !rejected.isEmpty { error = filmText("不支持这些文件：", "Unsupported files: ") + rejected.joined(separator: ", ") }
        enqueue(added, detect: autoDetect)
        return !added.isEmpty
    }

    func select(_ item: FilmBatchItem) {
        guard !blocksDocuments, !switching, activeID != item.id else { return }
        let previous = activeItem
        activeID = item.id
        switching = true
        activationTask = Task {
            if let previous, !previous.store.busy { await previous.store.suspendSource() }
            if item.initialized, !item.store.busy, !item.queued { await item.store.resumeSource() }
            switching = false; activationTask = nil
        }
    }

    func applyFormat(_ format: FilmFormat?) {
        guard !blocksDocuments else { return }
        for item in checkedItems where !item.queued && !item.store.busy && !isExporting(item.store) {
            item.store.change { $0.filmFormat = format }
        }
    }
    func detectChecked() { enqueue(checkedItems, detect: true) }
    func retry(_ item: FilmBatchItem) { enqueue([item], detect: autoDetect) }
    private func enqueue(_ entries: [FilmBatchItem], detect: Bool) {
        guard !blocksDocuments, !exportController.isRunning else { return }
        for item in entries where !item.queued && !item.store.busy && !isExporting(item.store) {
            item.queued = true; item.store.batchQueued = true
            queue.append((item.id, detect))
        }
        guard !queue.isEmpty else { return }
        if queueRunning { total = completed + queue.count + 1; return }
        completed = 0; total = queue.count; cancellationRequested = false; queueRunning = true
        task = Task {
            while !queue.isEmpty && !Task.isCancelled {
                let next = queue.removeFirst()
                guard let item = items.first(where: { $0.id == next.id }) else { continue }
                await activationTask?.value
                item.store.error = nil
                do {
                    if !item.initialized {
                        let url = item.store.project.resolvedSourceURL
                        let probe = try await item.store.renderer.probe(url)
                        if !probe.hasProfile && !item.profileAssigned {
                            item.needsProfile = true
                        } else {
                            item.needsProfile = false
                            let entry = item.entry
                            item.store.loadSource(url, restoring: item.store.project, batchImport: true)
                            await item.store.importTask?.value
                            item.initialized = item.store.info != nil
                            if item.initialized {
                                item.store.selected = item.store.project.frames.first(where: { $0.id == entry.selected })?.id ?? item.store.project.frames.first?.id
                                item.store.selection = entry.selection.intersection(Set(item.store.project.frames.map(\.id)))
                                item.store.reviewed = entry.reviewed
                                item.profileAssigned = true
                                // Loading may refresh a bookmark or resolve a moved source.
                                // Do not turn an otherwise untouched saved entry into an edit.
                                if let index = savedEntries.firstIndex(where: { $0.id == item.id }),
                                   savedEntries[index].project == entry.project {
                                    savedEntries[index].project = item.store.project
                                    savedEntries[index].profileAssigned = item.profileAssigned
                                }
                            }
                        }
                    } else { await item.store.resumeSource() }
                    item.store.batchQueued = false
                    if next.detect, item.initialized, item.store.error == nil, !Task.isCancelled {
                        await item.store.detectAndWait()
                    }
                } catch { item.store.error = error.localizedDescription }
                item.queued = false; item.store.batchQueued = false
                if activeID != item.id { await item.store.suspendSource() }
                completed += 1
            }
            for pending in queue {
                if let item = items.first(where: { $0.id == pending.id }) { item.queued = false; item.store.batchQueued = false }
            }
            queue.removeAll(); queueRunning = false; cancellationRequested = false; task = nil
            // A selected, previously loaded scan may have been waiting in the cancelled
            // queue. Restore its editor in a fresh task, outside the cancelled task context.
            if let item = activeItem, item.initialized, item.store.sourceSuspended, !switching, !item.store.busy {
                switching = true
                activationTask = Task {
                    await item.store.resumeSource()
                    switching = false; activationTask = nil
                }
            }
        }
    }
    func cancelQueue() {
        cancellationRequested = true; task?.cancel()
        items.filter { $0.store.detecting }.forEach { $0.store.cancelDetection() }
    }
    func applyProfile(_ name: String, data: Data? = nil) {
        guard !blocksDocuments else { return }
        let targets = checkedItems.filter { $0.needsProfile && !$0.queued }
        for item in targets {
            item.store.project.inputSpace = name; item.store.project.inputProfile = data
            item.profileAssigned = true; item.needsProfile = false
        }
        enqueue(targets, detect: autoDetect)
    }
    func chooseProfile() {
        guard !blocksDocuments else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let profile = CGColorSpace(iccData: data as CFData), profile.model == .rgb else {
                    throw FilmFailure(message: filmText("请选择有效的 RGB ICC 配置。", "Choose a valid RGB ICC profile."))
                }
                self.applyProfile("Custom ICC", data: data)
            } catch { self.error = error.localizedDescription }
        }
    }
    func locate(_ item: FilmBatchItem) {
        guard canSave, !isExporting(item.store) else { return }
        let panel = NSOpenPanel()
        panel.message = filmText("重新定位原始扫描文件", "Locate the original scan file")
        panel.allowedContentTypes = [.tiff, UTType(filenameExtension: "fff") ?? .data]
        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            item.retainAccess(url)
            item.store.project.sourcePath = url.path
            item.store.project.bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            item.initialized = false
            self.enqueue([item], detect: false)
        }
    }
    func reviewAndNext() {
        guard let item = activeItem, item.initialized, item.store.canImportScan, item.store.error == nil else { return }
        item.store.reviewed = true
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        let ordered = Array(items.dropFirst(index + 1)) + Array(items.prefix(index))
        if let next = ordered.first(where: { !$0.store.reviewed }) { select(next) }
    }
    func removeActive() {
        guard canSave, !exportController.isRunning, let item = activeItem,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        removed?.item.releaseAccess()
        removed = (item, index)
        items.remove(at: index); activeID = nil
        Task { await item.store.suspendSource() }
        if let next = items.first { select(next) }
    }
    func undoRemoval() {
        guard canSave, let removed else { return }
        items.insert(removed.item, at: min(removed.index, items.count)); self.removed = nil
        select(removed.item)
    }

    func openExport(scope: FilmBatchScope = .checked) {
        guard !blocksDocuments, !exportController.isRunning, !queueRunning, !switching, !items.contains(where: { $0.store.busy }) else { return }
        exportController.openBatch(scope: scope)
    }
    func exportSources(scope: FilmBatchScope) throws -> [FilmExportSource] {
        let chosen = candidates(scope)
        guard !chosen.isEmpty else { throw FilmFailure(message: filmText("请选择胶片。", "Select scans.")) }
        return try chosen.map { item in
            guard item.initialized, let info = item.store.info, !item.queued, !item.store.busy,
                  !item.needsProfile, item.store.error == nil else {
                throw FilmFailure(message: item.name + ": " + filmText("请先完成加载并处理错误。", "Finish loading and resolve errors first."))
            }
            return FilmExportSource(id: item.id, project: item.store.project, selected: item.store.selected,
                                    checked: item.store.selection, size: CGSize(width: info.width, height: info.height),
                                    reviewed: item.store.reviewed)
        }
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !blocksDocuments else { return }
        presentingPanel = true
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            panel.orderOut(nil); self.presentingPanel = false; completion(response)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finished) }
        else { panel.begin(completionHandler: finished) }
    }
    func save(asNew: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) {
        guard canSave else { completion(false); return }
        if let projectURL, !asNew { completion(write(to: projectURL)); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.rasteaks.fffilm-batch", conformingTo: .json)]
        panel.nameFieldStringValue = "Scans.ffbatch"
        present(panel) { response in
            guard response == .OK, let url = panel.url else { completion(false); return }
            completion(self.write(to: url))
        }
    }
    private func write(to url: URL) -> Bool {
        do {
            let entries = items.map(\.entry)
            let document = FilmBatchDocument(entries: entries, activeID: activeID, organization: organization)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
            savedEntries = entries; savedOrganization = organization; projectURL = url
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func requestDiscard(_ completion: @escaping (Bool) -> Void) {
        guard !blocksDocuments, !busy else { completion(false); return }
        guard dirty else { completion(true); return }
        guard let window else { completion(false); return }
        presentingPanel = true
        let alert = NSAlert()
        alert.messageText = filmText("保存胶片批次？", "Save film batch?")
        alert.informativeText = filmText("此批次中的胶片调整尚未保存。", "This batch contains unsaved scan adjustments.")
        alert.addButton(withTitle: filmText("保存", "Save")); alert.addButton(withTitle: filmText("取消", "Cancel"))
        alert.addButton(withTitle: filmText("不保存", "Don't Save"))
        alert.beginSheetModal(for: window) { response in
            alert.window.orderOut(nil); self.presentingPanel = false
            switch response {
            case .alertFirstButtonReturn: self.save(completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }
    func openProject() {
        guard canSave, !exportController.isRunning else { return }
        requestDiscard { accepted in
            guard accepted else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(exportedAs: "com.rasteaks.fffilm-batch", conformingTo: .json),
                                         UTType(exportedAs: "com.rasteaks.fffilm-project", conformingTo: .json)]
            self.present(panel) { response in
                guard response == .OK, let url = panel.url else { return }
                self.read(url)
            }
        }
    }
    private func read(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let document: FilmBatchDocument
            if url.pathExtension.lowercased() == "fffilm" {
                let project = try decoder.decode(FilmProject.self, from: data)
                document = FilmBatchDocument(entries: [.init(id: UUID(), project: project, checked: true, reviewed: false,
                                                             profileAssigned: true, selected: nil, selection: [])])
            } else { document = try decoder.decode(FilmBatchDocument.self, from: data) }
            guard document.valid else { throw FilmFailure(message: filmText("批次版本或项目参数无效。", "Invalid batch version or project parameters.")) }
            closeSources()
            items = document.entries.map { entry in
                let item = FilmBatchItem(id: entry.id)
                item.store.workspace = self; item.store.window = window; item.store.project = entry.project
                item.store.selected = entry.selected; item.store.selection = entry.selection; item.store.reviewed = entry.reviewed
                item.checked = entry.checked; item.profileAssigned = entry.profileAssigned
                item.retainAccess(entry.project.resolvedSourceURL)
                return item
            }
            activeID = items.first(where: { $0.id == document.activeID })?.id ?? items.first?.id
            organization = document.organization
            savedEntries = document.entries; savedOrganization = organization
            projectURL = url.pathExtension.lowercased() == "ffbatch" ? url : nil
            exportController.clearJob()
            enqueue(items, detect: false)
        } catch { self.error = error.localizedDescription }
    }
    func closeSources() {
        activationTask?.cancel(); task?.cancel()
        for item in items {
            item.store.renderTask?.cancel(); item.releaseAccess(); item.store.window = nil
            Task { await item.store.renderer.close() }
        }
        removed?.item.releaseAccess(); removed = nil
    }
}
#endif

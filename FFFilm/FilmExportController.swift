#if os(macOS)
import AppKit
import Observation

/// UI-facing export contract. Views own layout only; this controller owns the
/// draft, validation, destination access, immutable job and recovery actions.
@MainActor @Observable
final class FilmExportController {
    @ObservationIgnored weak var workspace: FilmBatchStore?
    var batchScope = FilmBatchScope.checked {
        didSet {
            if batchScope != .current && settings.scope == .current { settings.scope = .all }
            if isPresented { refreshPreview() }
        }
    }
    var organization = FilmFileOrganization.flat {
        didSet { if isPresented { workspace?.organization = organization; refreshPreview() } }
    }
    var includesReadyOnly = false { didSet { if isPresented { refreshPreview() } } }
    var deferredNames: [String] {
        workspace?.candidates(batchScope).filter { !$0.ready }.map { $0.name + " · " + $0.status } ?? []
    }
    private(set) var remainingSeconds: Double?
    private(set) var freeBytes: Int64?
    var useSourceNames = true { didSet { if isPresented { refreshPreview() } } }
    var isBatch: Bool { workspace != nil }
    private var canRun: Bool { workspace.map { !$0.blocksDocuments && !$0.queueRunning && !$0.switching && !$0.items.contains { $0.store.busy } } ?? (document?.canImportScan == true) }
    var settings = FilmExportSettings() {
        didSet { if isPresented && settings != oldValue { schedulePreview() } }
    }
    private(set) var isPresented = false
    private(set) var isDismissing = false
    private(set) var isChoosingDirectory = false
    private(set) var isRunning = false
    private(set) var cancellationRequested = false
    private(set) var directory: URL?
    private(set) var preview: FilmExportPlan?
    private(set) var validationMessage: String?
    private(set) var revision = 0
    private(set) var job: FilmExportJob?
    private var needsDestination = false
    private(set) var isVerifying = false
    @ObservationIgnored private(set) var verificationTask: Task<Void, Never>?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private let renderer: FilmRenderer
    // Read the owner's live gate so recovery actions obey detection and file-panel
    // locks too. A weak reference avoids retaining the document through its controller.
    @ObservationIgnored weak var document: FilmStore?
    private var context = FilmProject()
    private var selected: UUID?
    private var checked: Set<UUID> = []
    private var sourceSize = CGSize.zero
    private var sourceIdentifier = UUID()
    private var pendingPlan: FilmExportPlan?

    var blocksDocument: Bool { isPresented || isDismissing || isChoosingDirectory }
    var canStart: Bool {
        !isRunning && !isChoosingDirectory && directory != nil && (preview?.outputCount ?? 0) > 0
    }
    var canResume: Bool { !isRunning && !isVerifying && !needsDestination && canRun && (job?.pendingCount ?? 0) > 0 }
    var canRetry: Bool { !isRunning && !isVerifying && !needsDestination && canRun && (job?.failedCount ?? 0) > 0 }
    var checkedCount: Int {
        if let workspace { return workspace.candidates(batchScope).reduce(0) { $0 + $1.store.selection.count } }
        return context.frames.filter { checked.contains($0.id) }.count
    }
    var currentName: String? { workspace?.activeStore.frame?.name ?? context.frames.first { $0.id == selected }?.name }
    var sourceName: String {
        if let workspace { return String(format: filmText("%d 条胶片", "%d scans"), workspace.candidates(batchScope).count) }
        return URL(fileURLWithPath: context.sourcePath).lastPathComponent
    }

    func openBatch(scope: FilmBatchScope) {
        guard let workspace, !isRunning, !blocksDocument else { return }
        includesReadyOnly = false
        batchScope = scope
        organization = workspace.organization ?? (workspace.candidates(scope).count > 1 ? .folders : .flat)
        if settings.scope == nil {
            settings.scope = scope == .current ? (workspace.activeStore.selection.isEmpty ? .current : .checked) : .all
        }
        isPresented = true
        refreshPreview()
    }

    init(renderer: FilmRenderer) { self.renderer = renderer }

    func resetSource(project: FilmProject, size: CGSize, identifier: UUID) {
        guard !isRunning else { return }
        clearJob()
        context = project; sourceSize = size; sourceIdentifier = identifier
        settings = FilmExportSettings(format: project.exportJPEG ? .jpeg : .tiff,
                                      qualityPercent: Int((project.jpegQuality * 100).rounded()),
                                      prefix: URL(fileURLWithPath: project.sourcePath).deletingPathExtension().lastPathComponent)
        preview = nil; validationMessage = nil
    }

    func open(project: FilmProject, selected: UUID?, checked: Set<UUID>) {
        guard !isRunning, !blocksDocument else { return }
        context = project; self.selected = selected; self.checked = checked
        if settings.scope == nil || settings.scope == .checked && checkedCount == 0 {
            settings.scope = checkedCount == 0 ? .current : .checked
        }
        isPresented = true
        refreshPreview()
    }

    func dismiss() {
        guard !isChoosingDirectory, isPresented else { return }
        isDismissing = true
        isPresented = false
    }

    /// Called by the sheet's onDismiss. Keep the document gate closed until AppKit
    /// has removed the sheet, and only then start the already-confirmed job.
    func didDismiss() {
        isPresented = false; isDismissing = false
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        start(plan)
    }

    func setDirectory(_ url: URL) {
        guard !isRunning else { return }
        directory = url
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        freeBytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        refreshPreview()
    }

    func chooseDirectory(parent: NSWindow?) {
        guard isPresented, !isChoosingDirectory else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = directory
        isChoosingDirectory = true
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            panel.orderOut(nil)
            self.isChoosingDirectory = false
            if response == .OK, let url = panel.url { self.setDirectory(url) }
        }
        // The folder picker belongs to the export sheet, not to the blocked
        // document window. Ordinary import/save panels still use FilmStore's gate.
        if let parent = parent?.attachedSheet ?? parent {
            panel.beginSheetModal(for: parent, completionHandler: finished)
        } else { panel.begin(completionHandler: finished) }
    }

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    private func schedulePreview() {
        previewTask?.cancel()
        preview = nil
        previewTask = Task {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard isPresented else { return }
            refreshPreview()
        }
    }

    func refreshPreview() {
        previewTask?.cancel(); previewTask = nil
        do {
            if let workspace {
                preview = try FilmExportPlan.makeBatch(sources: workspace.exportSources(scope: batchScope, readyOnly: includesReadyOnly), settings: settings,
                                                       organization: organization, useSourceNames: useSourceNames, directory: directory)
            } else {
                preview = try FilmExportPlan.make(project: context, selected: selected, checked: checked,
                                                  sourceSize: sourceSize, settings: settings, directory: directory)
            }
            validationMessage = nil
        } catch {
            preview = nil
            validationMessage = error.localizedDescription
        }
    }

    func confirm() {
        guard isPresented, !isChoosingDirectory else { return }
        // Recheck destination collisions at the commit boundary; the exact plan
        // captured here is retained for cancellation/resume and failed retries.
        refreshPreview()
        guard canStart, let preview else { return }
        pendingPlan = preview
        if let workspace { workspace.organization = organization }
        dismiss()
    }

    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        task?.cancel()
    }

    func resume() {
        guard canResume else { return }
        run()
    }

    func retryFailed() {
        guard canRetry, var job else { return }
        let indexes = job.results.indices.filter { if case .failed = job.results[$0].status { true } else { false } }
        for index in indexes { job.results[index].status = .pending }
        self.job = job
        run(indexes: indexes)
    }

    var needsRecoveryDirectory: Bool { needsDestination && job != nil }

    func chooseRecoveryDirectory() {
        guard needsRecoveryDirectory, !isChoosingDirectory else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = job?.directory
        isChoosingDirectory = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            panel.orderOut(nil); self.isChoosingDirectory = false
            guard response == .OK, let url = panel.url, var saved = self.job else { return }
            saved.directory = url
            saved.directoryBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            self.restore(saved, authorizedDirectory: url)
        }
        if let window = workspace?.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    /// Restored manifests are user-opened documents. Validate names, snapshots and prior outputs
    /// before a resume can read a scan or publish a file in the selected destination.
    func restore(_ savedJob: FilmExportJob?, authorizedDirectory: URL? = nil) {
        clearJob()
        guard var saved = savedJob, let workspace else { return }
        let sourceIDs = Set(workspace.items.map(\.id))
        let valid = saved.sources.allSatisfy { key, source in
            key == source.id && sourceIDs.contains(key) && source.project.valid
        } && saved.results.allSatisfy { result in
            let parts = result.item.fileName.components(separatedBy: "/")
            guard (1...2).contains(parts.count), parts.allSatisfy({ (try? FilmExportPlan.validateComponent($0)) != nil }),
                  let id = result.item.sourceID, let source = saved.sources[id] else { return false }
            return result.item.frame.map { source.project.frames.contains($0) } ?? true
        }
        guard valid else {
            workspace.notice = filmText("导出记录无效，请重新配置。", "Invalid export record. Configure a new export.")
            return
        }
        var stale = false
        let resolved = authorizedDirectory ?? saved.directoryBookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: .withSecurityScope,
                                            relativeTo: nil, bookmarkDataIsStale: &stale) }
        saved.phase = .cancelled; saved.activeSourceID = nil; saved.activeFileName = nil
        job = saved
        guard let resolved else { needsDestination = true; return }
        saved.directory = resolved
        if stale { saved.directoryBookmark = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        directory = resolved; needsDestination = false; isVerifying = true
        let snapshot = saved
        verificationTask = Task {
            let changes = await Task.detached(priority: .utility) {
                snapshot.checkPublishedFiles(at: resolved)
            }.value
            guard !Task.isCancelled, self.job?.id == snapshot.id else { return }
            defer { isVerifying = false; verificationTask = nil }
            guard let changes else { needsDestination = true; return }
            var verified = snapshot
            for (index, present) in changes {
                verified.results[index].status = present
                    ? .failed(filmText("目标文件已改变，请核对目标。", "Destination file changed. Check the existing file."))
                    : .pending
                if let source = verified.results[index].item.sourceID, let frame = verified.results[index].item.frame {
                    workspace.items.first(where: { $0.id == source })?.delivery?.frames.removeValue(forKey: frame.id)
                }
            }
            verified.phase = verified.pendingCount == 0 ? .finished : .cancelled
            job = verified
            if !changes.isEmpty || stale || authorizedDirectory != nil { revision += 1 }
        }
    }

    func clearJob() {
        guard !isRunning else { return }
        if job != nil { revision += 1 }
        verificationTask?.cancel(); verificationTask = nil; isVerifying = false
        job = nil; needsDestination = false
    }

    func revealFiles() {
        guard let job, !job.completedURLs.isEmpty else { return }
        let access = job.directory.startAccessingSecurityScopedResource()
        defer { if access { job.directory.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting(job.completedURLs)
    }

    private func start(_ plan: FilmExportPlan) {
        guard !isRunning, let directory = plan.directory else { return }
        job = FilmExportJob(project: plan.project, sourceIdentifier: sourceIdentifier, directory: directory,
                            results: plan.items.map { FilmExportResult(item: $0, status: $0.skipped ? .skipped : .pending) }, sources: plan.sources)
        job?.directoryBookmark = try? directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        job?.deferredSources = includesReadyOnly ? deferredNames : []
        revision += 1
        run()
    }

    private func run(indexes requestedIndexes: [Int]? = nil) {
        guard canRun, let snapshot = job else { return }
        let indexes = requestedIndexes ?? snapshot.results.indices.filter { snapshot.results[$0].status == .pending }
        guard !indexes.isEmpty else { return }
        isRunning = true; cancellationRequested = false; job?.phase = .running
        task = Task {
            let access = snapshot.directory.startAccessingSecurityScopedResource()
            defer {
                if access { snapshot.directory.stopAccessingSecurityScopedResource() }
                job?.activeFileName = nil; job?.activeSourceID = nil
                isRunning = false; cancellationRequested = false; task = nil
            }
            var loadedSource: UUID?
            var sourceFailure: String?
            let began = ProcessInfo.processInfo.systemUptime
            remainingSeconds = nil
            for (position, index) in indexes.enumerated() {
                if Task.isCancelled { break }
                let item = snapshot.results[index].item
                job?.activeFileName = item.fileName; job?.activeSourceID = item.sourceID
                let url = snapshot.directory.appendingPathComponent(item.fileName)
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
                do {
                    let project: FilmProject
                    let identifier: UUID
                    if let sourceID = item.sourceID, let source = snapshot.sources[sourceID] {
                        if loadedSource != sourceID {
                            await renderer.close()
                            loadedSource = sourceID; sourceFailure = nil
                            do {
                                let decoded = try await renderer.load(source.project.resolvedSourceURL, inputSpace: source.project.inputSpace,
                                                            inputProfile: source.project.inputProfile)
                                if let expected = source.project.sourceIdentity,
                                   try await renderer.identity(source.project.resolvedSourceURL, width: decoded.width, height: decoded.height) != expected {
                                    throw FilmFailure(message: filmText("原扫描已改变。", "Original scan changed."))
                                }
                            } catch { sourceFailure = error.localizedDescription }
                        }
                        if let sourceFailure { throw FilmFailure(message: sourceFailure) }
                        project = source.project; identifier = await renderer.sourceIdentifier
                        // Create only folders with actual pending output, never during preview.
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    } else { project = snapshot.project; identifier = snapshot.sourceIdentifier }
                    try Task.checkCancellation()
                    try await renderer.export(project: project, frame: item.frame, to: temporary,
                                              sourceIdentifier: identifier)
                    try Task.checkCancellation()
                    // Publishing never overwrites a destination that appeared after
                    // planning. Report the conflict and keep its original planned name.
                    let written = try await Task.detached { try FilmSourceIdentity.read(temporary, width: 0, height: 0) }.value
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: url)
                    job?.results[index].writtenFile = written
                    if let id = item.sourceID, let frame = item.frame {
                        workspace?.items.first(where: { $0.id == id })?.recordDelivery(frame, project: project)
                    }
                    job?.results[index].status = .succeeded
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    if Task.isCancelled || error is CancellationError { break }
                    job?.results[index].status = .failed(error.localizedDescription)
                }
                remainingSeconds = (ProcessInfo.processInfo.systemUptime - began) / Double(position + 1) * Double(indexes.count - position - 1)
            }
            remainingSeconds = nil
            if !snapshot.sources.isEmpty { await renderer.close() }
            revision += 1
            job?.phase = Task.isCancelled ? .cancelled : .finished
        }
    }
}
#endif

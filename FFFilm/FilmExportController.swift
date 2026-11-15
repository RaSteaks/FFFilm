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
    var useSourceNames = true { didSet { if isPresented { refreshPreview() } } }
    var isBatch: Bool { workspace != nil }
    private var canRun: Bool { workspace.map { !$0.blocksDocuments && !$0.queueRunning && !$0.switching && !$0.items.contains { $0.store.busy } } ?? (document?.canImportScan == true) }
    var settings = FilmExportSettings() {
        didSet { if isPresented { refreshPreview() } }
    }
    private(set) var isPresented = false
    private(set) var isDismissing = false
    private(set) var isChoosingDirectory = false
    private(set) var isRunning = false
    private(set) var cancellationRequested = false
    private(set) var directory: URL?
    private(set) var preview: FilmExportPlan?
    private(set) var validationMessage: String?
    private(set) var job: FilmExportJob?
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
    var canResume: Bool { !isRunning && canRun && (job?.pendingCount ?? 0) > 0 }
    var canRetry: Bool { !isRunning && canRun && (job?.failedCount ?? 0) > 0 }
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

    func refreshPreview() {
        do {
            if let workspace {
                preview = try FilmExportPlan.makeBatch(sources: workspace.exportSources(scope: batchScope), settings: settings,
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

    func clearJob() {
        guard !isRunning else { return }
        job = nil
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
            for index in indexes {
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
                                _ = try await renderer.load(source.project.resolvedSourceURL, inputSpace: source.project.inputSpace,
                                                            inputProfile: source.project.inputProfile)
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
                    try FileManager.default.moveItem(at: temporary, to: url)
                    job?.results[index].status = .succeeded
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    if Task.isCancelled || error is CancellationError { break }
                    job?.results[index].status = .failed(error.localizedDescription)
                }
            }
            if !snapshot.sources.isEmpty { await renderer.close() }
            job?.phase = Task.isCancelled ? .cancelled : .finished
        }
    }
}
#endif

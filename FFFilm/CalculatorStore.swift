import Foundation
import Observation

private enum ResetUndoSnapshot {
    // Each reset owns only the state it changes, including the persisted value it replaces.
    case rate(settings: CaptureSettings, defaultCameraMemory: CameraSettingsMemory?)
    case shutter(settings: ShutterSettings, rememberedSettings: ShutterSettings)
}

@Observable
final class CalculatorStore {
    @ObservationIgnored private let engine: CalculatorEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var cameraMemories: [String: CameraSettingsMemory]
    private var resetUndoSnapshot: ResetUndoSnapshot?
    // One window-local entry bounds memory and avoids repeating the multi-frequency search.
    @ObservationIgnored private var shutterCache: (settings: ShutterSettings, result: ShutterCalculation)?
    @ObservationIgnored private var rememberedShutterSettings: ShutterSettings
    // Invalid numeric drafts may live in a window, but never enter persisted rig snapshots.
    @ObservationIgnored private var shutterRigDrafts: [ShutterRigID: ShutterSettings] = [:]
    // Uncommitted Mac input must gate every handoff action, including toolbar shortcuts.
    var durationDraftPending = false
    var recordingRig = ""
    var backupCopies = 2
    var reservePercent = 10
    var proxyGb = 0.0
    var destinationFreeGb: Double?
    var bytesPerDestinationGb: Double { (calculation.dayTotalGb + max(proxyGb, 0)) / (1 - Double(reservePercent) / 100) }
    var addLabel: String {
        let result = calculation
        let value = recordingTask == .capacity ? DisplayFormat.plannedDuration(settings.shootHours) : result.media.label
        return "\(AppText.key("summary.add")) · \(value)"
    }
    func backupSummary(unit: StorageUnit) -> String {
        return "\(AppText.key("plan.destination")) \(DisplayFormat.compactStorage(bytesPerDestinationGb, unit: unit)) × \(backupCopies) · \(AppText.key("plan.reserve")) \(reservePercent)%"
    }
    var needsCadenceReview = false
    var validBackupPlan: Bool {
        proxyGb.isFinite && proxyGb >= 0 && (destinationFreeGb.map { $0.isFinite && $0 >= 0 } ?? true)
            && bytesPerDestinationGb.isFinite
    }
    var canShareRecording: Bool {
        summary.activeDay.archivedUnit == nil && calculation.hasEstimate && !needsCadenceReview && (recordingTask == .runtime || (!durationDraftPending && validBackupPlan))
    }
    let shutterWorkspace: ShutterWorkspace
    /// Persisted and shared by every window; each window refreshes it before changing it.
    let summary: RecordingSummary

    let catalog: CatalogData
    // Writes must pass through the workflow methods to keep normalization,
    // persistence and reset invalidation consistent with the visible inputs.
    private(set) var settings: CaptureSettings
    private(set) var shutterSettings: ShutterSettings
    private(set) var shutterInputRevision = 0
    var activeView: CalculatorView = .rate
    // Window-local task selection never changes the shared camera format or planning inputs.
    var recordingTask: RecordingTask = .capacity
    private(set) var quickStartCameraIds: [String]

    /// The banner is deliberately modelled as state instead of a transient
    /// toast so VoiceOver and keyboard users can discover important changes.
    var feedbackMessage: String?
    var resetUndoAvailable: Bool { resetUndoSnapshot != nil }
    /// Counts additions to the summary so every add control shares one confirmation.
    private(set) var summaryAdditions = 0

    private static let quickStartKey = "fffilm.quick-start-camera-ids"
    static let cameraMemoryKey = "fffilm.camera-settings-memory"
    private static let defaultQuickStarts = ["alexa35", "alexa265", "venice2", "burano"]

    init(catalog suppliedCatalog: CatalogData? = nil, defaults: UserDefaults = .standard) {
        let catalog = suppliedCatalog ?? CatalogData.bundled
        self.catalog = catalog
        self.engine = CalculatorEngine(catalog: catalog)
        self.defaults = defaults
        self.cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
        self.settings = .default
        let memory = defaults.data(forKey: ShutterSettingsMemory.key)
            .flatMap { try? JSONDecoder().decode(ShutterSettingsMemory.self, from: $0) }
        let restored = memory.flatMap { $0.isValid ? $0.settings : nil } ?? ShutterSettings.default
        let workspace = ShutterWorkspace(defaults: defaults, migrating: restored)
        self.shutterWorkspace = workspace
        self.summary = RecordingSummary(defaults: defaults, engine: CalculatorEngine(catalog: catalog))
        self.shutterSettings = workspace.active.settings
        self.rememberedShutterSettings = workspace.active.settings

        self.quickStartCameraIds = Self.favoriteCameraIDs(defaults: defaults, catalog: catalog)

        let defaultSettings = engine.normalized(.default)
        if let memory = cameraMemories[defaultSettings.cameraId] {
            self.settings = engine.normalized(memory.applying(to: defaultSettings))
        } else {
            self.settings = defaultSettings
        }
    }

    @ObservationIgnored private var calculationCache: (CaptureSettings, Calculation)?
    var calculation: Calculation {
        let inputs = settings
        if let calculationCache, calculationCache.0 == inputs { return calculationCache.1 }
        let result = engine.calculate(settings: inputs)
        calculationCache = (inputs, result)
        return result
    }
    var shutterCalculation: ShutterCalculation {
        // Read observed inputs even on cache hits, so views still update after input edits,
        // import, reset or undo. Cache writes themselves must not trigger view invalidation.
        let inputs = shutterSettings
        if let shutterCache, shutterCache.settings == inputs { return shutterCache.result }
        let result = engine.calculateShutter(settings: inputs)
        shutterCache = (inputs, result)
        return result
    }
    var currentCamera: CameraProfile { engine.camera(id: settings.cameraId) }
    var currentMode: SensorMode { engine.mode(for: settings) }
    var currentResolution: Resolution { engine.resolution(for: settings) }
    var currentCodec: CodecProfile { engine.codec(for: settings) }
    var currentMedia: MediaProfile { engine.media(id: settings.mediaId) }
    var availableMedia: [MediaProfile] { engine.availableMedia(for: currentCamera) }
    var availableCodecs: [CodecProfile] { engine.availableCodecs(for: settings) }
    var availableSensorFrameRates: [Double] { engine.availableSensorFrameRates(for: settings) }

    var catalogSelection = 0
    func camera(_ camera: CameraProfile, supportsCodecNamed query: String) -> Bool {
        guard catalog.codecs.contains(where: { $0.name.localizedStandardContains(query) }) else { return false }
        var proposed = settings
        proposed.cameraId = camera.id
        for mode in camera.modes {
            proposed.modeId = mode.id
            for resolution in mode.resolutions {
                proposed.resolutionId = resolution.id
                if engine.availableCodecs(for: proposed).contains(where: { $0.name.localizedStandardContains(query) }) { return true }
            }
        }
        return false
    }
    var sortedCameras: [CameraProfile] {
        catalog.cameras.sorted {
            ($0.manufacturer.rawValue, $0.name) < ($1.manufacturer.rawValue, $1.name)
        }
    }

    var quickStartCameras: [CameraProfile] {
        quickStartCameraIds.compactMap { id in catalog.cameras.first(where: { $0.id == id }) }
    }

    var quickStartCandidates: [CameraProfile] {
        sortedCameras.filter { !$0.isStandaloneProRes && !quickStartCameraIds.contains($0.id) }
    }

    var canAddQuickStart: Bool {
        !quickStartCandidates.isEmpty
    }

    /// The legacy configuration-link format is intentionally kept separate
    /// from the human-readable clipboard summary for compatibility.
    var configurationText: String {
        var components = URLComponents()
        components.scheme = "fffilm"
        components.host = "configuration"
        components.queryItems = [
            URLQueryItem(name: "camera", value: settings.cameraId),
            URLQueryItem(name: "mode", value: settings.modeId),
            URLQueryItem(name: "resolution", value: settings.resolutionId),
            URLQueryItem(name: "codec", value: settings.codecId),
            URLQueryItem(name: "project", value: String(settings.projectFps)),
            URLQueryItem(name: "sensor", value: String(settings.sensorFps)),
            URLQueryItem(name: "sensorOverdrive", value: String(settings.sensorOverdrive)),
            URLQueryItem(name: "media", value: settings.mediaId),
            URLQueryItem(name: "hours", value: String(settings.shootHours)),
        ]
        return components.string ?? ""
    }

    /// Links cross a process boundary. Reject duplicate/missing fields and invalid numbers before previewing.
    func configuration(from url: URL) -> CaptureSettings? {
        guard url.scheme?.lowercased() == "fffilm", url.host == "configuration",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var fields: [String: String] = [:]
        for item in items {
            guard fields[item.name] == nil, let value = item.value else { return nil }
            fields[item.name] = value
        }
        guard let camera = fields["camera"], catalog.cameras.contains(where: { $0.id == camera }),
              let mode = fields["mode"], let resolution = fields["resolution"], let codec = fields["codec"],
              let project = fields["project"].flatMap(Double.init), project.isFinite, project > 0,
              let sensor = fields["sensor"].flatMap(Double.init), sensor.isFinite, sensor > 0,
              let overdrive = fields["sensorOverdrive"].flatMap(Bool.init), let media = fields["media"],
              let hours = fields["hours"].flatMap(Double.init), CaptureSettings.shootHoursRange.contains(hours) else { return nil }
        let proposed = CaptureSettings(cameraId: camera, modeId: mode, resolutionId: resolution,
            codecId: codec, projectFps: project, sensorFps: sensor,
            sensorOverdrive: overdrive, mediaId: media, shootHours: hours)
        let result = engine.normalized(proposed)
        guard result == engine.migratingLegacyIdentifiers(proposed),
              engine.calculate(settings: result).hasEstimate else { return nil }
        return result
    }

    func applyConfiguration(_ value: CaptureSettings) {
        durationDraftPending = false; needsCadenceReview = false
        commitFormatSettings(value)
    }

    func readableRecordingSummary(storageUnit: StorageUnit) -> String {
        let result = calculation
        return AppText.recordingSummary(settings: settings, calculation: result, unit: storageUnit, task: recordingTask)
            + "\n" + result.rateBasis + (recordingTask == .capacity ? "\n" + backupSummary(unit: storageUnit) : "")
    }

    func readableShutterSummary() -> String {
        AppText.shutterRigContext(shutterWorkspace.active)
            + "\n" + AppText.shutterSummary(settings: shutterSettings, calculation: shutterCalculation)
    }

    func selectShutterRig(_ id: ShutterRigID) {
        guard id != shutterWorkspace.selectedRig else { return }
        rememberShutterResult()
        shutterRigDrafts[shutterWorkspace.selectedRig] = shutterSettings
        clearTransientState()
        shutterWorkspace.select(id)
        rememberedShutterSettings = shutterWorkspace.active.settings
        shutterSettings = shutterRigDrafts[id] ?? rememberedShutterSettings
    }

    func configureShutterRig(cameraLabel: String) {
        shutterWorkspace.update(settings: rememberedShutterSettings, cameraLabel: cameraLabel)
    }

    /// Called at semantic edit boundaries, not on every keystroke. Pending/no-result input
    /// is excluded; inactive drafts use the last valid values already retained for launch.
    func currentShutterRecord() -> ShutterRecord? {
        guard let exposure = shutterCalculation.exposure else { return nil }
        let rig = shutterWorkspace.active
        return ShutterRecord(id: UUID(), rig: rig.id,
            title: "\(DisplayFormat.shutterFrameRate(shutterSettings.sensorFps)) fps · \(DisplayFormat.shutterNumber(exposure.angle))°",
            cameraLabel: rig.cameraLabel, settings: restorableShutterSettings, date: .now)
    }

    func rememberShutterResult() {
        if let record = currentShutterRecord() { shutterWorkspace.remember(record) }
    }

    func restoreShutterRecord(_ record: ShutterRecord) {
        guard record.isValid else { return }
        rememberShutterResult()
        shutterRigDrafts[shutterWorkspace.selectedRig] = shutterSettings
        clearTransientState()
        shutterWorkspace.select(record.rig)
        shutterSettings = record.settings
        rememberedShutterSettings = record.settings
        shutterRigDrafts[record.rig] = nil
        shutterWorkspace.update(settings: record.settings, cameraLabel: record.cameraLabel)
        persistShutterSettings()
        // Explicit restoration replaces the destination editor's drafts, not other rigs' drafts.
        shutterInputRevision += 1
        shutterWorkspace.remember(record)
    }

    func summary(for record: ShutterRecord) -> String {
        AppText.shutterRigContext(ShutterRig(id: record.rig, cameraLabel: record.cameraLabel, settings: record.settings))
            + "\n" + AppText.shutterSummary(settings: record.settings, calculation: engine.calculateShutter(settings: record.settings))
            + (record.conditions.isEmpty ? "" : "\n" + record.conditions)
            + (record.fieldChecked ? "\n" + AppText.localized("shutter.library.checked") + " · " + record.date.formatted() : "")
    }

    func chooseShutterCandidate(_ candidate: ShutterCandidate) {
        // Selection is explicit and limited to the current candidate set. Matching keeps its target.
        guard shutterSettings.mode == .flicker, shutterCalculation.candidates.contains(candidate) else { return }
        updateShutterSettings(candidate.exposure.angle, at: \.preferredAngle)
        rememberShutterResult()
    }

    func setActiveView(_ view: CalculatorView) {
        guard activeView != view else { return }
        activeView = view
        clearTransientState()
    }

    func selectCamera(_ id: String) {
        // A different window may have edited this camera since this store opened.
        // Every format edit is already persisted, so switching need not save the outgoing state.
        cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
        commitFormatSettings(Self.proposedSettings(cameraID: id, base: settings, memories: cameraMemories, engine: engine))
    }

    /// The format a camera switch proposes: that camera's remembered choices, or its first mode.
    /// Siri and Shortcuts reuse it so an answer matches what the calculator would show.
    /// The result is not normalized, so callers can report adjustments made by normalization.
    static func rememberedSettings(cameraID: String, base: CaptureSettings, defaults: UserDefaults,
                                   catalog: CatalogData) -> CaptureSettings {
        proposedSettings(cameraID: cameraID, base: base,
                         memories: loadCameraMemories(defaults: defaults, catalog: catalog),
                         engine: CalculatorEngine(catalog: catalog))
    }

    private static func proposedSettings(cameraID: String, base: CaptureSettings,
                                         memories: [String: CameraSettingsMemory],
                                         engine: CalculatorEngine) -> CaptureSettings {
        let selectedCamera = engine.camera(id: cameraID)
        var next = base
        next.cameraId = selectedCamera.id
        if let memory = memories[selectedCamera.id] {
            next = memory.applying(to: next)
        } else {
            next.modeId = selectedCamera.modes[0].id
            next.resolutionId = engine.preferredResolution(camera: selectedCamera, mode: selectedCamera.modes[0]).id
        }
        return next
    }

    func selectMode(_ id: String) {
        var next = settings
        next.modeId = id
        let selectedMode = engine.mode(for: next)
        next.resolutionId = engine.preferredResolution(camera: engine.camera(id: next.cameraId), mode: selectedMode).id
        commitFormatSettings(next)
    }

    func selectResolution(_ id: String) {
        updateFormatSettings { $0.resolutionId = id }
    }

    func selectCodec(_ id: String) {
        updateFormatSettings { $0.codecId = id }
    }

    /// Dials pass `persisting: false` for each detent and call `persistFormatSettings()` when they
    /// settle, so a fling recalculates live without re-encoding camera memory at every stop.
    func selectProjectFps(_ fps: Double, persisting: Bool = true) {
        if currentCamera.isStandaloneProRes { needsCadenceReview = false }
        updateFormatSettings(persisting: persisting) { $0.projectFps = fps }
    }

    func selectSensorFps(_ fps: Double, persisting: Bool = true) {
        needsCadenceReview = false
        updateFormatSettings(persisting: persisting) { $0.sensorFps = fps }
    }

    func persistFormatSettings() {
        rememberCurrentCamera()
    }

    func selectMedia(_ id: String) {
        guard availableMedia.contains(where: { $0.id == id }) else { return }
        updateFormatSettings { $0.mediaId = id }
    }

    func setShootHours(_ hours: Double) {
        guard hours.isFinite, CaptureSettings.shootHoursRange.contains(hours) else { return }
        clearTransientState()
        settings.shootHours = hours
    }

    func setSensorOverdrive(_ enabled: Bool) {
        updateFormatSettings { $0.sensorOverdrive = enabled }
    }

    /// Shutter controls edit through the store so a new input invalidates the
    /// one-step reset undo before it could overwrite that input.
    /// Dials pass `persisting: false` for each detent and call `persistShutterChanges()` on settle.
    func updateShutterSettings<Value>(_ value: Value, at keyPath: WritableKeyPath<ShutterSettings, Value>,
                                      persisting: Bool = true) {
        clearTransientState()
        shutterSettings[keyPath: keyPath] = value
        if persisting { persistShutterSettings() }
    }

    func persistShutterChanges() {
        persistShutterSettings()
    }

    /// Save valid values independently so a pending draft cannot erase the last usable
    /// parameter, or prevent a task/direction change from being remembered on relaunch.
    private func persistShutterSettings() {
        let next = restorableShutterSettings
        guard let data = try? JSONEncoder().encode(ShutterSettingsMemory(settings: next)) else { return }
        rememberedShutterSettings = next
        defaults.set(data, forKey: ShutterSettingsMemory.key)
        shutterWorkspace.update(settings: next)
    }

    private var restorableShutterSettings: ShutterSettings {
        var next = shutterSettings
        for field in ShutterInputField.allCases where field.error(for: next[keyPath: field.keyPath]) != nil {
            next[keyPath: field.keyPath] = rememberedShutterSettings[keyPath: field.keyPath]
        }
        if next.displayRefreshMilliHz == nil { next.displayRefreshRates = rememberedShutterSettings.displayRefreshRates }
        return next
    }

    func resetActiveView() {
        #if os(macOS)
        // The film workbench owns its document lifecycle; calculator reset does not apply.
        guard activeView != .film else { return }
        #endif
        feedbackMessage = AppText.reset

        if activeView == .rate {
            durationDraftPending = false; needsCadenceReview = false
            let resetSettings = engine.normalized(.default)
            cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
            resetUndoSnapshot = .rate(settings: settings, defaultCameraMemory: cameraMemories[resetSettings.cameraId])
            settings = resetSettings
            rememberCurrentCamera()
        } else {
            resetUndoSnapshot = .shutter(settings: shutterSettings, rememberedSettings: rememberedShutterSettings)
            shutterSettings = .default
            persistShutterSettings()
            shutterInputRevision += 1
        }
    }

    func undoReset() {
        guard let snapshot = resetUndoSnapshot else { return }
        switch snapshot {
        case .shutter(let previous, let remembered):
            shutterSettings = previous
            // Undoing a reset during an invalid draft also restores its last usable launch value.
            rememberedShutterSettings = remembered
            persistShutterSettings()
        case .rate(let previous, let defaultCameraMemory):
            settings = previous
            // Undo only the default camera record reset changed; keep other
            // windows' later edits to unrelated cameras.
            cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
            let defaultCameraID = engine.normalized(.default).cameraId
            cameraMemories[defaultCameraID] = defaultCameraMemory
            persistCameraMemories()
        }
        resetUndoSnapshot = nil
        feedbackMessage = AppText.resetUndone
    }

    /// One-shot import deliberately leaves RATE, angles and lighting unchanged.
    @discardableResult
    func importShutterFrameRates(includeProject: Bool = false) -> (sensor: Double, project: Double) {
        clearTransientState()
        shutterSettings.sensorFps = ShutterFramePreset.recordingCadence(calculation.captureFps)
        if includeProject { shutterSettings.projectFps = ShutterFramePreset.recordingCadence(settings.projectFps) }
        configureShutterRig(cameraLabel: currentCamera.name)
        persistShutterSettings()
        rememberShutterResult()
        return (shutterSettings.sensorFps, shutterSettings.projectFps)
    }

    /// Identical setups are added again on purpose: two cameras with one format both record.
    /// The control's count and an accessibility announcement confirm the addition instead of
    /// a banner, which would shift the page while the operator is working near the bottom.
    func addCurrentToSummary() {
        guard canShareRecording else { return }
        summary.add(settings, card: recordingTask == .runtime, rig: recordingRig)
        summaryAdditions += 1
    }

    func removeSummaryEntry(id: UUID) {
        summary.remove(id)
    }

    func clearSummary() {
        summary.clear()
    }

    var summaryItems: [SummaryItem] { summary.items }
    var summaryTotalGb: Double { summary.totalGb }

    func readableSummary(storageUnit: StorageUnit) -> String {
        let unknown = summary.entries.filter { $0.snapshot == nil }.map { $0.settings.cameraId + " · " + AppText.key("rate.unknown") }
        return ([summary.activeDay.title, AppText.summaryText(items: summaryItems, total: summaryTotalGb, unit: summary.activeDay.archivedUnit ?? storageUnit)] + unknown).joined(separator: "\n")
    }

    func clearTransientState() {
        feedbackMessage = nil
        resetUndoSnapshot = nil
    }

    func addQuickStart(cameraID: String) {
        guard canAddQuickStart,
              !quickStartCameraIds.contains(cameraID),
              catalog.cameras.contains(where: { $0.id == cameraID && !$0.isStandaloneProRes }) else { return }
        quickStartCameraIds.append(cameraID)
        persistQuickStarts()
    }

    func removeQuickStart(cameraID: String) {
        quickStartCameraIds.removeAll { $0 == cameraID }
        persistQuickStarts()
    }

    /// Catalog and detail actions share persisted ordering; PRORES stays outside the favorites array.
    @discardableResult
    func moveQuickStart(cameraID: String, relativeTo targetID: String, after: Bool) -> Bool {
        guard cameraID != targetID,
              let source = quickStartCameraIds.firstIndex(of: cameraID),
              quickStartCameraIds.contains(targetID) else { return false }
        var reordered = quickStartCameraIds
        reordered.remove(at: source)
        guard let target = reordered.firstIndex(of: targetID) else { return false }
        reordered.insert(cameraID, at: target + (after ? 1 : 0))
        guard reordered != quickStartCameraIds else { return false }
        quickStartCameraIds = reordered
        persistQuickStarts()
        return true
    }

    func shiftQuickStart(cameraID: String, forward: Bool) {
        guard let index = quickStartCameraIds.firstIndex(of: cameraID) else { return }
        let neighbor = index + (forward ? 1 : -1)
        guard quickStartCameraIds.indices.contains(neighbor) else { return }
        moveQuickStart(cameraID: cameraID, relativeTo: quickStartCameraIds[neighbor], after: forward)
    }

    /// Native List destinations refer to the original array, before the moved rows are removed.
    func moveQuickStarts(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy(quickStartCameraIds.indices.contains),
              (0 ... quickStartCameraIds.count).contains(destination) else { return }
        let moving = offsets.map { quickStartCameraIds[$0] }
        var remaining = quickStartCameraIds.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: insertion)
        guard remaining != quickStartCameraIds else { return }
        quickStartCameraIds = remaining
        persistQuickStarts()
    }

    private func updateFormatSettings(persisting: Bool = true, _ mutation: (inout CaptureSettings) -> Void) {
        var next = settings
        mutation(&next)
        commitFormatSettings(next, persisting: persisting)
    }

    private func commitFormatSettings(_ proposed: CaptureSettings, persisting: Bool = true) {
        clearTransientState()
        let normalized = engine.normalized(proposed)
        // Standalone ProRes records at project cadence. Its mirrored sensor value is not a user input.
        let usesProjectCadence = engine.camera(id: normalized.cameraId).isStandaloneProRes
        let adjusted = adjustedParameters(from: proposed, to: normalized, usesProjectCadence: usesProjectCadence)
        if normalized.cameraId != settings.cameraId { needsCadenceReview = false }
        settings = normalized
        if persisting { rememberCurrentCamera() }
        if !adjusted.isEmpty {
            var message = AppText.adjusted(parameters: adjusted)
            let requestedFps = usesProjectCadence ? proposed.projectFps : proposed.sensorFps
            let effectiveFps = usesProjectCadence ? normalized.projectFps : normalized.sensorFps
            if requestedFps != effectiveFps {
                message += " \(DisplayFormat.fps(requestedFps)) → \(DisplayFormat.fps(effectiveFps)) fps"
                needsCadenceReview = abs(requestedFps - effectiveFps) > 1
            }
            feedbackMessage = message
        }
    }

    private func adjustedParameters(from proposed: CaptureSettings, to normalized: CaptureSettings,
                                    usesProjectCadence: Bool) -> [CaptureParameter] {
        var fields: [CaptureParameter] = []
        if proposed.modeId != normalized.modeId { fields.append(.mode) }
        if proposed.resolutionId != normalized.resolutionId { fields.append(.resolution) }
        if proposed.codecId != normalized.codecId { fields.append(.codec) }
        if proposed.projectFps != normalized.projectFps { fields.append(.projectFps) }
        if !usesProjectCadence, proposed.sensorFps != normalized.sensorFps { fields.append(.sensorFps) }
        if proposed.sensorOverdrive != normalized.sensorOverdrive { fields.append(.sensorOverdrive) }
        return fields
    }

    private func rememberCurrentCamera() {
        guard catalog.cameras.contains(where: { $0.id == settings.cameraId }) else { return }
        // Merge by camera ID against the latest persisted payload rather than
        // writing this window's stale copy over another window's edits.
        cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
        cameraMemories[settings.cameraId] = CameraSettingsMemory(settings: settings)
        persistCameraMemories()
    }

    /// Saved favorites in order, or the default strip before the operator has changed it.
    /// Siri's camera suggestions read the same list so both surfaces rank cameras alike.
    static func favoriteCameraIDs(defaults: UserDefaults, catalog: CatalogData) -> [String] {
        let stored = defaults.stringArray(forKey: quickStartKey) ?? defaultQuickStarts
        // Preserve existing shortcuts as favorites, including an intentionally empty saved list.
        return stored.filter { id in
            catalog.cameras.contains(where: { $0.id == id && !$0.isStandaloneProRes })
        }.uniqued()
    }

    private func persistQuickStarts() {
        defaults.set(quickStartCameraIds, forKey: Self.quickStartKey)
    }

    private func persistCameraMemories() {
        let payload = CameraSettingsMemoryPayload(version: CameraSettingsMemoryPayload.currentVersion,
                                                  memories: cameraMemories)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.cameraMemoryKey)
    }

    private static func loadCameraMemories(defaults: UserDefaults, catalog: CatalogData) -> [String: CameraSettingsMemory] {
        guard let data = defaults.data(forKey: cameraMemoryKey),
              let payload = try? JSONDecoder().decode(CameraSettingsMemoryPayload.self, from: data),
              payload.version == CameraSettingsMemoryPayload.currentVersion else {
            return [:]
        }
        let validIDs = Set(catalog.cameras.map(\.id))
        return payload.memories.filter { validIDs.contains($0.key) }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

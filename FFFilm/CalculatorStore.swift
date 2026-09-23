import Foundation
import Observation

private struct ResetUndoSnapshot {
    let settings: CaptureSettings
    let shutterSettings: ShutterSettings
    let cameraMemories: [String: CameraSettingsMemory]
    let view: CalculatorView
}

@Observable
final class CalculatorStore {
    @ObservationIgnored private let engine: CalculatorEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var cameraMemories: [String: CameraSettingsMemory]
    @ObservationIgnored private var resetUndoSnapshot: ResetUndoSnapshot?

    let catalog: CatalogData
    var settings: CaptureSettings
    var shutterSettings: ShutterSettings
    var shutterInputRevision = 0
    var activeView: CalculatorView = .rate
    var pinnedSetups: [PinnedSetup] = []
    var quickStartCameraIds: [String]

    /// The banner is deliberately modelled as state instead of a transient
    /// toast so VoiceOver and keyboard users can discover important changes.
    var feedbackMessage: String?
    var resetUndoAvailable = false

    private static let quickStartKey = "fffilm.quick-start-camera-ids"
    private static let cameraMemoryKey = "fffilm.camera-settings-memory"
    private static let defaultQuickStarts = ["alexa35", "alexa265", "venice2", "burano"]

    init(catalog suppliedCatalog: CatalogData? = nil, defaults: UserDefaults = .standard) {
        let catalog = suppliedCatalog ?? CatalogData.bundled
        self.catalog = catalog
        self.engine = CalculatorEngine(catalog: catalog)
        self.defaults = defaults
        self.cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
        self.settings = .default
        self.shutterSettings = .default

        let stored = defaults.stringArray(forKey: Self.quickStartKey) ?? Self.defaultQuickStarts
        let validIDs = stored.filter { id in
            catalog.cameras.contains(where: { $0.id == id && !$0.isStandaloneProRes })
        }
        // Preserve existing shortcuts as favorites, including an intentionally empty saved list.
        self.quickStartCameraIds = validIDs.uniqued()

        let defaultSettings = engine.normalized(.default)
        if let memory = cameraMemories[defaultSettings.cameraId] {
            self.settings = engine.normalized(memory.applying(to: defaultSettings))
        } else {
            self.settings = defaultSettings
        }
    }

    var calculation: Calculation { engine.calculate(settings: settings) }
    var shutterCalculation: ShutterCalculation { engine.calculateShutter(settings: shutterSettings) }
    var currentCamera: CameraProfile { engine.camera(id: settings.cameraId) }
    var currentMode: SensorMode { engine.mode(for: settings) }
    var currentResolution: Resolution { engine.resolution(for: settings) }
    var currentCodec: CodecProfile { engine.codec(for: settings) }
    var currentMedia: MediaProfile { engine.media(id: settings.mediaId) }
    var availableCodecs: [CodecProfile] { engine.availableCodecs(for: settings) }
    var availableSensorFrameRates: [Double] { engine.availableSensorFrameRates(for: settings) }

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

    func readableRecordingSummary(storageUnit: StorageUnit) -> String {
        AppText.recordingSummary(settings: settings, calculation: calculation, unit: storageUnit)
    }

    func readableShutterSummary() -> String {
        AppText.shutterSummary(settings: shutterSettings, calculation: shutterCalculation)
    }

    func setActiveView(_ view: CalculatorView) {
        guard activeView != view else { return }
        activeView = view
        clearTransientState()
    }

    func selectCamera(_ id: String) {
        let selectedCamera = engine.camera(id: id)
        // A different window may have edited this camera since this store opened.
        // Every format edit is already persisted, so switching need not save the outgoing state.
        cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)

        var next = settings
        next.cameraId = selectedCamera.id
        if let memory = cameraMemories[selectedCamera.id] {
            next = memory.applying(to: next)
        } else {
            next.modeId = selectedCamera.modes[0].id
            next.resolutionId = engine.preferredResolution(camera: selectedCamera, mode: selectedCamera.modes[0]).id
        }
        commitFormatSettings(next)
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

    func selectProjectFps(_ fps: Double) {
        updateFormatSettings { $0.projectFps = fps }
    }

    func selectSensorFps(_ fps: Double) {
        updateFormatSettings { $0.sensorFps = fps }
    }

    func selectMedia(_ id: String) {
        guard catalog.mediaOptions.contains(where: { $0.id == id }) else { return }
        clearTransientState()
        settings.mediaId = id
    }

    func setShootHours(_ hours: Double) {
        guard hours.isFinite, (0.25 ... 24).contains(hours) else { return }
        clearTransientState()
        settings.shootHours = hours
    }

    func setSensorOverdrive(_ enabled: Bool) {
        updateFormatSettings { $0.sensorOverdrive = enabled }
    }

    /// Shutter controls edit through the store so a new input invalidates the
    /// one-step reset undo before it could overwrite that input.
    func updateShutterSettings<Value>(_ value: Value, at keyPath: WritableKeyPath<ShutterSettings, Value>) {
        clearTransientState()
        shutterSettings[keyPath: keyPath] = value
    }

    func resetActiveView() {
        #if os(macOS)
        // The film workbench owns its document lifecycle; calculator reset does not apply.
        guard activeView != .film else { return }
        #endif
        cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
        resetUndoSnapshot = ResetUndoSnapshot(
            settings: settings,
            shutterSettings: shutterSettings,
            cameraMemories: cameraMemories,
            view: activeView
        )
        resetUndoAvailable = true
        feedbackMessage = AppText.reset

        if activeView == .rate {
            settings = engine.normalized(.default)
            rememberCurrentCamera()
        } else {
            shutterSettings = .default
            shutterInputRevision += 1
        }
    }

    func undoReset() {
        guard let snapshot = resetUndoSnapshot else { return }
        settings = snapshot.settings
        shutterSettings = snapshot.shutterSettings
        if snapshot.view == .rate {
            // Undo only the default camera record reset changed; keep other
            // windows' later edits to unrelated cameras.
            cameraMemories = Self.loadCameraMemories(defaults: defaults, catalog: catalog)
            let defaultCameraID = engine.normalized(.default).cameraId
            cameraMemories[defaultCameraID] = snapshot.cameraMemories[defaultCameraID]
            persistCameraMemories()
        }
        resetUndoSnapshot = nil
        resetUndoAvailable = false
        feedbackMessage = AppText.resetUndone
    }

    /// One-shot import deliberately leaves RATE, angles and lighting unchanged.
    @discardableResult
    func importShutterFrameRates() -> (sensor: Double, project: Double) {
        clearTransientState()
        shutterSettings.sensorFps = settings.sensorFps
        shutterSettings.projectFps = settings.projectFps
        return (settings.sensorFps, settings.projectFps)
    }

    @discardableResult
    func pinCurrentSetup() -> ComparisonAddResult {
        if pinnedSetups.contains(where: { $0.settings == settings }) {
            feedbackMessage = AppText.comparisonDuplicate
            return .duplicate
        }
        guard pinnedSetups.count < 4 else {
            feedbackMessage = AppText.comparisonFull
            return .full
        }
        pinnedSetups.append(PinnedSetup(id: UUID(), settings: settings, calculation: calculation))
        feedbackMessage = AppText.comparisonAdded
        return .added
    }

    func removePinnedSetup(id: UUID) {
        pinnedSetups.removeAll { $0.id == id }
    }

    func clearTransientState() {
        feedbackMessage = nil
        resetUndoSnapshot = nil
        resetUndoAvailable = false
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

    private func updateFormatSettings(_ mutation: (inout CaptureSettings) -> Void) {
        var next = settings
        mutation(&next)
        commitFormatSettings(next)
    }

    private func commitFormatSettings(_ proposed: CaptureSettings) {
        clearTransientState()
        let normalized = engine.normalized(proposed)
        let adjusted = adjustedParameters(from: proposed, to: normalized)
        settings = normalized
        rememberCurrentCamera()
        if !adjusted.isEmpty {
            feedbackMessage = AppText.adjusted(parameters: adjusted)
        }
    }

    private func adjustedParameters(from proposed: CaptureSettings, to normalized: CaptureSettings) -> [CaptureParameter] {
        var fields: [CaptureParameter] = []
        if proposed.modeId != normalized.modeId { fields.append(.mode) }
        if proposed.resolutionId != normalized.resolutionId { fields.append(.resolution) }
        if proposed.codecId != normalized.codecId { fields.append(.codec) }
        if proposed.projectFps != normalized.projectFps { fields.append(.projectFps) }
        if proposed.sensorFps != normalized.sensorFps { fields.append(.sensorFps) }
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

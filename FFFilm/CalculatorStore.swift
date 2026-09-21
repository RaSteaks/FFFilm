import Foundation
import Observation

@Observable
final class CalculatorStore {
    @ObservationIgnored private let engine: CalculatorEngine
    @ObservationIgnored private let defaults: UserDefaults

    let catalog: CatalogData
    var settings: CaptureSettings
    var shutterSettings: ShutterSettings
    var shutterInputRevision = 0
    var activeView: CalculatorView = .rate
    var pinnedSetups: [PinnedSetup] = []
    var quickStartCameraIds: [String]

    private static let quickStartKey = "fffilm.quick-start-camera-ids"
    private static let defaultQuickStarts = ["alexa35", "alexa265", "venice2", "burano"]

    init(catalog: CatalogData = .bundled, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.engine = CalculatorEngine(catalog: catalog)
        self.defaults = defaults
        self.settings = .default
        self.shutterSettings = .default

        let stored = defaults.stringArray(forKey: Self.quickStartKey) ?? Self.defaultQuickStarts
        let validIDs = stored.filter { id in
            catalog.cameras.contains(where: { $0.id == id && !$0.isStandaloneProRes })
        }
        // Preserve existing shortcuts as favorites, including an intentionally empty saved list.
        self.quickStartCameraIds = validIDs.uniqued()
        self.settings = engine.normalized(settings)
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

    func selectCamera(_ id: String) {
        let selectedCamera = engine.camera(id: id)
        var next = settings
        next.cameraId = selectedCamera.id
        next.modeId = selectedCamera.modes[0].id
        next.resolutionId = engine.preferredResolution(camera: selectedCamera, mode: selectedCamera.modes[0]).id
        settings = engine.normalized(next)
    }

    func selectMode(_ id: String) {
        var next = settings
        next.modeId = id
        let selectedMode = engine.mode(for: next)
        next.resolutionId = selectedMode.resolutions[0].id
        settings = engine.normalized(next)
    }

    func selectResolution(_ id: String) {
        updateSettings { $0.resolutionId = id }
    }

    func selectCodec(_ id: String) {
        updateSettings { $0.codecId = id }
    }

    func selectProjectFps(_ fps: Double) {
        updateSettings { $0.projectFps = fps }
    }

    func selectSensorFps(_ fps: Double) {
        updateSettings { $0.sensorFps = fps }
    }

    func selectMedia(_ id: String) {
        updateSettings { $0.mediaId = id }
    }

    func setShootHours(_ hours: Double) {
        updateSettings { $0.shootHours = hours }
    }

    func setSensorOverdrive(_ enabled: Bool) {
        updateSettings { $0.sensorOverdrive = enabled }
    }

    func resetActiveView() {
        if activeView == .rate {
            settings = engine.normalized(.default)
        } else {
            shutterSettings = .default
            shutterInputRevision += 1
        }
    }

    /// One-shot import deliberately leaves RATE, angles and lighting unchanged.
    func importShutterFrameRates() {
        shutterSettings.sensorFps = settings.sensorFps
        shutterSettings.projectFps = settings.projectFps
    }

    func pinCurrentSetup() {
        guard pinnedSetups.count < 4 else { return }
        pinnedSetups.append(PinnedSetup(id: UUID(), settings: settings, calculation: calculation))
    }

    func removePinnedSetup(id: UUID) {
        pinnedSetups.removeAll { $0.id == id }
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
              (0...quickStartCameraIds.count).contains(destination) else { return }
        let moving = offsets.map { quickStartCameraIds[$0] }
        var remaining = quickStartCameraIds.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: insertion)
        guard remaining != quickStartCameraIds else { return }
        quickStartCameraIds = remaining
        persistQuickStarts()
    }

    private func updateSettings(_ mutation: (inout CaptureSettings) -> Void) {
        var next = settings
        mutation(&next)
        settings = engine.normalized(next)
    }

    private func persistQuickStarts() {
        defaults.set(quickStartCameraIds, forKey: Self.quickStartKey)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

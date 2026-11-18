import AppIntents
import Foundation

/// Plain-text answers shared by Siri, Shortcuts and the unit tests. They follow the system
/// language Siri speaks rather than the in-app language preference.
enum RecordingEstimate {
    static func storageAnswer(cameraID: String, hours: Double, defaults: UserDefaults = .standard,
                              catalog: CatalogData = .bundled) -> String {
        // Asking Siri about zero recording time has no useful answer, though the wheel allows it.
        guard hours.isFinite, hours > 0, CaptureSettings.shootHoursRange.contains(hours) else {
            return String(localized: "intent.estimate.invalidDuration",
                          defaultValue: "Give a recording time from one second to 24 hours.",
                          comment: "Siri answer when the requested duration is outside the supported range.")
        }
        let engine = CalculatorEngine(catalog: catalog)
        // The camera's remembered format is what the operator last chose for it in the app.
        var proposed = CalculatorStore.rememberedSettings(cameraID: cameraID, base: .default,
                                                          defaults: defaults, catalog: catalog)
        proposed.shootHours = hours
        let settings = engine.normalized(proposed)
        let result = engine.calculate(settings: settings)
        let unit = storageUnit(defaults)
        let fps = result.camera.isStandaloneProRes ? settings.projectFps : settings.sensorFps
        let format = "\(result.camera.name) · \(result.codec.name) · \(DisplayFormat.fps(fps)) fps"
        let duration = DisplayFormat.plannedDuration(settings.shootHours)
        let storage = DisplayFormat.compactStorage(result.dayTotalGb, unit: unit)
        let rate = "\(DisplayFormat.number(unit.converted(decimalGB: result.sensorGbPerHour))) \(unit.symbol)/h"
        return String(localized: "intent.estimate.answer",
                      defaultValue: "\(format) for \(duration) needs about \(storage) (\(rate)).",
                      comment: "Siri answer: camera format, recording time, storage and hourly rate.")
    }

    static func summaryAnswer(defaults: UserDefaults = .standard, catalog: CatalogData = .bundled) -> String {
        let engine = CalculatorEngine(catalog: catalog)
        let entries = RecordingSummary(defaults: defaults, engine: engine).entries
        guard !entries.isEmpty else {
            return String(localized: "intent.summary.empty", defaultValue: "The summary is empty.",
                          comment: "Siri answer when no setups have been added to the summary.")
        }
        let total = entries.reduce(0) { $0 + engine.calculate(settings: $1.settings).dayTotalGb }
        let storage = DisplayFormat.compactStorage(total, unit: storageUnit(defaults))
        return String(localized: "intent.summary.answer",
                      defaultValue: "\(entries.count) setups in the summary need \(storage) in total.",
                      comment: "Siri answer: number of summary entries and their total storage.")
    }

    private static func storageUnit(_ defaults: UserDefaults) -> StorageUnit {
        defaults.string(forKey: StorageUnit.preferenceKey).flatMap(StorageUnit.init(rawValue:)) ?? .decimal
    }
}

struct CameraEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "intent.camera.type"
    static let defaultQuery = CameraQuery()
    let id: String
    let name: String
    let manufacturer: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(manufacturer)")
    }

    init(_ camera: CameraProfile) {
        id = camera.id
        name = camera.name
        manufacturer = camera.manufacturer.rawValue
    }
}

struct CameraQuery: EntityStringQuery {
    private var cameras: [CameraProfile] { CatalogData.bundled.cameras }

    func entities(for identifiers: [String]) async throws -> [CameraEntity] {
        cameras.filter { identifiers.contains($0.id) }.map(CameraEntity.init)
    }

    /// Spoken names drop spaces and hyphens ("Alexa 35", "alexa35"), so compare without them.
    func entities(matching string: String) async throws -> [CameraEntity] {
        let needle = Self.normalized(string)
        guard !needle.isEmpty else { return [] }
        return cameras.filter { Self.normalized($0.name).contains(needle) }.map(CameraEntity.init)
    }

    /// Favorites first, matching the calculator's quick-start strip, then the rest of the catalog.
    func suggestedEntities() async throws -> [CameraEntity] {
        let favorites = UserDefaults.standard.stringArray(forKey: "fffilm.quick-start-camera-ids") ?? []
        let ranked = cameras.sorted { lhs, rhs in
            let left = favorites.firstIndex(of: lhs.id) ?? .max
            let right = favorites.firstIndex(of: rhs.id) ?? .max
            return left == right ? lhs.name < rhs.name : left < right
        }
        return ranked.map(CameraEntity.init)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct EstimateStorageIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.estimate.title"
    static let description = IntentDescription("intent.estimate.description")

    @Parameter(title: "intent.estimate.camera")
    var camera: CameraEntity

    @Parameter(title: "intent.estimate.duration", defaultUnit: .hours, supportsNegativeNumbers: false)
    var duration: Measurement<UnitDuration>

    static var parameterSummary: some ParameterSummary {
        Summary("Estimate storage for \(\.$camera) over \(\.$duration)")
    }

    // The catalog, camera memory and formatting all live on the main actor.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = RecordingEstimate.storageAnswer(cameraID: camera.id, hours: duration.converted(to: .hours).value)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

struct SummaryTotalIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.summary.title"
    static let description = IntentDescription("intent.summary.description")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: RecordingEstimate.summaryAnswer()))
    }
}

struct FFFilmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: EstimateStorageIntent(), phrases: [
            "Estimate storage with \(.applicationName)",
            "Estimate \(\.$camera) storage with \(.applicationName)",
        ], shortTitle: "intent.estimate.shortTitle", systemImageName: "externaldrive")
        AppShortcut(intent: SummaryTotalIntent(), phrases: [
            "\(.applicationName) summary total",
            "Show the \(.applicationName) summary total",
        ], shortTitle: "intent.summary.shortTitle", systemImageName: "sum")
    }
}

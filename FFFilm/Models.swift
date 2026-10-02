import Foundation

// MARK: - Catalog

enum CameraManufacturer: String, Codable, CaseIterable, Hashable {
    case arri = "ARRI"
    case sony = "SONY"
    case canon = "CANON"
    case red = "RED"
    case dji = "DJI"
    case kinefinity = "KINEFINITY"
    case apple = "APPLE"
}

enum CaptureSourceType: String, Codable, Hashable {
    case camera
    case proRes = "prores"
}

enum RateModel: String, Codable, Hashable {
    case appleTarget = "apple-target"
    case estimatedBitsPerPixel = "estimated-bpp"
    // Manufacturer-published sensor-rate rows; the table is shared across brands.
    case publishedTable = "published-table"
}

/// Optical crop relative to the resolution's base area, independent of encoded pixels.
struct SensorCrop: Codable, Hashable {
    let minSensorFps: Double
    let factor: Double
}

struct Resolution: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let width: Int
    let height: Int
    let activeWidth: Int?
    let activeHeight: Int?
    let maxSensorFps: Double?
    // Published optical dimensions preserve the field of view of oversampled modes.
    let activeWidthMm: Double?
    let activeHeightMm: Double?
    // Some internal recording formats crop only at high capture cadences.
    let sensorCrop: SensorCrop?
    let minSensorFps: Double?
    let supportedCodecIds: [String]?
}

struct SensorMode: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let note: String
    let resolutions: [Resolution]
}

struct CameraProfile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: CameraManufacturer
    let sourceType: CaptureSourceType?
    let maxSensorFps: Double?
    let maxSensorFpsWithoutOverdrive: Double?
    let supportsSensorOverdrive: Bool?
    let sensorLabel: String
    let sensorWidthMm: Double
    let sensorHeightMm: Double
    let nativeWidth: Int
    let nativeHeight: Int
    let imageCircleMm: Double
    let modes: [SensorMode]
    // An explicit allowlist prevents generic codecs leaking into camera-specific formats.
    let supportedCodecIds: [String]?

    var isStandaloneProRes: Bool { sourceType == .proRes }
}

struct CodecProfile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let rateModel: RateModel
    let effectiveBitsPerPixel: Double?
    let note: String
    let supportedManufacturers: [CameraManufacturer]?
    let supportedCameraIds: [String]?
}

struct MediaProfile: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let capacityGb: Double
}

struct CatalogData: Codable, Hashable {
    let cameras: [CameraProfile]
    let codecs: [CodecProfile]
    let mediaOptions: [MediaProfile]
    let frameRates: [Double]
    let projectFrameRates: [Double]
    let proResRateTable: [String: [String: [String: Double]]]
    // Published per-camera rows keyed "camera|codec|resolution" → frame rate → MB/s payload.
    let rateTable: [String: [String: Double]]

    static let bundled: CatalogData = {
        do {
            return try load()
        } catch {
            fatalError("Catalog.json could not be loaded: \(error)")
        }
    }()

    static func load(bundle: Bundle? = nil) throws -> CatalogData {
        let resourceBundle = bundle ?? Bundle(for: CatalogBundleToken.self)
        guard let url = resourceBundle.url(forResource: "Catalog", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try JSONDecoder().decode(CatalogData.self, from: Data(contentsOf: url))
    }
}

private final class CatalogBundleToken {}

private enum CatalogError: LocalizedError {
    case missingResource

    var errorDescription: String? {
        "Catalog.json is missing from the application bundle."
    }
}

// MARK: - Calculator state

struct CaptureSettings: Codable, Equatable, Hashable {
    var cameraId: String
    var modeId: String
    var resolutionId: String
    var codecId: String
    var projectFps: Double
    var sensorFps: Double
    var sensorOverdrive: Bool
    var mediaId: String
    var shootHours: Double

    static let `default` = CaptureSettings(
        cameraId: "alexa35",
        modeId: "open-gate",
        resolutionId: "a35-open",
        codecId: "arriraw-hde",
        projectFps: 24,
        sensorFps: 24,
        sensorOverdrive: false,
        mediaId: "2tb",
        shootHours: 8
    )
}

/// The camera-scoped part of a capture setup. Media and planned duration stay
/// window-local, so switching cameras never unexpectedly changes the budget.
struct CameraSettingsMemory: Codable, Equatable, Hashable {
    let modeId: String
    let resolutionId: String
    let codecId: String
    let projectFps: Double
    let sensorFps: Double
    let sensorOverdrive: Bool

    init(settings: CaptureSettings) {
        modeId = settings.modeId
        resolutionId = settings.resolutionId
        codecId = settings.codecId
        projectFps = settings.projectFps
        sensorFps = settings.sensorFps
        sensorOverdrive = settings.sensorOverdrive
    }

    func applying(to settings: CaptureSettings) -> CaptureSettings {
        var restored = settings
        restored.modeId = modeId
        restored.resolutionId = resolutionId
        restored.codecId = codecId
        restored.projectFps = projectFps
        restored.sensorFps = sensorFps
        restored.sensorOverdrive = sensorOverdrive
        return restored
    }
}

/// UserDefaults payloads are versioned so a future catalog change can ignore
/// stale data safely instead of feeding unknown selections into the engine.
struct CameraSettingsMemoryPayload: Codable, Equatable {
    static let currentVersion = 1
    let version: Int
    let memories: [String: CameraSettingsMemory]
}

enum CaptureParameter: String, CaseIterable, Hashable {
    case mode, resolution, codec, projectFps, sensorFps, sensorOverdrive

    var label: LocalizedStringResource {
        switch self {
        case .mode: "field.mode"
        case .resolution: "field.resolution"
        case .codec: "field.codec"
        case .projectFps: "field.projectFps"
        case .sensorFps: "field.sensorFps"
        case .sensorOverdrive: "field.overdrive"
        }
    }
}

enum ComparisonAddResult: Equatable {
    case added
    case duplicate
    case full
}

struct Calculation: Hashable {
    let camera: CameraProfile
    let mode: SensorMode
    let resolution: Resolution
    let codec: CodecProfile
    let media: MediaProfile
    let projectMbps: Double
    let sensorMbps: Double
    let projectGbPerHour: Double
    let sensorGbPerHour: Double
    let projectRuntimeHours: Double
    let captureRuntimeHours: Double
    let dayTotalGb: Double
    let dayUsagePercent: Double
    let clipWidthMm: Double
    let clipHeightMm: Double
    let imageCircleMm: Double
    let formatFactor: Double
}

struct PinnedSetup: Identifiable, Hashable {
    let id: UUID
    let settings: CaptureSettings
    let calculation: Calculation
}

/// Two independent planning questions share one camera format without overwriting inputs.
enum RecordingTask: String, CaseIterable, Identifiable {
    case capacity, runtime

    var id: Self { self }
    var label: LocalizedStringResource {
        switch self {
        case .capacity: "recording.capacity"
        case .runtime: "recording.runtime"
        }
    }
    var hint: LocalizedStringResource {
        switch self {
        case .capacity: "recording.capacityHint"
        case .runtime: "recording.runtimeHint"
        }
    }
}

enum CalculatorView: String, CaseIterable, Identifiable, Hashable {
    case rate = "RATE"
    case shutter = "SHUTTER"
    // The film editor is macOS-only, so its navigation segment never appears on iOS.
    #if os(macOS)
    case film = "FILM"
    #endif

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .rate: "nav.recording"
        case .shutter: "nav.shutter"
        #if os(macOS)
        case .film: "nav.film"
        #endif
        }
    }
}

// MARK: - Shutter workbench

enum ShutterMode: String, CaseIterable, Identifiable, Hashable {
    case conversion, flicker, matching
    var id: Self { self }
    var label: LocalizedStringResource {
        switch self {
        case .conversion: "shutter.mode.conversion"
        case .flicker: "shutter.mode.flicker"
        case .matching: "shutter.mode.matching"
        }
    }
}

enum ShutterDirection: String, CaseIterable, Identifiable {
    case angleToTime, timeToAngle
    var id: Self { self }
    var label: LocalizedStringResource {
        self == .angleToTime ? "shutter.direction.angleToTime" : "shutter.direction.timeToAngle"
    }
}

enum ShutterMatch: String, CaseIterable, Identifiable {
    case exposure, angle
    var id: Self { self }
    var label: LocalizedStringResource {
        self == .exposure ? "shutter.match.exposure" : "shutter.match.angle"
    }
}

enum ShutterLight: String, CaseIterable, Identifiable {
    case mains50, mains60, custom, displays
    var id: Self { self }
    var label: LocalizedStringResource {
        switch self {
        case .mains50: "shutter.light.mains50"
        case .mains60: "shutter.light.mains60"
        case .custom: "shutter.light.custom"
        case .displays: "shutter.light.displays"
        }
    }
}

/// Presets opt into exact fractional cadence; typed decimals are never reinterpreted.
enum ShutterFramePreset: String, CaseIterable, Identifiable {
    case fractional24, fractional30, fractional60, fps24, fps25, fps30, fps48, fps50, fps60, fps120
    var id: Self { self }
    var fps: Double {
        switch self {
        case .fractional24: 24_000 / 1_001
        case .fractional30: 30_000 / 1_001
        case .fractional60: 60_000 / 1_001
        case .fps24: 24
        case .fps25: 25
        case .fps30: 30
        case .fps48: 48
        case .fps50: 50
        case .fps60: 60
        case .fps120: 120
        }
    }
    var label: String {
        switch self {
        case .fractional24: "23.976 (24000/1001)"
        case .fractional30: "29.97 (30000/1001)"
        case .fractional60: "59.94 (60000/1001)"
        default: "\(Int(fps)) fps"
        }
    }
}

struct ShutterSettings: Equatable, Hashable {
    var mode: ShutterMode = .conversion
    var direction: ShutterDirection = .angleToTime
    var match: ShutterMatch = .exposure
    var sensorFps: Double = 24
    var projectFps: Double = 24
    var angle: Double = 180
    var shutterDenominator: Double = 48
    var targetAngle: Double = 180
    var preferredAngle: Double = 180
    var maxAngle: Double = 360
    var light: ShutterLight = .mains50
    var customLightHz: Double = 100
    var checksFlicker = false
    // Preserve the editable list, including unfinished input, across mode changes and RATE imports.
    var displayRefreshRates = "60, 120"

    var lightHz: Double {
        switch light {
        case .mains50: 100
        case .mains60: 120
        case .custom: customLightHz
        case .displays: .nan // The engine derives the common period from validated refresh rates.
        }
    }
    // Resolve validation at display time so it follows the in-app language.
    static var displayRefreshError: String {
        AppText.resolve("shutter.displayRefreshError", defaultValue: "Enter 2–16 refresh rates (0.001–1000000 Hz, up to three decimals), separated by commas. Use . for decimals.",
               comment: "Inline validation for the multiple-display refresh-rate list.")
    }

    /// Parse decimal Hz as exact milli-Hz; never round distinct refresh rates into a common rate.
    var displayRefreshMilliHz: [Int64]? {
        let entries = displayRefreshRates.replacingOccurrences(of: "，", with: ",")
            .components(separatedBy: ",")
        guard (2...16).contains(entries.count) else { return nil }
        var rates: [Int64] = []
        for entry in entries {
            let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ "0123456789".contains($0) }) }),
                  let whole = Int64(parts[0]), whole <= 1_000_000 else { return nil }
            let fraction = parts.count == 2 ? String(parts[1]) : ""
            guard fraction.count <= 3,
                  let milli = Int64(fraction + String(repeating: "0", count: 3 - fraction.count)) else { return nil }
            let rate = whole * 1_000 + milli
            guard (1...1_000_000_000).contains(rate) else { return nil }
            rates.append(rate)
        }
        return rates
    }

    var needsLight: Bool { mode == .flicker || (mode == .matching && checksFlicker) }
    static let `default` = ShutterSettings()
}

/// Both the engine and editable fields use these same domain limits.
enum ShutterInputField: String, Hashable {
    case sensorFps, projectFps, angle, shutterDenominator, targetAngle, preferredAngle, maxAngle, customLightHz

    var keyPath: WritableKeyPath<ShutterSettings, Double> {
        switch self {
        case .sensorFps: \.sensorFps
        case .projectFps: \.projectFps
        case .angle: \.angle
        case .shutterDenominator: \.shutterDenominator
        case .targetAngle: \.targetAngle
        case .preferredAngle: \.preferredAngle
        case .maxAngle: \.maxAngle
        case .customLightHz: \.customLightHz
        }
    }

    func error(for value: Double) -> String? {
        guard value.isFinite, value > 0 else {
            return AppText.resolve("field.validationFinite", defaultValue: "Enter a finite number greater than zero.",
                          comment: "Validation for a positive numeric shutter input.")
        }
        switch self {
        case .sensorFps, .projectFps:
            return (0.001 ... 10_000).contains(value) ? nil : AppText.resolve("field.validationFPS", defaultValue: "Enter 0.001–10000 fps.",
                                                                        comment: "FPS validation range.")
        case .maxAngle:
            return value <= 360 ? nil : AppText.resolve("field.validationAngle", defaultValue: "Maximum angle must be at most 360°.",
                                                comment: "Maximum shutter angle validation.")
        default:
            return nil
        }
    }
}

struct ShutterExposure: Equatable, Hashable {
    let exposureSeconds: Double
    let angle: Double
    let framePeriodMs: Double
    var exposureMs: Double { exposureSeconds * 1_000 }
    var shutterDenominator: Double { 1 / exposureSeconds }
}

struct ShutterCandidate: Equatable, Hashable, Identifiable {
    // Cycle count is stable across result sorting and avoids index-based row identity.
    let cycles: Double
    let exposure: ShutterExposure
    var id: Double { cycles }
}

/// A cycle-domain mismatch, not an estimate of measured flicker or brightness.
struct DisplayCycleMatch: Equatable, Hashable, Identifiable {
    let hz: Double
    let cycles: Double
    var nearestCycles: Double { max(1, cycles.rounded()) }
    var error: Double { abs(cycles - nearestCycles) }
    var id: Double { hz }
}

struct ShutterCompromise: Equatable, Hashable {
    let exposure: ShutterExposure
    let displays: [DisplayCycleMatch]
    let approximateSearch: Bool
    var worstError: Double { displays.map(\.error).max() ?? 0 }
}

enum ShutterStatus: Equatable, Hashable {
    case valid, exceedsMaximum, noCandidates
    case invalidInput(ShutterInputField)
    case numericalLimit
    case invalidDisplays
}

struct ShutterCalculation: Equatable, Hashable {
    let status: ShutterStatus
    var exposure: ShutterExposure? = nil
    var playbackSpeed: Double? = nil
    var durationMultiplier: Double? = nil
    var matchesLightCycles: Bool? = nil
    var candidates: [ShutterCandidate] = []
    // Separate from exact candidates so matching mode never replaces its target exposure.
    var compromise: ShutterCompromise? = nil
}

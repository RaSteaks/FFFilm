import Foundation
import Testing
@testable import FFFilm

struct ShutterTests {
    private var engine: CalculatorEngine { CalculatorEngine(catalog: .bundled) }

    @Test("Angle and time round-trip without rounding the exposure")
    func conversion() throws {
        var settings = ShutterSettings.default
        let forward = try #require(engine.calculateShutter(settings: settings).exposure)
        #expect(abs(forward.shutterDenominator - 48) < 1e-10)
        #expect(abs(forward.exposureMs - 20.833333333333) < 1e-9)
        settings.direction = .timeToAngle
        settings.shutterDenominator = forward.shutterDenominator
        let reverse = try #require(engine.calculateShutter(settings: settings).exposure)
        #expect(abs(reverse.angle - 180) < 1e-10)
    }

    @Test("Decimal inputs remain decimal; fractional presets explicitly opt into rational cadence")
    func fractionalRates() throws {
        var settings = ShutterSettings.default
        settings.sensorFps = 23.976
        settings.angle = 172.8
        let decimal = try #require(engine.calculateShutter(settings: settings).exposure)
        #expect(abs(decimal.shutterDenominator - 49.95) < 1e-10)
        #expect(DisplayFormat.shutterNumber(decimal.shutterDenominator) == "49.95")
        settings.sensorFps = ShutterFramePreset.fractional24.fps
        let rational = try #require(engine.calculateShutter(settings: settings).exposure)
        #expect(settings.sensorFps == 24_000.0 / 1_001)
        #expect(abs(rational.shutterDenominator - decimal.shutterDenominator) > 1e-6)
    }

    @Test("Mains models choose complete cycles and break distance ties toward the lower angle")
    func lightCandidates() throws {
        var settings = ShutterSettings.default
        settings.mode = .flicker
        let fifty = engine.calculateShutter(settings: settings)
        #expect(fifty.status == .valid)
        #expect(fifty.candidates.count == 3)
        let first = try #require(fifty.exposure)
        #expect(abs(first.angle - 172.8) < 1e-10)
        #expect(abs(first.shutterDenominator - 50) < 1e-10)
        settings.light = .mains60
        let sixty = engine.calculateShutter(settings: settings)
        #expect(sixty.candidates.map { $0.exposure.angle } == [144, 216, 72])
        // Custom input already means optical Hz and must not be multiplied by two.
        settings.light = .custom
        settings.customLightHz = 120
        #expect(engine.calculateShutter(settings: settings).candidates == sixty.candidates)
    }

    @Test("No complete cycle fits above the light pulse rate")
    func noCandidates() {
        var settings = ShutterSettings.default
        settings.mode = .flicker
        settings.sensorFps = 120
        let result = engine.calculateShutter(settings: settings)
        #expect(result.status == .noCandidates)
        #expect(result.exposure == nil)
        #expect(result.candidates.isEmpty)
    }

    @Test("Matching exposure preserves impossible theoretical angles")
    func matchingExposure() throws {
        var settings = ShutterSettings.default
        settings.mode = .matching
        settings.sensorFps = 48
        let matching = engine.calculateShutter(settings: settings)
        let exposure = try #require(matching.exposure)
        #expect(matching.status == .valid)
        #expect(exposure.angle == 360)
        #expect(exposure.shutterDenominator == 48)
        settings.maxAngle = 356
        let capped = engine.calculateShutter(settings: settings)
        #expect(capped.status == .exceedsMaximum)
        #expect(capped.exposure == exposure)
        settings.maxAngle = 360
        settings.sensorFps = 60
        let impossible = engine.calculateShutter(settings: settings)
        #expect(impossible.status == .exceedsMaximum)
        #expect(impossible.exposure?.angle == 450)
        settings.sensorFps = 12
        #expect(engine.calculateShutter(settings: settings).exposure?.angle == 90)
    }

    @Test("Keeping angle separates real exposure from retimed playback")
    func matchingAngle() throws {
        var settings = ShutterSettings.default
        settings.mode = .matching
        settings.match = .angle
        settings.sensorFps = 60
        let result = engine.calculateShutter(settings: settings)
        let exposure = try #require(result.exposure)
        #expect(exposure.angle == 180)
        #expect(exposure.shutterDenominator == 120)
        #expect(result.playbackSpeed == 0.4)
        #expect(result.durationMultiplier == 2.5)
    }

    @Test("Optional light checks never replace the matching target")
    func optionalCheck() throws {
        var settings = ShutterSettings.default
        settings.mode = .matching
        settings.sensorFps = 60
        let original = engine.calculateShutter(settings: settings)
        settings.checksFlicker = true
        let checked = engine.calculateShutter(settings: settings)
        #expect(checked.exposure == original.exposure)
        #expect(checked.status == .exceedsMaximum)
        #expect(checked.matchesLightCycles == false)
        #expect(checked.candidates.first?.exposure.angle == 216)
        settings.targetAngle = 172.8
        #expect(engine.calculateShutter(settings: settings).matchesLightCycles == true)
        settings.targetAngle = 172.8001
        #expect(engine.calculateShutter(settings: settings).matchesLightCycles == false)
    }

    @Test("Active fields reject invalid values instead of producing fallback results",
          arguments: [0.0, -1, Double.nan, Double.infinity, -Double.infinity])
    func invalidInputs(_ value: Double) {
        for field in [ShutterInputField.sensorFps, .angle, .maxAngle] {
            var settings = ShutterSettings.default
            settings[keyPath: field.keyPath] = value
            let result = engine.calculateShutter(settings: settings)
            #expect(result.status == .invalidInput(field))
            #expect(result.exposure == nil)
        }
        var settings = ShutterSettings.default
        settings.direction = .timeToAngle
        settings.shutterDenominator = value
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.shutterDenominator))
        settings = .default
        settings.mode = .matching
        settings.projectFps = value
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.projectFps))
        settings.projectFps = 24
        settings.targetAngle = value
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.targetAngle))
        settings = .default
        settings.mode = .flicker
        settings.preferredAngle = value
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.preferredAngle))
        settings.preferredAngle = 180
        settings.light = .custom
        settings.customLightHz = value
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.customLightHz))
    }

    @Test("Bounds, inactive inputs and numeric overflow are explicit")
    func bounds() {
        var settings = ShutterSettings.default
        settings.sensorFps = 0.0001
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.sensorFps))
        settings.sensorFps = 10_001
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.sensorFps))
        settings.sensorFps = 24
        settings.maxAngle = 361
        #expect(engine.calculateShutter(settings: settings).status == .invalidInput(.maxAngle))
        settings = .default
        settings.customLightHz = .nan
        settings.projectFps = .nan
        #expect(engine.calculateShutter(settings: settings).status == .valid)
        settings.direction = .timeToAngle
        settings.shutterDenominator = .leastNonzeroMagnitude
        #expect(engine.calculateShutter(settings: settings).status == .numericalLimit)
    }

    @Test("Cycle search is bounded, honors small limits and keeps floating point boundary candidates")
    func candidateBoundaries() throws {
        var settings = ShutterSettings.default
        settings.mode = .flicker
        settings.maxAngle = 172.8
        let boundary = engine.calculateShutter(settings: settings)
        #expect(boundary.candidates.count == 2)
        #expect(abs(try #require(boundary.exposure).angle - 172.8) < 1e-10)
        settings.maxAngle = 172.7999
        #expect(engine.calculateShutter(settings: settings).candidates.count == 1)
        settings.maxAngle = 1
        #expect(engine.calculateShutter(settings: settings).status == .noCandidates)
        settings.maxAngle = 360
        settings.light = .custom
        settings.customLightHz = 1_000_000_000
        #expect(engine.calculateShutter(settings: settings).candidates.count == 3)
        settings.customLightHz = .greatestFiniteMagnitude
        #expect(engine.calculateShutter(settings: settings).status == .numericalLimit)
        settings.light = .mains50
        settings.preferredAngle = .greatestFiniteMagnitude
        #expect(engine.calculateShutter(settings: settings).candidates.map(\.cycles) == [4, 3, 2])
    }

    @Test("Large cycle counts do not classify a fractional cycle as a model match")
    func largeCycleFraction() {
        var settings = ShutterSettings.default
        settings.mode = .matching
        settings.checksFlicker = true
        settings.light = .custom
        settings.customLightHz = (100_000_000_000_000.5) * 48
        #expect(engine.calculateShutter(settings: settings).matchesLightCycles == false)
        #expect(DisplayFormat.shutterNumber(0.00000001) != "0")
    }

    @Test("Nearest candidates match exhaustive enumeration for representative inputs")
    func rankedCandidates() {
        // Compare the bounded production search with an independent small exhaustive oracle.
        for fps in [12.0, 23.976, 24, 25, 60, 120] {
            for target in [1.0, 90, 172.8, 180, 450] {
                var settings = ShutterSettings.default
                settings.mode = .flicker
                settings.sensorFps = fps
                settings.preferredAngle = target
                let step = 360 * fps / 100
                let count = Int(floor(360 / step + 1e-12))
                let expected = count == 0 ? [] : (1 ... count).map { Double($0) }.sorted {
                    let left = abs($0 * step - target), right = abs($1 * step - target)
                    return abs(left - right) < 1e-10 ? $0 < $1 : left < right
                }
                #expect(engine.calculateShutter(settings: settings).candidates.map(\.cycles) == Array(expected.prefix(3)))
            }
        }
    }

    @MainActor
    @Test("RATE import is one-shot and reset restores all shutter defaults")
    func importAndReset() {
        let store = CalculatorStore()
        store.settings.sensorFps = 47.952
        store.settings.projectFps = 23.976
        let rateBefore = store.settings
        store.shutterSettings.mode = .matching
        store.shutterSettings.targetAngle = 172.8
        store.shutterSettings.light = .mains60
        store.importShutterFrameRates()
        #expect(store.shutterSettings.sensorFps == 47.952)
        #expect(store.shutterSettings.projectFps == 23.976)
        #expect(store.shutterSettings.targetAngle == 172.8)
        #expect(store.shutterSettings.light == .mains60)
        store.shutterSettings.sensorFps = 120
        #expect(store.settings == rateBefore)
        store.activeView = .shutter
        store.resetActiveView()
        #expect(store.shutterSettings == .default)
        #expect(store.settings == rateBefore)
        #expect(store.shutterInputRevision == 1)
    }
}

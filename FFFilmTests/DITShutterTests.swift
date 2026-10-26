import Foundation
import Testing
@testable import FFFilm

@MainActor
struct DITShutterTests {
    @Test func timeExpressionsPreserveUnitsAndRejectIncompleteInput() throws {
        for input in ["50", "1/50", "1 / 50 s", "20 ms", "0.02 s", "2/100 s", "20 MS"] {
            #expect(abs(try #require(ShutterTimeInput.denominator(input, locale: Locale(identifier: "en_US"))) - 50) < 1e-10)
        }
        #expect(ShutterTimeInput.denominator("0,02 s", locale: Locale(identifier: "fr_FR")) == 50)
        for invalid in ["", "0", "-50", "1/0", "0/50", "1/", "1/50/2", "20 m", "0. s", "1/50.", "nan", "inf", "1e-320 ms"] {
            #expect(ShutterTimeInput.denominator(invalid, locale: Locale(identifier: "en_US")) == nil)
        }
        // Fractional FPS comes from the exact preset, never the short chip label.
        var settings = ShutterSettings.default
        settings.direction = .timeToAngle
        settings.sensorFps = ShutterFramePreset.fractional24.fps
        settings.shutterDenominator = try #require(ShutterTimeInput.denominator("20 ms"))
        let result = CalculatorEngine(catalog: .bundled).calculateShutter(settings: settings)
        #expect(abs(try #require(result.exposure).angle - 172.62737262737264) < 1e-10)
        #expect(AppText.shutterSummary(settings: settings, calculation: result).contains("24000/1001"))
        #expect(!DisplayFormat.shutterFrameRate(23.976).contains("1001"))
    }

    @Test func overLimitKeepsTargetAndSeparatelyExplainsAchievableExposure() throws {
        var settings = ShutterSettings.default
        settings.mode = .matching
        settings.sensorFps = 60
        let engine = CalculatorEngine(catalog: .bundled)
        let result = engine.calculateShutter(settings: settings)
        #expect(result.status == .exceedsMaximum)
        #expect(try #require(result.exposure).angle == 450)
        let alternative = try #require(result.maximumExposure)
        #expect(alternative.angle == 360)
        #expect(abs(alternative.shutterDenominator - 60) < 1e-10)
        #expect(abs(try #require(result.maximumExposureDifferenceStops) - log2(0.8)) < 1e-10)
        let summary = AppText.shutterSummary(settings: settings, calculation: result)
        #expect(summary.contains("450°") && summary.contains("360°") && summary.contains("1/60 s"))
        #expect(summary.contains(AppText.shutterOverLimit(360)))
        settings.maxAngle = 180
        let limited = engine.calculateShutter(settings: settings)
        #expect(try #require(limited.maximumExposure).shutterDenominator == 120)
        #expect(try #require(limited.exposure).angle == 450)
        settings.match = .angle
        #expect(engine.calculateShutter(settings: settings).maximumExposure == nil)
    }

    @Test func launchMemoryPreservesValidValuesThroughDraftsModesImportResetAndUndo() throws {
        let suite = "FFFilm.DITShutter.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CalculatorStore(defaults: defaults)
        store.setActiveView(.shutter)
        store.updateShutterSettings(ShutterFramePreset.fractional24.fps, at: \.sensorFps)
        store.updateShutterSettings(ShutterDirection.timeToAngle, at: \.direction)
        store.updateShutterSettings(50.0, at: \.shutterDenominator)
        let valid = store.shutterSettings
        store.updateShutterSettings(Double.nan, at: \.sensorFps)
        store.updateShutterSettings(ShutterMode.flicker, at: \.mode)
        store.updateShutterSettings("60,", at: \.displayRefreshRates)
        let restored = CalculatorStore(defaults: defaults)
        #expect(restored.shutterSettings.sensorFps == valid.sensorFps)
        #expect(restored.shutterSettings.direction == .timeToAngle)
        #expect(restored.shutterSettings.mode == .flicker)
        #expect(restored.shutterSettings.displayRefreshRates == "60, 120")
        #expect(store.shutterSettings.sensorFps.isNaN)
        // Existing windows keep their own editor state; only newly created stores restore memory.
        restored.updateShutterSettings(25.0, at: \.sensorFps)
        #expect(store.shutterSettings.sensorFps.isNaN)
        restored.selectSensorFps(48)
        restored.selectProjectFps(24)
        restored.importShutterFrameRates()
        #expect(CalculatorStore(defaults: defaults).shutterSettings.sensorFps == 48)
        restored.setActiveView(.shutter)
        let beforeReset = restored.shutterSettings
        restored.resetActiveView()
        #expect(CalculatorStore(defaults: defaults).shutterSettings == .default)
        restored.undoReset()
        #expect(CalculatorStore(defaults: defaults).shutterSettings == beforeReset)
        restored.updateShutterSettings(Double.nan, at: \.sensorFps)
        restored.resetActiveView()
        restored.undoReset()
        #expect(restored.shutterSettings.sensorFps.isNaN)
        #expect(CalculatorStore(defaults: defaults).shutterSettings.sensorFps == beforeReset.sensorFps)
    }

    @Test func corruptFutureAndOutOfRangeMemoryFallsBackWithoutChangingOtherPreferences() throws {
        let suite = "FFFilm.DITShutter.Invalid.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "unrelated-setting")
        defaults.set(Data("not-json".utf8), forKey: ShutterSettingsMemory.key)
        #expect(CalculatorStore(defaults: defaults).shutterSettings == .default)
        let data = try JSONEncoder().encode(ShutterSettingsMemory(settings: .default))
        var future = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        future["version"] = 2
        defaults.set(try JSONSerialization.data(withJSONObject: future), forKey: ShutterSettingsMemory.key)
        #expect(CalculatorStore(defaults: defaults).shutterSettings == .default)
        var invalid = ShutterSettings.default
        invalid.maxAngle = 720
        defaults.set(try JSONEncoder().encode(ShutterSettingsMemory(settings: invalid)), forKey: ShutterSettingsMemory.key)
        #expect(CalculatorStore(defaults: defaults).shutterSettings == .default)
        #expect(defaults.string(forKey: "unrelated-setting") == "keep")
    }
}

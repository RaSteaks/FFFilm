import Foundation
import Observation
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
    @Test("Multiple displays share complete refresh cycles and retain nearest-angle ranking")
    func displayCandidates() throws {
        var settings = ShutterSettings.default
        settings.mode = .flicker
        settings.light = .displays
        #expect(engine.calculateShutter(settings: settings).candidates.map(\.exposure.angle) == [144, 288])
        #expect(engine.calculateShutter(settings: settings).compromise == nil)
        settings.displayRefreshRates = "60, 120, 144"
        #expect(engine.calculateShutter(settings: settings).compromise != nil)
        settings.sensorFps = 12
        #expect(try #require(engine.calculateShutter(settings: settings).exposure).angle == 360)
        settings.displayRefreshRates = "50, 60"
        settings.sensorFps = 24
        #expect(engine.calculateShutter(settings: settings).compromise != nil)
        settings.sensorFps = 10
        #expect(try #require(engine.calculateShutter(settings: settings).exposure).angle == 360)
        settings.maxAngle = 359.999
        #expect(engine.calculateShutter(settings: settings).compromise != nil)
    }

    @MainActor
    @Test("Decimal display rates are exact, order-independent and never merged by rounding")
    func decimalDisplays() throws {
        var settings = ShutterSettings.default
        settings.mode = .flicker
        settings.light = .displays
        settings.displayRefreshRates = "59.94，119.88"
        let result = engine.calculateShutter(settings: settings)
        #expect(abs(try #require(result.exposure).shutterDenominator - 59.94) < 1e-10)
        settings.displayRefreshRates = "119.880, 59.940, 59.94"
        #expect(engine.calculateShutter(settings: settings) == result)
        settings.displayRefreshRates = "59.94, 60"
        #expect(engine.calculateShutter(settings: settings).compromise != nil)
        settings.displayRefreshRates = "1000000, 1000000"
        #expect(engine.calculateShutter(settings: settings).candidates.count == 3)
    }

    @MainActor
    @Test("Malformed refresh lists invalidate active results and are ignored when inactive")
    func invalidDisplays() {
        for text in ["", "60", "60,", "60,,120", "0,60", "-60,120", "nan,120", "inf,60",
                     "60.0001,120", "1000000.001,60", "60.,120", "1e2,60",
                     "9999999999999999999999,60", Array(repeating: "60", count: 17).joined(separator: ",")] {
            var settings = ShutterSettings.default
            settings.light = .displays
            settings.displayRefreshRates = text
            #expect(engine.calculateShutter(settings: settings).status == .valid)
            settings.mode = .flicker
            let result = engine.calculateShutter(settings: settings)
            #expect(result.status == .invalidDisplays)
            #expect(result.exposure == nil)
        }
    }

    @MainActor
    @Test("Display matching checks every device without changing target exposure")
    func displayMatching() {
        var settings = ShutterSettings.default
        settings.mode = .matching
        settings.light = .displays
        settings.checksFlicker = true
        settings.targetAngle = 144
        #expect(engine.calculateShutter(settings: settings).matchesLightCycles == true)
        settings.targetAngle = 180
        let result = engine.calculateShutter(settings: settings)
        #expect(result.matchesLightCycles == false)
        #expect(result.exposure?.angle == 180)
        // Compare bounded GCD candidates to exhaustive enumeration of the first display's periods.
        for rates in [[60, 120], [50, 60], [120, 144], [48, 72, 120]] {
            settings.mode = .flicker
            settings.sensorFps = 1
            settings.displayRefreshRates = rates.map(String.init).joined(separator: ",")
            let base = rates[0]
            let cycles = (1...base).filter { n in rates.allSatisfy { (n * $0) % base == 0 } }
            let angles: [Double] = cycles.map { Double($0) / Double(base) * 360.0 }
            let expected = angles.sorted { left, right in
                let lhs = abs(left - 180), rhs = abs(right - 180)
                return abs(lhs - rhs) < 1e-9 ? left < right : lhs < rhs
            }
            let actual = engine.calculateShutter(settings: settings).candidates.map(\.exposure.angle)
            #expect(actual.count == min(3, expected.count))
            for (a, b) in zip(actual, expected.prefix(3)) { #expect(abs(a - b) < 1e-9) }
        }
    }

    @MainActor
    @Test("Compromise minimizes the worst positive-cycle deviation, not a near-zero exposure")
    func compromiseOptimum() throws {
        var settings = ShutterSettings.default
        settings.mode = .flicker
        settings.light = .displays
        settings.displayRefreshRates = "50, 60"
        let result = engine.calculateShutter(settings: settings)
        let compromise = try #require(result.compromise)
        #expect(result.status == .valid)
        #expect(result.candidates.isEmpty)
        #expect(abs(compromise.exposure.shutterDenominator - 55) < 1e-9)
        #expect(abs(compromise.worstError - 1.0 / 11) < 1e-10)
        #expect(!compromise.approximateSearch)
        #expect(result.exposure == compromise.exposure)
        settings.displayRefreshRates = "60, 50, 50"
        #expect(engine.calculateShutter(settings: settings).compromise == compromise)
        // Symmetric minima around the 0.1 s common period have the same worst error.
        // The preferred angle must choose between them without changing the minimax priority.
        settings.sensorFps = 10.5
        settings.preferredAngle = 60
        let early = try #require(engine.calculateShutter(settings: settings).compromise)
        settings.preferredAngle = 300
        let late = try #require(engine.calculateShutter(settings: settings).compromise)
        #expect(abs(early.exposure.exposureSeconds - 1.0 / 55) < 1e-10)
        #expect(abs(late.exposure.exposureSeconds - 9.0 / 110) < 1e-10)
        #expect(abs(early.worstError - late.worstError) < 1e-10)
        settings.maxAngle = 1
        let limited = try #require(engine.calculateShutter(settings: settings).compromise)
        #expect(abs(limited.exposure.angle - 1) < 1e-10)
        #expect(limited.displays.allSatisfy { $0.nearestCycles == 1 })
        settings.maxAngle = .leastNonzeroMagnitude
        #expect(engine.calculateShutter(settings: settings).status == .numericalLimit)
    }

    @MainActor
    @Test("Common compromise beats an independent dense search across the permitted exposure range")
    func compromiseOracle() throws {
        for rates in [[50.0, 60], [60, 144], [50, 60, 144], [59.94, 60], [25, 144, 240]] {
            for fps in [24.0, 60, 240] {
                var settings = ShutterSettings.default
                settings.mode = .flicker
                settings.light = .displays
                settings.sensorFps = fps
                settings.displayRefreshRates = rates.map(String.init(describing:)).joined(separator: ",")
                let compromise = try #require(engine.calculateShutter(settings: settings).compromise)
                // This oracle samples the original objective rather than reproducing the interval solver.
                var sampledBest = Double.infinity
                for step in 1...10_000 {
                    let time = Double(step) / (10_000 * fps)
                    let worst = rates.map { hz in abs(time * hz - max(1, (time * hz).rounded())) }.max()!
                    sampledBest = min(sampledBest, worst)
                }
                #expect(compromise.worstError <= sampledBest + 1e-9)
                #expect(compromise.exposure.angle <= settings.maxAngle + 1e-9)
                #expect(!compromise.approximateSearch)
            }
        }
    }

    @MainActor
    @Test("Analytical compromises match an independent piecewise-linear vertex oracle")
    func analyticalCompromiseOracle() throws {
        let cases: [[Double]] = [
            [59.94, 60], [0.001, 144], [50, 60, 144],
            [24, 25, 30, 48, 50, 59.94, 60, 72, 90, 100, 120, 144, 165, 200, 240, 360]
        ]
        for rates in cases {
            for maximum in [1.0, 143.9, 360] {
                var settings = ShutterSettings.default
                settings.mode = .flicker
                settings.light = .displays
                settings.displayRefreshRates = rates.map(String.init(describing:)).joined(separator: ",")
                settings.maxAngle = maximum
                let limit = maximum / (360 * settings.sensorFps)
                var boundaries = [0.0, limit]
                for hz in rates {
                    var n = 1.0
                    while (n + 0.5) / hz < limit {
                        boundaries.append((n + 0.5) / hz)
                        n += 1
                    }
                }
                boundaries.sort()
                var oracleError = Double.infinity
                // A convex piecewise-linear minimum is at an endpoint or a crossing of
                // two signed error lines. Enumerate vertices without the production formula.
                for (lower, upper) in zip(boundaries, boundaries.dropFirst()) {
                    let counts = rates.map { max(1, (($0 * (lower + upper)) / 2).rounded()) }
                    var times = [lower, upper]
                    for i in rates.indices {
                        for j in rates.indices {
                            let crossing = (counts[i] + counts[j]) / (rates[i] + rates[j])
                            if crossing >= lower, crossing <= upper { times.append(crossing) }
                        }
                    }
                    for time in times where time > 0 {
                        let error = rates.map { abs($0 * time - max(1, ($0 * time).rounded())) }.max()!
                        oracleError = min(oracleError, error)
                    }
                }
                let result = try #require(engine.calculateShutter(settings: settings).compromise)
                #expect(abs(result.worstError - oracleError) < 1e-10)
                #expect(result.exposure.exposureSeconds > 0 && result.exposure.exposureSeconds <= limit)
                #expect(!result.approximateSearch)
            }
        }
    }

    @MainActor
    @Test("Cached shutter results track edits, invalid inputs, import, reset and undo")
    func cachedShutterResults() async throws {
        let store = CalculatorStore()
        store.activeView = .shutter
        store.shutterSettings.mode = .flicker
        store.shutterSettings.light = .displays
        store.shutterSettings.displayRefreshRates = "50, 60"
        let original = store.shutterCalculation
        #expect(store.shutterCalculation == original)

        // Register on a warm cache: a hit must retain input observation, while unrelated
        // recording state changes and additional reads must not invalidate the observer.
        await confirmation("Cached result observes shutter inputs", expectedCount: 1) { changed in
            withObservationTracking {
                _ = store.shutterCalculation
            } onChange: {
                changed()
            }
            store.settings.sensorFps = 60
            #expect(store.shutterCalculation == original)
            store.shutterSettings.maxAngle = 90
        }
        #expect(store.shutterCalculation == engine.calculateShutter(settings: store.shutterSettings))
        #expect(store.shutterCalculation != original)
        store.shutterSettings.displayRefreshRates = "60,"
        #expect(store.shutterCalculation.status == .invalidDisplays)
        #expect(store.shutterCalculation.exposure == nil)
        store.shutterSettings.displayRefreshRates = "59.94, 60"
        store.importShutterFrameRates()
        let imported = store.shutterCalculation
        #expect(imported == engine.calculateShutter(settings: store.shutterSettings))
        store.resetActiveView()
        #expect(store.shutterCalculation == engine.calculateShutter(settings: .default))
        store.undoReset()
        #expect(store.shutterCalculation == imported)
        store.shutterSettings.mode = .matching
        store.shutterSettings.checksFlicker = true
        #expect(store.shutterCalculation == engine.calculateShutter(settings: store.shutterSettings))
    }

    @MainActor
    @Test("Extreme inputs use bounded search, and matching preserves its original exposure and copy qualification")
    func compromiseMatchingAndLimits() throws {
        var settings = ShutterSettings.default
        settings.mode = .matching
        settings.light = .displays
        settings.displayRefreshRates = "50, 60"
        settings.checksFlicker = true
        let result = engine.calculateShutter(settings: settings)
        #expect(result.exposure?.angle == 180)
        #expect(result.matchesLightCycles == false)
        let compromise = try #require(result.compromise)
        #expect(abs(compromise.exposure.angle - 8640.0 / 55) < 1e-9)
        #expect(AppText.shutterSummary(settings: settings, calculation: result).contains(DisplayFormat.shutterNumber(compromise.exposure.angle)))
        settings.sensorFps = 60
        #expect(engine.calculateShutter(settings: settings).status == .exceedsMaximum)
        settings.checksFlicker = false
        #expect(engine.calculateShutter(settings: settings).compromise == nil)
        settings.mode = .flicker
        settings.displayRefreshRates = "1000000, 999999.999"
        let high = try #require(engine.calculateShutter(settings: settings).compromise)
        #expect(high.approximateSearch)
        #expect(high.worstError.isFinite)
        #expect(high.exposure.angle > 0 && high.exposure.angle <= settings.maxAngle + 1e-9)
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
        store.shutterSettings.displayRefreshRates = "50, 100, 150"
        store.importShutterFrameRates()
        #expect(store.shutterSettings.sensorFps == 47.952)
        #expect(store.shutterSettings.projectFps == 23.976)
        #expect(store.shutterSettings.targetAngle == 172.8)
        #expect(store.shutterSettings.light == .mains60)
        #expect(store.shutterSettings.displayRefreshRates == "50, 100, 150")
        store.shutterSettings.sensorFps = 120
        #expect(store.settings == rateBefore)
        store.activeView = .shutter
        store.resetActiveView()
        #expect(store.shutterSettings == .default)
        #expect(store.settings == rateBefore)
        #expect(store.shutterInputRevision == 1)
    }
}

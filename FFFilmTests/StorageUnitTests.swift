import Foundation
import Testing
@testable import FFFilm

struct StorageUnitTests {
    /// The same bytes must use a full 1024³ divisor, not just a GB/MB ratio.
    @Test func conversionAndThresholds() {
        #expect(StorageUnit.decimal.converted(decimalGB: 1000) == 1000)
        #expect(abs(StorageUnit.binary.converted(decimalGB: 1000) - 931.3225746154785) < 0.000001)
        #expect(DisplayFormat.compactStorage(1000).hasSuffix(" TB"))
        #expect(DisplayFormat.compactStorage(1000, unit: .binary).hasSuffix(" GiB"))
        #expect(DisplayFormat.compactStorage(1099.511627776, unit: .binary).hasSuffix(" TiB"))
    }

    @Test @MainActor func preferenceSurvivesCalculatorReset() throws {
        let suite = "StorageUnitTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(StorageUnit.binary.rawValue, forKey: StorageUnit.preferenceKey)
        let store = CalculatorStore(defaults: defaults)
        let before = store.calculation
        store.resetActiveView()
        #expect(defaults.string(forKey: StorageUnit.preferenceKey) == "binary")
        #expect(store.calculation.captureRuntimeHours == before.captureRuntimeHours)
        #expect(store.calculation.sensorMbps == before.sensorMbps)
        #expect(store.calculation.dayUsagePercent == before.dayUsagePercent)
    }
}

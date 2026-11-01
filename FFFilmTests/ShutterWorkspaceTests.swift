import Foundation
import Testing
@testable import FFFilm

@MainActor
struct ShutterWorkspaceTests {
    private func isolated(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "FFFilm.ShutterWorkspace.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func rigsRetainIndependentSettingsAndPendingDrafts() throws {
        try isolated { defaults in
            let store = CalculatorStore(defaults: defaults)
            store.updateShutterSettings(48.0, at: \.sensorFps)
            store.configureShutterRig(cameraLabel: "A camera mode")
            store.selectShutterRig(.b)
            #expect(store.shutterSettings.sensorFps == 24)
            store.updateShutterSettings(60.0, at: \.sensorFps)
            store.updateShutterSettings(ShutterMode.flicker, at: \.mode)
            store.selectShutterRig(.a)
            #expect(store.shutterSettings.sensorFps == 48)
            #expect(store.shutterWorkspace.active.cameraLabel == "A camera mode")
            store.updateShutterSettings(Double.nan, at: \.sensorFps)
            store.selectShutterRig(.b)
            #expect(store.shutterSettings.sensorFps == 60 && store.shutterSettings.mode == .flicker)
            store.selectShutterRig(.a)
            #expect(store.shutterSettings.sensorFps.isNaN)
            let reopened = CalculatorStore(defaults: defaults)
            #expect(reopened.shutterWorkspace.selectedRig == .a)
            #expect(reopened.shutterSettings.sensorFps == 48)
            reopened.selectShutterRig(.b)
            #expect(reopened.shutterSettings.sensorFps == 60)
        }
    }

    @Test func historyRecordsCommitBoundariesDeduplicatesAndBoundsStorage() throws {
        try isolated { defaults in
            let store = CalculatorStore(defaults: defaults)
            for fps in [24.0, 25, 48] { store.updateShutterSettings(fps, at: \.sensorFps) }
            #expect(store.shutterWorkspace.recent.isEmpty)
            store.rememberShutterResult(); store.rememberShutterResult()
            #expect(store.shutterWorkspace.recent.count == 1)
            for fps in 50...70 {
                store.updateShutterSettings(Double(fps), at: \.sensorFps)
                store.rememberShutterResult()
            }
            #expect(store.shutterWorkspace.recent.count == ShutterWorkspace.recentLimit)
            #expect(store.shutterWorkspace.recent.first?.settings.sensorFps == 70)
            store.updateShutterSettings(Double.nan, at: \.sensorFps)
            store.rememberShutterResult()
            #expect(store.shutterWorkspace.recent.first?.settings.sensorFps == 70)
            #expect(CalculatorStore(defaults: defaults).shutterWorkspace.recent.count == ShutterWorkspace.recentLimit)
        }
    }

    @Test func fieldChecksRequireConditionsAndRemainAttachedToImmutableSnapshots() throws {
        try isolated { defaults in
            let store = CalculatorStore(defaults: defaults)
            var record = try #require(store.currentShutterRecord())
            record.fieldChecked = true
            store.shutterWorkspace.save(record)
            #expect(store.shutterWorkspace.saved.isEmpty)
            record.conditions = "Synthetic fixture; no physical lighting test"
            record.title = "A setup"
            store.shutterWorkspace.save(record)
            store.updateShutterSettings(60.0, at: \.sensorFps)
            let saved = try #require(CalculatorStore(defaults: defaults).shutterWorkspace.saved.first)
            #expect(saved.settings.sensorFps == 24 && saved.fieldChecked)
            #expect(saved.conditions == record.conditions && saved.date == record.date)
            #expect(store.summary(for: saved).contains(record.conditions))
            #expect(try #require(store.currentShutterRecord()).fieldChecked == false)
        }
    }

    @Test func restoringTargetsTheSourceRigAndReplacesOnlyItsDraft() throws {
        try isolated { defaults in
            let store = CalculatorStore(defaults: defaults)
            store.updateShutterSettings(ShutterFramePreset.fractional24.fps, at: \.sensorFps)
            let record = try #require(store.currentShutterRecord())
            store.updateShutterSettings(Double.nan, at: \.sensorFps)
            store.selectShutterRig(.b)
            store.updateShutterSettings(50.0, at: \.sensorFps)
            store.restoreShutterRecord(record)
            #expect(store.shutterWorkspace.selectedRig == .a)
            #expect(store.shutterSettings == record.settings)
            #expect(store.shutterInputRevision == 1)
            store.selectShutterRig(.b)
            #expect(store.shutterSettings.sensorFps == 50)
            store.selectShutterRig(.a)
            #expect(store.shutterSettings.sensorFps == ShutterFramePreset.fractional24.fps)
        }
    }

    @Test func windowsMergeOtherRigsAndLibraryChangesWithoutRevivingRemovedItems() throws {
        try isolated { defaults in
            let first = CalculatorStore(defaults: defaults), second = CalculatorStore(defaults: defaults)
            first.updateShutterSettings(48.0, at: \.sensorFps)
            let a = try #require(first.currentShutterRecord())
            first.shutterWorkspace.save(a)
            second.selectShutterRig(.b)
            second.updateShutterSettings(60.0, at: \.sensorFps)
            let b = try #require(second.currentShutterRecord())
            second.shutterWorkspace.save(b)
            let reopened = CalculatorStore(defaults: defaults)
            reopened.selectShutterRig(.a)
            #expect(reopened.shutterSettings.sensorFps == 48)
            reopened.selectShutterRig(.b)
            #expect(reopened.shutterSettings.sensorFps == 60)
            #expect(reopened.shutterWorkspace.saved.count == 2)
            first.shutterWorkspace.deleteSaved(a.id)
            second.shutterWorkspace.remember(b)
            let final = CalculatorStore(defaults: defaults)
            #expect(final.shutterWorkspace.saved.map(\.id) == [b.id])
        }
    }

    @Test func migrationAndMalformedWorkspaceUseValidatedLegacySettings() throws {
        try isolated { defaults in
            var settings = ShutterSettings.default; settings.sensorFps = 47.952
            defaults.set(try JSONEncoder().encode(ShutterSettingsMemory(settings: settings)), forKey: ShutterSettingsMemory.key)
            defaults.set(Data("invalid".utf8), forKey: ShutterWorkspace.rigsKey)
            defaults.set(Data("invalid".utf8), forKey: ShutterWorkspace.libraryKey)
            let store = CalculatorStore(defaults: defaults)
            #expect(store.shutterSettings.sensorFps == 47.952)
            #expect(store.shutterWorkspace.saved.isEmpty && store.shutterWorkspace.recent.isEmpty)
            store.selectShutterRig(.c)
            #expect(store.shutterSettings == .default)
        }
    }

    @Test func candidatesAreExplicitCurrentAndCannotReplaceMatchingTargets() throws {
        try isolated { defaults in
            let store = CalculatorStore(defaults: defaults)
            store.updateShutterSettings(ShutterMode.flicker, at: \.mode)
            let candidate = try #require(store.shutterCalculation.candidates.first(where: { $0.cycles == 1 }))
            #expect(store.readableShutterSummary().contains("180°")) // Include the target as well as the 172.8° answer.
            #expect(abs(try #require(candidate.differenceStops(relativeTo: 180)) - log2(86.4 / 180)) < 1e-10)
            #expect(candidate.differenceStops(relativeTo: 0) == nil)
            store.chooseShutterCandidate(candidate)
            #expect(store.shutterSettings.preferredAngle == 86.4)
            #expect(store.shutterCalculation.exposure?.angle == 86.4)
            #expect(store.shutterWorkspace.recent.first?.fieldChecked == false)
            store.updateShutterSettings(48.0, at: \.sensorFps)
            let before = store.shutterSettings
            store.chooseShutterCandidate(candidate)
            #expect(store.shutterSettings == before)
            store.updateShutterSettings(ShutterMode.matching, at: \.mode)
            let matching = store.shutterSettings
            store.chooseShutterCandidate(candidate)
            #expect(store.shutterSettings == matching)
        }
    }
}

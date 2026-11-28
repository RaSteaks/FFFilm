import Foundation
import Observation
import Testing
@testable import FFFilm

@MainActor
struct CalculatorStoreTests {
    @Test("Camera memory restores valid format settings without replacing the current budget")
    func cameraMemoryRestoresFormatOnly() throws {
        let suite = "FFFilm.CameraMemory.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CalculatorStore(defaults: defaults)
        let target = try #require(store.catalog.cameras.first(where: { !$0.isStandaloneProRes && $0.id != store.settings.cameraId }))
        store.selectCamera(target.id)
        let mode = try #require(target.modes.last)
        store.selectMode(mode.id)
        let resolution = try #require(mode.resolutions.last)
        store.selectResolution(resolution.id)
        if let codec = store.availableCodecs.last { store.selectCodec(codec.id) }
        if let fps = store.availableSensorFrameRates.last { store.selectSensorFps(fps) }
        store.setSensorOverdrive(target.supportsSensorOverdrive == true)
        store.selectMedia("1tb")
        store.setShootHours(3.5)
        let remembered = store.settings

        store.selectCamera("alexa35")
        #expect(store.settings.mediaId == "1tb")
        #expect(store.settings.shootHours == 3.5)
        store.selectCamera(target.id)
        #expect(store.settings.modeId == remembered.modeId)
        #expect(store.settings.resolutionId == remembered.resolutionId)
        #expect(store.settings.codecId == remembered.codecId)
        #expect(store.settings.sensorFps == remembered.sensorFps)
        #expect(store.settings.sensorOverdrive == remembered.sensorOverdrive)
        #expect(store.settings.mediaId == "1tb")
        #expect(store.settings.shootHours == 3.5)
    }

    @Test("Missing, corrupt and future camera memory payloads fall back safely")
    func invalidCameraMemoryFallsBack() throws {
        let suite = "FFilm.CameraMemory.Invalid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not-json".utf8), forKey: "fffilm.camera-settings-memory")
        let corrupt = CalculatorStore(defaults: defaults)
        #expect(corrupt.settings.cameraId == "alexa35")

        let payload = CameraSettingsMemoryPayload(version: CameraSettingsMemoryPayload.currentVersion + 1,
                                                  memories: ["alexa35": CameraSettingsMemory(settings: .default)])
        defaults.set(try JSONEncoder().encode(payload), forKey: "fffilm.camera-settings-memory")
        let future = CalculatorStore(defaults: defaults)
        #expect(future.settings == CalculatorEngine(catalog: future.catalog).normalized(.default))
    }

    @Test("Two stores keep independent window state while sharing the latest camera memory")
    func windowsDoNotOverwriteActiveState() throws {
        let suite = "FFFilm.CameraMemory.Windows.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = CalculatorStore(defaults: defaults)
        let second = CalculatorStore(defaults: defaults)
        first.selectCamera("venice2")
        let rememberedFPS = try #require(first.availableSensorFrameRates.last)
        first.selectSensorFps(rememberedFPS)
        let firstCamera = first.settings
        // Switching a second, already-open window must not write its stale
        // memory payload over the first window's Venice format edit.
        second.selectCamera("burano")
        let reopened = CalculatorStore(defaults: defaults)
        reopened.selectCamera("venice2")
        #expect(reopened.settings.sensorFps == rememberedFPS)

        second.selectCamera("venice2")
        second.setShootHours(2.25)
        #expect(first.settings == firstCamera)
        #expect(second.settings.shootHours == 2.25)
        #expect(second.settings.sensorFps == rememberedFPS)
        first.selectCamera("venice2")
        #expect(first.settings.shootHours == firstCamera.shootHours)
    }

    @Test("A shutter edit removes reset undo before it can replace the new input")
    func shutterEditInvalidatesResetUndo() throws {
        // Shutter preferences now persist; keep this regression independent of other tests.
        let suite = "FFFilm.ShutterUndo.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CalculatorStore(defaults: defaults)
        store.setActiveView(.shutter)
        store.updateShutterSettings(172.8, at: \.angle)
        store.resetActiveView()
        #expect(store.resetUndoAvailable)
        store.updateShutterSettings(90.0, at: \.angle)
        #expect(!store.resetUndoAvailable)
        #expect(store.feedbackMessage == nil)
        store.undoReset()
        #expect(store.shutterSettings.angle == 90)
    }

    @Test("Reset preserves preferences and camera memory while undo stays observable")
    func resetUndo() async throws {
        let suite = "FFFilm.ResetUndo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(StorageUnit.binary.rawValue, forKey: StorageUnit.preferenceKey)
        let store = CalculatorStore(defaults: defaults)
        store.selectMedia("1tb")
        store.setShootHours(4.5)
        let before = store.settings
        store.addCurrentToSummary()
        await confirmation("Reset enables undo") { changed in
            withObservationTracking { _ = store.resetUndoAvailable } onChange: { changed() }
            store.resetActiveView()
        }
        #expect(defaults.string(forKey: StorageUnit.preferenceKey) == StorageUnit.binary.rawValue)
        #expect(store.resetUndoAvailable)
        #expect(store.settings == CalculatorEngine(catalog: store.catalog).normalized(.default))
        #expect(store.summary.entries.count == 1)
        await confirmation("Undo consumes the snapshot") { changed in
            withObservationTracking { _ = store.resetUndoAvailable } onChange: { changed() }
            store.undoReset()
        }
        #expect(store.settings == before)
        #expect(!store.resetUndoAvailable)

        // Media and planned hours stay window-local by design, so only the
        // per-camera format memory survives the relaunch.
        let relaunched = CalculatorStore(defaults: defaults)
        relaunched.selectCamera(before.cameraId)
        #expect(relaunched.settings.cameraId == before.cameraId)
        #expect(relaunched.settings.modeId == before.modeId)
        #expect(relaunched.settings.resolutionId == before.resolutionId)
        #expect(relaunched.settings.codecId == before.codecId)
        #expect(relaunched.settings.sensorFps == before.sensorFps)
        #expect(relaunched.settings.sensorOverdrive == before.sensorOverdrive)

        store.resetActiveView()
        await confirmation("A new edit invalidates undo") { changed in
            withObservationTracking { _ = store.resetUndoAvailable } onChange: { changed() }
            store.setShootHours(2)
        }
        #expect(!store.resetUndoAvailable)
        store.undoReset()
        #expect(store.settings.shootHours == 2)
    }

    @Test("Reset undo restores only the camera memory it replaced, preserving another window's edits")
    func resetUndoMergesCameraMemory() throws {
        let suite = "FFFilm.ResetMemory.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CalculatorStore(defaults: defaults)
        let defaultID = first.settings.cameraId
        first.selectSensorFps(48)
        let defaultMemory = first.settings
        first.selectCamera("venice2")
        first.setShootHours(2.5)
        let beforeReset = first.settings
        first.resetActiveView()

        let second = CalculatorStore(defaults: defaults)
        second.selectCamera("venice2")
        second.selectSensorFps(60)
        let otherWindowMemory = second.settings
        first.undoReset()
        #expect(first.settings == beforeReset)

        let reopened = CalculatorStore(defaults: defaults)
        #expect(reopened.settings.cameraId == defaultID)
        #expect(reopened.settings.sensorFps == defaultMemory.sensorFps)
        reopened.selectCamera("venice2")
        #expect(reopened.settings.sensorFps == otherWindowMemory.sensorFps)
        #expect(second.settings == otherWindowMemory)
    }

    @Test("Summary keeps duplicate setups, merges window edits and totals every entry")
    func summaryPersistsAndTotals() throws {
        let suite = "FFFilm.Summary.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CalculatorStore(defaults: defaults)
        store.addCurrentToSummary()
        store.addCurrentToSummary()
        store.setShootHours(2)
        store.addCurrentToSummary()
        #expect(store.summary.entries.count == 3)
        #expect(store.summaryTotalGb == store.summaryItems.reduce(0) { $0 + $1.calculation.dayTotalGb })
        #expect(store.summaryItems[2].calculation.dayTotalGb == store.calculation.dayTotalGb)

        // Another window reads the same list and follows later additions without reopening it;
        // its removal survives this window's next addition.
        let other = CalculatorStore(defaults: defaults)
        #expect(other.summary.entries.map(\.id) == store.summary.entries.map(\.id))
        store.addCurrentToSummary()
        #expect(other.summary.entries.count == 4)
        #expect(store.summaryAdditions == 4)
        store.removeSummaryEntry(id: store.summary.entries[3].id)
        #expect(other.summary.entries.count == 3)
        other.removeSummaryEntry(id: other.summary.entries[0].id)
        store.addCurrentToSummary()
        #expect(store.summary.entries.count == 3)

        let firstDay = store.summary.activeDay
        let link = try #require(URL(string: store.configurationText))
        #expect(store.configuration(from: link) == store.settings)
        #expect(store.configuration(from: URL(string: store.configurationText + "&hours=2")!) == nil)
        store.summary.newDay(project: "Night unit", date: .now)
        #expect(other.summary.entries.isEmpty)
        store.recordingTask = .runtime
        store.recordingRig = "B"
        store.addCurrentToSummary()
        let card = try #require(store.summary.entries.first)
        #expect(card.rig == "B" && card.cardAllocation == true)
        #expect(store.summaryTotalGb == store.calculation.media.capacityGb)
        #expect(card.settings.shootHours == store.calculation.captureRuntimeHours)
        store.summary.edit(card.id, rig: "C", hours: 1)
        #expect(other.summary.entries.first?.rig == "C" && store.summaryTotalGb == store.calculation.media.capacityGb)
        store.summary.selectDay(firstDay)
        #expect(store.summary.entries.count == 3 && store.summary.activeDay.archivedUnit != nil)
        other.summary.renameDay("Second unit")
        other.addCurrentToSummary()
        #expect(store.summary.activeDay.id == firstDay.id)
        #expect(store.summary.entries.count == 3 && other.summary.entries.count == 2)
        #expect(store.readableSummary(storageUnit: .decimal).hasPrefix(firstDay.title))
        let archivedID = try #require(store.summary.entries.first?.id)
        store.removeSummaryEntry(id: archivedID)
        #expect(store.summary.entries.count == 3 && other.summary.entries.count == 2)
        store.summary.refresh(returnToOpenDay: true)
        #expect(store.summary.activeDay.project == "Second unit")
        store.clearSummary()
        #expect(CalculatorStore(defaults: defaults).summary.entries.isEmpty)
    }

    @Test("Legacy entries migrate by shooting date and retain unavailable original IDs")
    func legacySummaryHandoff() throws {
        struct Legacy: Encodable { let version = 1; let entries: [SummaryEntry] }
        let namespace = "FFFilm.LegacySummary.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        var retired = CaptureSettings.default
        retired.cameraId = "retired-camera"
        let input = Legacy(entries: [
            SummaryEntry(id: UUID(), settings: .default, added: yesterday),
            SummaryEntry(id: UUID(), settings: retired, added: yesterday),
            SummaryEntry(id: UUID(), settings: retired, added: .now)
        ])
        defaults.set(try JSONEncoder().encode(input), forKey: RecordingSummary.key)
        let store = CalculatorStore(defaults: defaults)
        #expect(store.summary.entries.count == 1 && store.summary.entries[0].snapshot == nil)
        let unavailable = RecordingEstimate.summaryAnswer(defaults: defaults, catalog: store.catalog)
        #expect(unavailable.contains(String(localized: "intent.summary.unavailable")))
        #expect(!unavailable.contains(DisplayFormat.compactStorage(0)))
        store.addCurrentToSummary()
        let partial = RecordingEstimate.summaryAnswer(defaults: defaults, catalog: store.catalog)
        let subtotal = DisplayFormat.compactStorage(store.calculation.dayTotalGb)
        let partialAnswer = String(localized: "intent.summary.partial",
            defaultValue: "Estimates for \(1) of \(2) setups give a subtotal of \(subtotal).")
        #expect(partial.contains(partialAnswer))
        let archive = try #require(store.summary.days.first { $0.archivedUnit != nil })
        store.summary.selectDay(archive)
        #expect(store.summary.entries.count == 2)
        #expect(store.summaryItems.first?.calculation.reconstructed == true)
        #expect(store.readableSummary(storageUnit: .decimal).contains("retired-camera"))
        #expect(CalculatorStore(defaults: defaults).summary.entries.count == 2)
    }

    @Test("Dial detents recalculate live but save camera and shutter memory once they settle")
    func dialDetentsPersistOnSettle() throws {
        let suite = "FFFilm.DialPersistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CalculatorStore(defaults: defaults)
        let target = try #require(store.availableSensorFrameRates.first { $0 != store.settings.sensorFps })
        store.selectSensorFps(target, persisting: false)
        #expect(store.settings.sensorFps == target)
        #expect(CalculatorStore(defaults: defaults).settings.sensorFps != target)
        store.persistFormatSettings()
        #expect(CalculatorStore(defaults: defaults).settings.sensorFps == target)

        store.updateShutterSettings(50, at: \.sensorFps, persisting: false)
        #expect(store.shutterCalculation.exposure != nil)
        #expect(CalculatorStore(defaults: defaults).shutterSettings.sensorFps != 50)
        store.persistShutterChanges()
        #expect(CalculatorStore(defaults: defaults).shutterSettings.sensorFps == 50)
    }

    @Test("Siri answers use the camera's remembered format and the shared summary")
    func recordingEstimateAnswers() throws {
        let suite = "FFFilm.Intents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CalculatorStore(defaults: defaults)
        let target = try #require(store.catalog.cameras.first(where: { !$0.isStandaloneProRes && $0.id != store.settings.cameraId }))
        store.selectCamera(target.id)
        if let codec = store.availableCodecs.last { store.selectCodec(codec.id) }
        store.setShootHours(2)
        let expected = store.calculation

        let answer = RecordingEstimate.storageAnswer(cameraID: target.id, hours: 2, defaults: defaults, catalog: store.catalog)
        #expect(answer.contains(target.name))
        #expect(answer.contains(expected.codec.name))
        #expect(answer.contains("02:00:00"))
        #expect(answer.contains(DisplayFormat.compactStorage(expected.dayTotalGb)))
        for hours in [0.0, 25] {
            // Siri asks for a usable time instead of answering for none or more than a day.
            let invalid = RecordingEstimate.storageAnswer(cameraID: target.id, hours: hours, defaults: defaults, catalog: store.catalog)
            #expect(!invalid.contains(target.name))
        }

        #expect(RecordingEstimate.summaryAnswer(defaults: defaults, catalog: store.catalog) != answer)
        store.addCurrentToSummary()
        store.addCurrentToSummary()
        let summary = RecordingEstimate.summaryAnswer(defaults: defaults, catalog: store.catalog)
        #expect(summary.contains(DisplayFormat.compactStorage(expected.dayTotalGb * 2)))
    }

    @Test("Duration setters reject invalid values without creating a new result")
    func durationBounds() {
        let store = CalculatorStore()
        let original = store.settings.shootHours
        store.setShootHours(-1)
        store.setShootHours(24 + 1.0 / 3_600)
        store.setShootHours(.nan)
        #expect(store.settings.shootHours == original)
        store.setShootHours(6.75)
        #expect(store.settings.shootHours == 6.75)
        // The iOS duration wheel edits whole seconds, so one second and ten minutes are valid plans.
        store.setShootHours(1.0 / 3_600)
        #expect(store.settings.shootHours == 1.0 / 3_600)
        store.setShootHours(10.0 / 60)
        #expect(CalculatorEngine(catalog: store.catalog).normalized(store.settings).shootHours == 10.0 / 60)
        // 00:00:00 on the wheel is a valid plan that needs no storage.
        store.setShootHours(0)
        #expect(store.settings.shootHours == 0)
        #expect(store.calculation.dayTotalGb == 0)
    }

    @Test("Planning tasks preserve inputs and copy only the active answer")
    func independentRecordingTasks() {
        let store = CalculatorStore()
        store.setShootHours(3.5)
        store.selectMedia("1tb")
        let settings = store.settings
        let capacity = store.calculation.dayTotalGb
        let runtime = store.calculation.captureRuntimeHours
        store.recordingTask = .runtime
        #expect(store.settings == settings)
        let summary = store.readableRecordingSummary(storageUnit: .decimal)
        #expect(summary.contains(DisplayFormat.duration(runtime)))
        #expect(!summary.contains("03:30:00"))
        // Planned hours never affect available recording time; media never affects required storage.
        store.setShootHours(7)
        #expect(store.calculation.captureRuntimeHours == runtime)
        store.recordingTask = .capacity
        store.selectMedia("2tb")
        #expect(store.calculation.dayTotalGb == capacity * 2)
        let capacitySummary = store.readableRecordingSummary(storageUnit: .decimal)
        #expect(capacitySummary.contains("07:00:00"))
        #expect(capacitySummary.contains("GB/h") && capacitySummary.contains("Mb/s") && capacitySummary.contains("fps"))
        #expect(store.readableRecordingSummary(storageUnit: .binary).contains("GiB/h"))
        #expect(!capacitySummary.contains("Media:"))
        #expect(!capacitySummary.contains("存储介质："))
    }

}

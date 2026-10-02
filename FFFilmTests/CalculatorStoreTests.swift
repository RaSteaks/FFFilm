import Foundation
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
    func shutterEditInvalidatesResetUndo() {
        let store = CalculatorStore()
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

    @Test("Reset updates the default camera memory and can be undone in one step")
    func resetUndo() throws {
        let suite = "FFFilm.ResetUndo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CalculatorStore(defaults: defaults)
        store.selectMedia("1tb")
        store.setShootHours(4.5)
        let before = store.settings
        #expect(store.pinCurrentSetup() == .added)
        store.resetActiveView()
        #expect(store.resetUndoAvailable)
        #expect(store.settings == CalculatorEngine(catalog: store.catalog).normalized(.default))
        #expect(store.pinnedSetups.count == 1)
        store.undoReset()
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
    }

    @Test("Comparison snapshots deduplicate identical settings and stop at four")
    func comparisonDeduplicationAndLimit() throws {
        let suite = "FFFilm.Comparison.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CalculatorStore(defaults: defaults)
        #expect(store.pinCurrentSetup() == .added)
        #expect(store.pinCurrentSetup() == .duplicate)
        for camera in store.catalog.cameras where !camera.isStandaloneProRes {
            guard store.pinnedSetups.count < 4 else { break }
            store.selectCamera(camera.id)
            _ = store.pinCurrentSetup()
        }
        #expect(store.pinnedSetups.count == 4)
        #expect(store.pinCurrentSetup() == .full || store.pinCurrentSetup() == .duplicate)
    }

    @Test("Duration setters reject invalid values without creating a new result")
    func durationBounds() {
        let store = CalculatorStore()
        let original = store.settings.shootHours
        store.setShootHours(0.249)
        store.setShootHours(24.001)
        store.setShootHours(.nan)
        #expect(store.settings.shootHours == original)
        store.setShootHours(6.75)
        #expect(store.settings.shootHours == 6.75)
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
        #expect(!summary.contains("3.50 h"))
        // Planned hours never affect available recording time; media never affects required storage.
        store.setShootHours(7)
        #expect(store.calculation.captureRuntimeHours == runtime)
        store.recordingTask = .capacity
        store.selectMedia("2tb")
        #expect(store.calculation.dayTotalGb == capacity * 2)
        let capacitySummary = store.readableRecordingSummary(storageUnit: .decimal)
        #expect(capacitySummary.contains("7.00 h"))
        #expect(!capacitySummary.contains("Media:"))
        #expect(!capacitySummary.contains("存储介质："))
    }

    @Test("Readable summaries include the storage plan in both unit systems")
    func readableSummaries() {
        let store = CalculatorStore()
        let decimal = store.readableRecordingSummary(storageUnit: .decimal)
        let binary = store.readableRecordingSummary(storageUnit: .binary)
        // The host system language decides the summary language, so assert on
        // language-invariant fragments: unit symbols, fps, Mb/s and numbers.
        #expect(decimal.contains("GB/h"))
        #expect(binary.contains("GiB/h"))
        #expect(decimal.contains("Mb/s"))
        #expect(decimal.contains("fps"))
        #expect(decimal.contains("8.00"))  // default 8-hour plan
    }
}

import Testing
@testable import FFFilm

struct FFFilmTests {
    private let catalog = CatalogData.bundled

    @Test("The migrated catalog preserves every source profile")
    func catalogMigration() {
        #expect(catalog.cameras.count == 33)
        #expect(catalog.codecs.count == 15)
        #expect(catalog.rateTable.count == 43)
        #expect(catalog.cameras.contains(where: { $0.id == "alexa35" }))
        #expect(catalog.cameras.contains(where: { $0.id == "ronin4d-8k" }))
    }

    @Test("Default ALEXA 35 ARRIRAW HDE calculation matches the web model")
    func defaultRateCalculation() {
        let result = CalculatorEngine(catalog: catalog).calculate(settings: .default)
        #expect(abs(result.projectMbps - 2_501.8785792) < 0.001)
        #expect(abs(result.projectGbPerHour - 1_125.84536064) < 0.001)
    }

    @Test("Apple ProRes uses the white-paper target row")
    func proResTargetRate() {
        let settings = CaptureSettings(
            cameraId: "apple-prores", modeId: "encoded-frame", resolutionId: "prores-1920x1080",
            codecId: "prores-422", projectFps: 24, sensorFps: 24, sensorOverdrive: false,
            mediaId: "1tb", shootHours: 8
        )
        let result = CalculatorEngine(catalog: catalog).calculate(settings: settings)
        #expect(result.projectMbps == 117)
    }

    @Test("DJI manual MB/s rows are converted to Mb/s")
    func djiOfficialRate() {
        let settings = CaptureSettings(
            cameraId: "ronin4d-8k", modeId: "full-frame-17x9", resolutionId: "r4d8k-8k-ff",
            codecId: "dji-prores-raw", projectFps: 24, sensorFps: 24, sensorOverdrive: false,
            mediaId: "2tb", shootHours: 8
        )
        let result = CalculatorEngine(catalog: catalog).calculate(settings: settings)
        #expect(result.projectMbps == 3_240)
    }

    @Test("DJI playback preserves recorded frames across nonlinear codec rate rows")
    func djiPlaybackDuration() {
        let engine = CalculatorEngine(catalog: catalog)
        var settings = CaptureSettings(
            cameraId: "ronin4d-8k", modeId: "full-frame-17x9", resolutionId: "r4d8k-4k-ff",
            codecId: "dji-h264", projectFps: 24, sensorFps: 60, sensorOverdrive: false,
            mediaId: "2tb", shootHours: 8
        )
        // The catalog uses 25 MB/s at 60 fps and 18 MB/s at 24 fps; retiming does not re-encode.
        let result = engine.calculate(settings: settings)
        #expect(abs(result.captureRuntimeHours - 22.22222222222222) < 0.0001)
        #expect(abs(result.projectRuntimeHours - 55.55555555555556) < 0.0001)
        settings.projectFps = 60
        settings.sensorFps = 24
        let undercranked = engine.calculate(settings: settings)
        #expect(abs(undercranked.projectRuntimeHours - 12.34567901234568) < 0.0001)
    }

    @Test("Camera storage depends on sensor cadence independently of project cadence")
    func cameraStorageCadence() {
        let engine = CalculatorEngine(catalog: catalog)
        var settings = CaptureSettings.default
        let baseline = engine.calculate(settings: settings)
        settings.projectFps = 25
        let playbackChanged = engine.calculate(settings: settings)
        #expect(playbackChanged.sensorGbPerHour == baseline.sensorGbPerHour)
        #expect(playbackChanged.sensorMbps == baseline.sensorMbps)
        #expect(playbackChanged.dayTotalGb == baseline.dayTotalGb)
        #expect(playbackChanged.captureRuntimeHours == baseline.captureRuntimeHours)

        // Doubling capture cadence doubles storage while halving available recording time.
        settings.sensorFps = 48
        let captureChanged = engine.calculate(settings: settings)
        #expect(abs(captureChanged.sensorGbPerHour - baseline.sensorGbPerHour * 2) < 0.0001)
        #expect(abs(captureChanged.dayTotalGb - baseline.dayTotalGb * 2) < 0.0001)
        #expect(abs(captureChanged.captureRuntimeHours - baseline.captureRuntimeHours / 2) < 0.0001)
    }

    @Test("Standalone ProRes storage follows project fps and ignores stale sensor fps")
    func standaloneProResStorageCadence() {
        let engine = CalculatorEngine(catalog: catalog)
        var settings = CaptureSettings(
            cameraId: "apple-prores", modeId: "encoded-frame", resolutionId: "prores-1920x1080",
            codecId: "prores-422", projectFps: 24, sensorFps: 120, sensorOverdrive: false,
            mediaId: "1tb", shootHours: 8
        )
        let baseline = engine.calculate(settings: settings)
        #expect(baseline.sensorMbps == 117)
        #expect(baseline.sensorGbPerHour == baseline.projectGbPerHour)
        #expect(abs(baseline.projectRuntimeHours - baseline.captureRuntimeHours) < 0.0001)
        settings.projectFps = 30
        let changed = engine.calculate(settings: settings)
        #expect(changed.sensorMbps == changed.projectMbps)
        #expect(changed.sensorGbPerHour > baseline.sensorGbPerHour)
        #expect(changed.dayTotalGb > baseline.dayTotalGb)
        #expect(changed.captureRuntimeHours < baseline.captureRuntimeHours)
        #expect(abs(changed.projectRuntimeHours - changed.captureRuntimeHours) < 0.0001)
    }

    @Test("Selected media capacity produces a capture-time estimate")
    func estimatedRecordingTime() {
        var settings = CaptureSettings.default
        settings.sensorFps = 48
        let result = CalculatorEngine(catalog: catalog).calculate(settings: settings)

        #expect(abs(result.captureRuntimeHours - result.projectRuntimeHours / 2) < 0.0001)
        #expect(abs(result.captureRuntimeHours - result.media.capacityGb / result.sensorGbPerHour) < 0.0001)
    }

}

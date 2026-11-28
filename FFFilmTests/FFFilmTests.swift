import Testing
@testable import FFFilm

struct FFFilmTests {
    private let catalog = CatalogData.bundled

    @Test("The migrated catalog preserves every source profile")
    func catalogMigration() {
        #expect(catalog.cameras.count == 39)
        #expect(catalog.codecs.count == 31)
        #expect(catalog.rateTable.count == 92)
        #expect(catalog.cameras.contains(where: { $0.id == "alexa35" }))
        #expect(catalog.cameras.contains(where: { $0.id == "ronin4d-8k" }))
        #expect(catalog.cameras.contains(where: { $0.id == "a7m4" }))
    }

    @Test("ALEXA 35 Open Gate uses published card times and migrates offload-only HDE")
    func defaultRateCalculation() {
        let result = CalculatorEngine(catalog: catalog).calculate(settings: .default)
        #expect(result.codec.id == "arriraw")
        #expect(abs(result.projectGbPerHour - 2009) < 0.001)
        #expect(abs(result.captureRuntimeHours * 60 - 56) < 0.001)
        let engine = CalculatorEngine(catalog: catalog)
        var legacy = CaptureSettings.default
        legacy.codecId = "arriraw-hde"; legacy.mediaId = "1tb"
        #expect(engine.normalized(legacy).codecId == "arriraw")
        #expect(engine.availableSensorFrameRates(for: legacy).max() == 35)
        #expect(abs(engine.calculate(settings: legacy).captureRuntimeHours * 60 - 28) < 0.001)
        #expect(DisplayFormat.compactStorage(0.32).contains("MB"))
        for (id, expected) in [("fx6", "fx6-xavc-i"), ("venice2", "x-ocn-xt"), ("raptor-xl", "r3d-hq")] {
            legacy.cameraId = id
            let capture = engine.calculate(settings: legacy)
            #expect(capture.codec.id == expected && capture.sensorMbps > 0)
        }
    }

    @Test("Card counts respect published runtime boundaries")
    func requiredCardsAtRuntimeBoundary() {
        let engine = CalculatorEngine(catalog: catalog)
        var settings = CaptureSettings.default
        settings.mediaId = "1tb"
        // The ALEXA 35 reference is 28 minutes per card at 24 fps.
        for (seconds, cards) in [(0, 0), (1, 1), (1_679, 1), (1_680, 1), (1_681, 2),
                                 (25_200, 15), (25_201, 16)] {
            settings.shootHours = Double(seconds) / 3_600
            #expect(engine.calculate(settings: settings).requiredCards == cards)
        }
    }

    @Test("V-RAPTOR XL dedicated 4K recording offers standard ProRes 422")
    func raptorProRes422() {
        let engine = CalculatorEngine(catalog: catalog)
        let settings = CaptureSettings(
            cameraId: "raptor-xl", modeId: "prores-4k", resolutionId: "raptor-prores-4k",
            codecId: "prores-422", projectFps: 24, sensorFps: 24, sensorOverdrive: false,
            mediaId: "1tb", shootHours: 1
        )
        #expect(engine.availableCodecs(for: settings).contains { $0.id == "prores-422" })
        let result = engine.calculate(settings: settings)
        #expect(result.codec.id == "prores-422" && result.hasEstimate)
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
        #expect(baseline.projectMbps == 117 && baseline.sensorMbps == 117)
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

}

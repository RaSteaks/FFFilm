import Testing
@testable import FFFilm

struct KinefinityTests {
    private let catalog = CatalogData.bundled

    @Test("Kinefinity modes expose only supported codecs and published frame rates")
    func kinefinityCompatibility() {
        let engine = CalculatorEngine(catalog: catalog)
        let cameras = catalog.cameras.filter { $0.manufacturer == .kinefinity }
        #expect(cameras.count == 5)
        for camera in cameras {
            for mode in camera.modes {
                for resolution in mode.resolutions {
                    var settings = CaptureSettings.default
                    settings.cameraId = camera.id
                    settings.modeId = mode.id
                    settings.resolutionId = resolution.id
                    // Stale selections from another manufacturer must normalize safely.
                    settings.codecId = "arriraw"
                    settings.sensorFps = 660
                    let normalized = engine.normalized(settings)
                    let codecs = engine.availableCodecs(for: settings)
                    #expect(!codecs.isEmpty)
                    #expect(!codecs.contains { ["hevc-10", "prores-422-proxy", "arriraw"].contains($0.id) })
                    #expect(normalized.sensorFps == resolution.maxSensorFps)
                    #expect(engine.availableSensorFrameRates(for: settings).first == resolution.minSensorFps)
                    for codec in codecs {
                        settings.codecId = codec.id
                        let result = engine.calculate(settings: settings)
                        #expect(result.sensorMbps.isFinite && result.sensorMbps > 0)
                        #expect(result.captureRuntimeHours.isFinite && result.captureRuntimeHours > 0)
                    }
                    if mode.id == "raw-kineos8" {
                        #expect(codecs.map(\.id) == ["kinefinity-dng"])
                        #expect(resolution.width <= 4096)
                    } else {
                        #expect(codecs.allSatisfy { $0.rateModel == .appleTarget })
                        #expect(codecs.count == (camera.id == "vista" ? 3 : 5))
                    }
                }
            }
        }
    }

    @Test("Oversampled ProRes uses encoded pixels for rate and published dimensions for coverage")
    func kinefinityOversampling() {
        var settings = CaptureSettings.default
        settings.cameraId = "mavo-edge-8k"
        settings.modeId = "full-frame"
        settings.resolutionId = "mavo-edge-8k-full-frame-12"
        settings.codecId = "prores-422-hq"
        settings.sensorFps = 55
        let result = CalculatorEngine(catalog: catalog).calculate(settings: settings)
        #expect(result.resolution.width == 4096)
        #expect(result.resolution.height == 2160)
        #expect(result.clipWidthMm == 36)
        #expect(result.clipHeightMm == 19)
        let target = catalog.proResRateTable["4096x2160"]?["24"]?["prores-422-hq"]
        #expect(result.projectMbps == target)
        // Apple publishes rounded targets per cadence bucket; 55 fps scales the 60 fps row.
        #expect(abs(result.sensorMbps - 1886.0 * 55 / 60) < 0.0001)
        #expect(abs(result.captureRuntimeHours - 2000 / (1886.0 * 55 / 60 * 0.45)) < 0.0001)
    }

    @Test("KineOS 8 DNG uses a 12-bit video payload estimate")
    func kinefinityRaw() {
        var settings = CaptureSettings.default
        settings.cameraId = "mavo-edge-6k"
        settings.modeId = "raw-kineos8"
        settings.resolutionId = "mavo-edge-6k-raw-1"
        settings.codecId = "kinefinity-dng"
        settings.sensorFps = 58
        let engine = CalculatorEngine(catalog: catalog)
        let result = engine.calculate(settings: settings)
        #expect(abs(result.sensorMbps - 5772.9024) < 0.0001)
        #expect(result.clipWidthMm == 34.5)
        #expect(result.clipHeightMm == 19.4)
        // Moving back to 6K must discard the RAW codec, even if it remains in saved state.
        settings.modeId = "full-frame"
        settings.resolutionId = "mavo-edge-6k-full-frame-1"
        #expect(engine.normalized(settings).codecId != "kinefinity-dng")
        #expect(engine.normalized(settings).sensorFps == 48)
    }

}

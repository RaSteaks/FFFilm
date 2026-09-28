import Foundation
import Testing
@testable import FFFilm

/// Regression coverage for the Sony α mirrorless additions: internal XAVC
/// allowlists, published sensor-rate rows and media planning anchors.
struct SonyMirrorlessTests {
    private let catalog = CatalogData.bundled
    private let alphaIds = ["a1m2", "a9m3", "a7sm3", "a7m4", "a7rm5", "a7m5"]

    @Test("Sony optical area follows capture cadence rather than output pixels or playback fps")
    func opticalAreas() throws {
        let engine = CalculatorEngine(catalog: catalog)
        // Expected widths are independent anchors: full width, mandatory APS-C,
        // Sony's approximate 1.1/1.2x crops, and the α7S III's published 10% crop.
        let cases: [(String, Double, Double)] = [
            ("a1m2", 59.94, 35.9), ("a1m2", 100, 35.9 / 1.1),
            ("a1m2", 119.88, 35.9 / 1.1),
            ("a9m3", 119.88, 35.6),
            ("a7sm3", 59.94, 35.6), ("a7sm3", 100, 35.6 * 0.9),
            ("a7sm3", 119.88, 35.6 * 0.9),
            ("a7m4", 29.97, 35.9), ("a7m4", 50, 35.9 / 1.5),
            ("a7m4", 59.94, 35.9 / 1.5),
            ("a7rm5", 29.97, 35.7), ("a7rm5", 50, 35.7 / 1.2),
            ("a7rm5", 59.94, 35.7 / 1.2),
            ("a7m5", 59.94, 35.9), ("a7m5", 100, 35.9 / 1.5),
            ("a7m5", 119.88, 35.9 / 1.5)
        ]
        for (id, fps, width) in cases {
            var input = CaptureSettings.default
            input.cameraId = id; input.modeId = "full-frame"
            input.resolutionId = "\(id)-uhd"; input.codecId = "xavc-s-4k-422"
            input.sensorFps = fps
            for playback in [23.976, 59.94] {
                input.projectFps = playback
                let result = engine.calculate(settings: input)
                let height = width * 9 / 16
                #expect(abs(result.clipWidthMm - width) < 0.000001)
                #expect(abs(result.clipHeightMm - height) < 0.000001)
                #expect(abs(result.imageCircleMm - hypot(width, height)) < 0.000001)
                #expect(abs(result.formatFactor - hypot(width, height) / hypot(24.89, 14)) < 0.000001)
            }
        }
        // HD downsampling retains the full optical width; 8K has model-specific coverage.
        for id in alphaIds {
            let camera = engine.camera(id: id)
            for resolution in camera.modes[0].resolutions {
                #expect(resolution.activeWidthMm != nil && resolution.activeHeightMm != nil)
                if resolution.id.hasSuffix("-uhd") { continue }
                var input = settings(camera: id, resolution: resolution)
                input.sensorFps = 23.976
                let width = camera.sensorWidthMm / (resolution.id == "a7rm5-8k" ? 1.2 : 1)
                let result = engine.calculate(settings: input)
                #expect(abs(result.clipWidthMm - width) < 0.000001)
                #expect(abs(result.clipHeightMm - width * 9 / 16) < 0.000001)
            }
        }
        // A stale unsupported high cadence is normalized before choosing the optical crop.
        var input = CaptureSettings.default
        input.cameraId = "a7sm3"; input.modeId = "full-frame"
        input.resolutionId = "a7sm3-uhd"; input.codecId = "xavc-si-4k"
        input.sensorFps = 119.88
        #expect(engine.normalized(input).sensorFps == 59.94)
        #expect(abs(engine.calculate(settings: input).clipWidthMm - 35.6) < 0.000001)
    }

    private func settings(camera id: String, resolution: Resolution) -> CaptureSettings {
        var settings = CaptureSettings.default
        settings.cameraId = id
        settings.modeId = "full-frame"
        settings.resolutionId = resolution.id
        return settings
    }

    @Test("α mirrorless bodies expose only internal XAVC codecs at published cadences")
    func alphaCompatibility() {
        let engine = CalculatorEngine(catalog: catalog)
        let cameras = alphaIds.map { engine.camera(id: $0) }
        #expect(cameras.allSatisfy { $0.manufacturer == .sony && !$0.isStandaloneProRes })
        for camera in cameras {
            for mode in camera.modes {
                for resolution in mode.resolutions {
                    var settings = self.settings(camera: camera.id, resolution: resolution)
                    // Stale selections from another manufacturer must normalize safely.
                    settings.codecId = "arriraw"
                    settings.sensorFps = 660

                    let normalized = engine.normalized(settings)
                    let codecs = engine.availableCodecs(for: settings)
                    let expectedCount = resolution.id.hasSuffix("-8k") ? 1
                        : resolution.width > 1920 ? 5 : 2
                    #expect(codecs.count == expectedCount)
                    #expect(codecs.allSatisfy { $0.family == "XAVC" && $0.rateModel == .publishedTable })
                    #expect(!codecs.contains { ["hevc-10", "prores-422", "arriraw", "dji-h264"].contains($0.id) })
                    // The stale sensor fps clamps to the resolved codec's published ceiling,
                    // which can sit below the body's overall maximum (e.g. S-I 4K on α7 IV).
                    let rates = engine.availableSensorFrameRates(for: settings)
                    #expect(!rates.isEmpty)
                    #expect(normalized.sensorFps == rates.last)
                    if let ceiling = resolution.maxSensorFps {
                        #expect((rates.last ?? 0) <= ceiling)
                    }

                    for codec in codecs {
                        settings.codecId = codec.id
                        let result = engine.calculate(settings: settings)
                        #expect(result.sensorMbps.isFinite && result.sensorMbps > 0)
                        #expect(result.captureRuntimeHours.isFinite && result.captureRuntimeHours > 0)
                    }
                }
            }
        }
    }

    @Test("Published Sony rate rows anchor exact sensor data rates")
    func publishedRateAnchors() {
        let engine = CalculatorEngine(catalog: catalog)

        func mbps(camera: String, resolution: String, codec: String, fps: Double) -> Double {
            var settings = CaptureSettings.default
            settings.cameraId = camera
            settings.modeId = "full-frame"
            settings.resolutionId = resolution
            settings.codecId = codec
            // Published rows are exact only at their own cadence.
            settings.projectFps = fps
            settings.sensorFps = fps
            return engine.calculate(settings: settings).sensorMbps
        }

        // XAVC S-I 4K tops at 600 Mb/s; an hour consumes 270 GB.
        #expect(mbps(camera: "a7m4", resolution: "a7m4-uhd", codec: "xavc-si-4k", fps: 59.94) == 600)
        #expect(mbps(camera: "a7m4", resolution: "a7m4-uhd", codec: "xavc-s-4k-422", fps: 23.976) == 100)
        #expect(mbps(camera: "a7m4", resolution: "a7m4-uhd", codec: "xavc-s-4k-420", fps: 59.94) == 150)
        #expect(mbps(camera: "a7m4", resolution: "a7m4-uhd", codec: "xavc-hs-4k-422", fps: 59.94) == 200)
        #expect(mbps(camera: "a7m4", resolution: "a7m4-uhd", codec: "xavc-hs-4k-420", fps: 23.976) == 100)

        // 120p bodies publish 280 Mb/s (XAVC S 4:2:2 / XAVC HS 4:2:2).
        #expect(mbps(camera: "a7sm3", resolution: "a7sm3-uhd", codec: "xavc-s-4k-422", fps: 119.88) == 280)
        #expect(mbps(camera: "a7sm3", resolution: "a7sm3-uhd", codec: "xavc-s-4k-420", fps: 119.88) == 200)
        #expect(mbps(camera: "a7sm3", resolution: "a7sm3-uhd", codec: "xavc-hs-4k-422", fps: 119.88) == 280)
        #expect(mbps(camera: "a7sm3", resolution: "a7sm3-uhd", codec: "xavc-hs-4k-420", fps: 119.88) == 200)

        // 8K is XAVC HS only: 8.6K oversampled 520 Mb/s on α1 II, 400 Mb/s on α7R V.
        #expect(mbps(camera: "a1m2", resolution: "a1m2-8k", codec: "xavc-hs-8k", fps: 29.97) == 520)
        #expect(mbps(camera: "a7rm5", resolution: "a7rm5-8k", codec: "xavc-hs-8k", fps: 23.976) == 400)

        // HD rows: 222 Mb/s All-Intra and 100 Mb/s long-GOP at 119.88p.
        #expect(mbps(camera: "a7m4", resolution: "a7m4-hd", codec: "xavc-si-hd", fps: 59.94) == 222)
        #expect(mbps(camera: "a7m4", resolution: "a7m4-hd", codec: "xavc-s-hd", fps: 119.88) == 100)

        var settings = CaptureSettings.default
        settings.cameraId = "a7m4"
        settings.modeId = "full-frame"
        settings.resolutionId = "a7m4-uhd"
        settings.codecId = "xavc-si-4k"
        settings.mediaId = "256gb"
        settings.projectFps = 59.94
        settings.sensorFps = 59.94
        let result = engine.calculate(settings: settings)
        #expect(abs(result.sensorGbPerHour - 270) < 0.0001)
        #expect(abs(result.captureRuntimeHours - 256 / 270) < 0.0001)
        #expect(abs(result.dayTotalGb - 270 * settings.shootHours) < 0.0001)
    }

    @Test("Frame-rate availability follows the published rows per body")
    func frameRateLimits() {
        let engine = CalculatorEngine(catalog: catalog)

        func rates(camera: String, resolution: String, codec: String) -> [Double] {
            var settings = CaptureSettings.default
            settings.cameraId = camera
            settings.modeId = "full-frame"
            settings.resolutionId = resolution
            settings.codecId = codec
            return engine.availableSensorFrameRates(for: settings)
        }

        // α7 IV tops out at 4K 59.94p; no 119.88p rows exist for its UHD output.
        #expect(rates(camera: "a7m4", resolution: "a7m4-uhd", codec: "xavc-si-4k")
            == [23.976, 25, 29.97, 50, 59.94])
        // 120p bodies publish XAVC S 4K up to 119.88p but XAVC HS only at the wide cadences.
        #expect(rates(camera: "a7sm3", resolution: "a7sm3-uhd", codec: "xavc-s-4k-422")
            == [23.976, 25, 29.97, 50, 59.94, 100, 119.88])
        #expect(rates(camera: "a7sm3", resolution: "a7sm3-uhd", codec: "xavc-hs-4k-422")
            == [23.976, 50, 59.94, 100, 119.88])
        // 8K cadences stay at their published ceilings.
        #expect(rates(camera: "a7rm5", resolution: "a7rm5-8k", codec: "xavc-hs-8k") == [23.976, 25])
        #expect(rates(camera: "a1m2", resolution: "a1m2-8k", codec: "xavc-hs-8k") == [23.976, 25, 29.97])
    }

    @Test("Saved codec selections normalize when the output cannot use them")
    func staleSelectionNormalization() {
        let engine = CalculatorEngine(catalog: catalog)

        var settings = CaptureSettings.default
        settings.cameraId = "a7m4"
        settings.modeId = "full-frame"
        settings.resolutionId = "a7m4-uhd"
        // 8K H.265 has no UHD rows; UHD falls back to the first published codec.
        settings.codecId = "xavc-hs-8k"
        #expect(engine.normalized(settings).codecId == "xavc-si-4k")

        // Moving α1 II from 4K to 8K must trade the 4K codec for the 8K one, and back.
        settings.cameraId = "a1m2"
        settings.resolutionId = "a1m2-uhd"
        settings.codecId = "xavc-si-4k"
        settings.resolutionId = "a1m2-8k"
        #expect(engine.normalized(settings).codecId == "xavc-hs-8k")
        settings.resolutionId = "a1m2-uhd"
        #expect(engine.normalized(settings).codecId == "xavc-si-4k")

        // HD resolutions never inherit 4K codecs; All-Intra HD is the first HD option.
        settings.resolutionId = "a1m2-hd"
        settings.codecId = "xavc-s-4k-422"
        #expect(engine.normalized(settings).codecId == "xavc-si-hd")
    }
}

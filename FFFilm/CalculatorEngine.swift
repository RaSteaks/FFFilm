import Foundation

/// Pure calculation and catalog-selection logic shared by the UI and tests.
struct CalculatorEngine {
    let catalog: CatalogData

    func camera(id: String) -> CameraProfile {
        catalog.cameras.first(where: { $0.id == id })
            ?? catalog.cameras.first(where: { !$0.isStandaloneProRes })
            ?? catalog.cameras[0]
    }

    func mode(for settings: CaptureSettings, camera: CameraProfile? = nil) -> SensorMode {
        let selectedCamera = camera ?? self.camera(id: settings.cameraId)
        return selectedCamera.modes.first(where: { $0.id == settings.modeId })
            ?? selectedCamera.modes[0]
    }

    func resolution(for settings: CaptureSettings, mode: SensorMode? = nil) -> Resolution {
        let selectedMode = mode ?? self.mode(for: settings)
        return selectedMode.resolutions.first(where: { $0.id == settings.resolutionId })
            ?? preferredResolution(camera: camera(id: settings.cameraId), mode: selectedMode)
    }

    func preferredResolution(camera: CameraProfile, mode: SensorMode) -> Resolution {
        if camera.isStandaloneProRes,
           let fullHD = mode.resolutions.first(where: { $0.id == "prores-1920x1080" }) {
            return fullHD
        }
        return mode.resolutions[0]
    }

    func availableCodecs(for settings: CaptureSettings) -> [CodecProfile] {
        let selectedCamera = camera(id: settings.cameraId)
        let selectedMode = mode(for: settings, camera: selectedCamera)
        let selectedResolution = resolution(for: settings, mode: selectedMode)

        if selectedCamera.isStandaloneProRes {
            return catalog.codecs.filter { $0.rateModel == .appleTarget }
        }

        return catalog.codecs.filter {
            codecMatchesCamera($0, camera: selectedCamera, resolution: selectedResolution)
        }
    }

    func codec(for settings: CaptureSettings) -> CodecProfile {
        let selectedCamera = camera(id: settings.cameraId)
        let available = availableCodecs(for: settings)
        if let selected = available.first(where: { $0.id == settings.codecId }) {
            return selected
        }
        if selectedCamera.isStandaloneProRes {
            return available.first(where: { $0.id == "prores-422" }) ?? available[0]
        }
        if selectedCamera.manufacturer == .dji {
            return available.first(where: { $0.id == "dji-prores-raw" }) ?? available[0]
        }
        return available[0]
    }

    func media(id: String) -> MediaProfile {
        catalog.mediaOptions.first(where: { $0.id == id }) ?? catalog.mediaOptions[0]
    }

    func availableSensorFrameRates(for settings: CaptureSettings) -> [Double] {
        let selectedCamera = camera(id: settings.cameraId)
        if selectedCamera.isStandaloneProRes {
            return catalog.projectFrameRates
        }

        let selectedMode = mode(for: settings, camera: selectedCamera)
        let selectedResolution = resolution(for: settings, mode: selectedMode)
        let selectedCodec = codec(for: settings)
        let cameraMaximum = selectedCamera.supportsSensorOverdrive == true && !settings.sensorOverdrive
            ? selectedCamera.maxSensorFpsWithoutOverdrive ?? selectedCamera.maxSensorFps ?? 60
            : selectedCamera.maxSensorFps ?? 60
        let maximum = min(cameraMaximum, selectedResolution.maxSensorFps ?? cameraMaximum)
        let tableRow = selectedCodec.rateModel == .publishedTable
            ? catalog.rateTable[publishedRateKey(camera: selectedCamera, codec: selectedCodec, resolution: selectedResolution)]
            : nil

        // Include published endpoints only for profiles that declare a recording range.
        // This exposes Kinefinity's 45/55/58/112 fps modes without changing older profiles.
        var candidates = catalog.frameRates
        if let minimum = selectedResolution.minSensorFps {
            candidates += [minimum, maximum]
        }
        return Array(Set(candidates)).sorted().filter { rate in
            rate >= (selectedResolution.minSensorFps ?? 0)
                && rate <= maximum && (tableRow == nil || tableRow?[rateKey(rate)] != nil)
        }
    }

    func normalized(_ input: CaptureSettings) -> CaptureSettings {
        var output = input
        let selectedCamera = camera(id: output.cameraId)
        let selectedMode = mode(for: output, camera: selectedCamera)
        output.cameraId = selectedCamera.id
        output.modeId = selectedMode.id
        output.resolutionId = resolution(for: output, mode: selectedMode).id
        output.codecId = codec(for: output).id
        output.projectFps = normalizedRate(output.projectFps, available: catalog.projectFrameRates)
        // Clear unsupported camera flags before validating cadence so normalization
        // keeps deriving limits from the effective settings as rate policy evolves.
        if selectedCamera.supportsSensorOverdrive != true {
            output.sensorOverdrive = false
        }
        output.sensorFps = normalizedRate(output.sensorFps, available: availableSensorFrameRates(for: output))
        output.shootHours = min(max(output.shootHours, 0.25), 24)
        if selectedCamera.isStandaloneProRes {
            output.sensorFps = output.projectFps
        }
        return output
    }

    func calculate(settings input: CaptureSettings) -> Calculation {
        let settings = normalized(input)
        let selectedCamera = camera(id: settings.cameraId)
        let selectedMode = mode(for: settings, camera: selectedCamera)
        let selectedResolution = resolution(for: settings, mode: selectedMode)
        let selectedCodec = codec(for: settings)
        let selectedMedia = media(id: settings.mediaId)
        // Standalone ProRes has no separate capture cadence; its storage rate follows project fps.
        let effectiveSensorFps = selectedCamera.isStandaloneProRes ? settings.projectFps : settings.sensorFps
        let projectMbps = videoMbps(
            camera: selectedCamera,
            codec: selectedCodec,
            resolution: selectedResolution,
            fps: settings.projectFps
        )
        let sensorMbps = videoMbps(
            camera: selectedCamera,
            codec: selectedCodec,
            resolution: selectedResolution,
            fps: effectiveSensorFps
        )
        let projectGbPerHour = projectMbps * 3_600 / 8 / 1_000
        let sensorGbPerHour = sensorMbps * 3_600 / 8 / 1_000
        let captureRuntimeHours = selectedMedia.capacityGb / sensorGbPerHour
        // Retiming preserves recorded frames, even when codec rates do not scale linearly with fps.
        let projectRuntimeHours = captureRuntimeHours * effectiveSensorFps / settings.projectFps
        let dayTotalGb = sensorGbPerHour * settings.shootHours
        let activeWidth = selectedResolution.activeWidth ?? selectedResolution.width
        let activeHeight = selectedResolution.activeHeight ?? selectedResolution.height
        // Apply optical cropping at normalized capture cadence, never project playback fps.
        let crop = selectedResolution.sensorCrop
        let cropFactor = crop.map { effectiveSensorFps >= $0.minSensorFps ? $0.factor : 1 } ?? 1
        let clipWidth = selectedCamera.isStandaloneProRes
            ? 0
            : (selectedResolution.activeWidthMm
                ?? Double(activeWidth) / Double(selectedCamera.nativeWidth) * selectedCamera.sensorWidthMm) / cropFactor
        let clipHeight = selectedCamera.isStandaloneProRes
            ? 0
            : (selectedResolution.activeHeightMm
                ?? Double(activeHeight) / Double(selectedCamera.nativeHeight) * selectedCamera.sensorHeightMm) / cropFactor
        let imageCircle = hypot(clipWidth, clipHeight)
        let super35Diagonal = hypot(24.89, 14.0)

        return Calculation(
            camera: selectedCamera,
            mode: selectedMode,
            resolution: selectedResolution,
            codec: selectedCodec,
            media: selectedMedia,
            projectMbps: projectMbps,
            sensorMbps: sensorMbps,
            projectGbPerHour: projectGbPerHour,
            sensorGbPerHour: sensorGbPerHour,
            projectRuntimeHours: projectRuntimeHours,
            captureRuntimeHours: captureRuntimeHours,
            dayTotalGb: dayTotalGb,
            dayUsagePercent: dayTotalGb / selectedMedia.capacityGb * 100,
            clipWidthMm: clipWidth,
            clipHeightMm: clipHeight,
            imageCircleMm: imageCircle,
            formatFactor: selectedCamera.isStandaloneProRes ? 0 : imageCircle / super35Diagonal
        )
    }

    func calculateShutter(settings: ShutterSettings) -> ShutterCalculation {
        var fields: [ShutterInputField] = [.sensorFps, .maxAngle]
        switch settings.mode {
        case .conversion:
            fields.append(settings.direction == .angleToTime ? .angle : .shutterDenominator)
        case .flicker:
            fields.append(.preferredAngle)
        case .matching:
            fields += [.projectFps, .targetAngle]
        }
        if settings.needsLight, settings.light == .custom { fields.append(.customLightHz) }
        for field in fields where field.error(for: settings[keyPath: field.keyPath]) != nil {
            return ShutterCalculation(status: .invalidInput(field))
        }

        var lightHz = settings.lightHz
        if settings.needsLight, settings.light == .displays {
            guard let rates = settings.displayRefreshMilliHz else {
                return ShutterCalculation(status: .invalidDisplays)
            }
            // t * Hz must be integral for every display. The shortest common exposure is
            // 1000 / gcd(milliHz), avoiding floating-point GCD and unbounded cycle searches.
            let common = rates.reduce(Int64(0)) { divisor, rate in
                var a = divisor, b = rate
                while b != 0 { (a, b) = (b, a % b) }
                return a
            }
            lightHz = Double(common) / 1_000
        }
        let fps = settings.sensorFps
        let seconds: Double
        switch settings.mode {
        case .conversion:
            seconds = settings.direction == .angleToTime
                ? settings.angle / (360 * fps) : 1 / settings.shutterDenominator
        case .matching:
            // Equal exposure refers to the project baseline, not blur after retiming.
            let baselineFps = settings.match == .exposure ? settings.projectFps : fps
            seconds = settings.targetAngle / (360 * baselineFps)
        case .flicker:
            guard let candidates = shutterCandidates(fps: fps, lightHz: lightHz,
                                                      target: settings.preferredAngle, maximum: settings.maxAngle) else {
                return ShutterCalculation(status: .numericalLimit)
            }
            if candidates.isEmpty, settings.light == .displays {
                guard let compromise = displayCompromise(settings: settings, target: settings.preferredAngle) else {
                    return ShutterCalculation(status: .numericalLimit)
                }
                return ShutterCalculation(status: .valid, exposure: compromise.exposure, compromise: compromise)
            }
            return ShutterCalculation(status: candidates.isEmpty ? .noCandidates : .valid,
                                      exposure: candidates.first?.exposure, candidates: candidates)
        }
        guard let exposure = shutterExposure(seconds: seconds, fps: fps) else {
            return ShutterCalculation(status: .numericalLimit)
        }
        // Preserve an impossible theoretical result rather than clamping it to a different exposure.
        let exceeds = exposure.angle > settings.maxAngle && !shutterClose(exposure.angle, settings.maxAngle)
        var result = ShutterCalculation(status: exceeds ? .exceedsMaximum : .valid, exposure: exposure)
        if settings.mode == .matching {
            result.playbackSpeed = settings.projectFps / fps
            result.durationMultiplier = fps / settings.projectFps
            if settings.checksFlicker {
                let cycles = seconds * lightHz
                guard cycles.isFinite, cycles < 4_503_599_627_370_496,
                      let candidates = shutterCandidates(fps: fps, lightHz: lightHz,
                                                         target: exposure.angle, maximum: settings.maxAngle) else {
                    return ShutterCalculation(status: .numericalLimit)
                }
                // A complete positive integer number of light cycles is a model check, not a guarantee.
                result.matchesLightCycles = cycles.rounded() >= 1 && shutterClose(cycles, cycles.rounded())
                result.candidates = candidates
                if candidates.isEmpty, settings.light == .displays {
                    result.compromise = displayCompromise(settings: settings, target: exposure.angle)
                }
            }
        }
        return result
    }

    private func displayCompromise(settings: ShutterSettings, target: Double) -> ShutterCompromise? {
        guard let milliHz = settings.displayRefreshMilliHz else { return nil }
        let rates = Set(milliHz).sorted().map { Double($0) / 1_000 }
        let maximumTime = settings.maxAngle / (360 * settings.sensorFps)
        guard maximumTime.isFinite, maximumTime > 0 else { return nil }
        let preferredTime = min(target, settings.maxAngle) / (360 * settings.sensorFps)
        let budget = 4_096
        let boundaryCount = rates.reduce(0.0) { $0 + max(0, floor(maximumTime * $1 - 0.5)) }
        let approximate = boundaryCount > Double(budget)
        var intervals: [(Double, Double)] = []
        if !approximate {
            // Between half-cycle boundaries, each device's nearest positive integer is fixed.
            // The maximum absolute error is convex on that interval, so its minimum is exact.
            var boundaries: Set<Double> = [0, maximumTime]
            for hz in rates {
                let count = Int(max(0, floor(maximumTime * hz - 0.5)))
                if count > 0 {
                    for n in 1...count { boundaries.insert((Double(n) + 0.5) / hz) }
                }
            }
            let sorted = boundaries.sorted()
            intervals = Array(zip(sorted, sorted.dropFirst()))
        } else {
            // Very high Hz / low fps can have billions of boundaries. Optimize sampled cells
            // with a fixed budget and expose that approximation instead of claiming a global optimum.
            var visited = Set<Double>()
            let seeds = (1...budget).map { maximumTime * Double($0) / Double(budget) } + [preferredTime]
            for time in seeds {
                var lower = 0.0, upper = maximumTime
                for hz in rates {
                    let n = max(1, (time * hz).rounded())
                    if n > 1 { lower = max(lower, (n - 0.5) / hz) }
                    upper = min(upper, (n + 0.5) / hz)
                }
                if lower <= upper, visited.insert(lower).inserted { intervals.append((lower, upper)) }
            }
        }
        var bestTime = maximumTime
        func error(_ time: Double) -> Double {
            rates.reduce(0) { max($0, abs(time * $1 - max(1, (time * $1).rounded()))) }
        }
        var bestError = error(bestTime)
        func consider(_ time: Double) {
            guard time > 0, time <= maximumTime else { return }
            let candidateError = error(time)
            let tied = abs(candidateError - bestError) <= 1e-12
            let distance = abs(time - preferredTime), bestDistance = abs(bestTime - preferredTime)
            if candidateError < bestError - 1e-12 || (tied && (distance < bestDistance || (distance == bestDistance && time < bestTime))) {
                bestTime = time
                bestError = candidateError
            }
        }
        for (lower, upper) in intervals {
            let middle = lower + (upper - lower) / 2
            let counts = rates.map { max(1, (middle * $0).rounded()) }
            // |hz*t - n| <= e gives [(n-e)/hz, (n+e)/hz]. All intervals intersect
            // [lower, upper] exactly when e satisfies the endpoint and pairwise bounds.
            // Solve those bounds directly instead of scanning every rate 48 times by bisection.
            var minimumError = 0.0
            for i in rates.indices {
                minimumError = max(minimumError, counts[i] - rates[i] * upper,
                                   rates[i] * lower - counts[i])
                for j in 0..<i {
                    let pairError = abs(rates[i] * counts[j] - rates[j] * counts[i]) / (rates[i] + rates[j])
                    minimumError = max(minimumError, pairError)
                }
            }
            var lo = lower, hi = upper
            for (hz, n) in zip(rates, counts) {
                lo = max(lo, (n - minimumError) / hz)
                hi = min(hi, (n + minimumError) / hz)
            }
            // Roundoff can invert the feasible endpoints by a few ULPs. Their midpoint
            // remains a candidate; clamp to the cell to preserve the camera's exposure limit.
            let optimum = lo <= hi ? min(max(preferredTime, lo), hi) : lo + (hi - lo) / 2
            consider(lower)
            consider(upper)
            consider(min(max(optimum, lower), upper))
            consider(min(max(preferredTime, lower), upper))
        }
        guard let exposure = shutterExposure(seconds: bestTime, fps: settings.sensorFps) else { return nil }
        return ShutterCompromise(exposure: exposure,
                                displays: rates.map { DisplayCycleMatch(hz: $0, cycles: bestTime * $0) },
                                approximateSearch: approximate)
    }

    private func shutterExposure(seconds: Double, fps: Double) -> ShutterExposure? {
        let angle = seconds * (360 * fps)
        guard seconds.isFinite, seconds > 0, angle.isFinite, angle > 0,
              (seconds * 1_000).isFinite, (1 / seconds).isFinite, 1 / seconds > 0 else { return nil }
        return ShutterExposure(exposureSeconds: seconds, angle: angle, framePeriodMs: 1_000 / fps)
    }

    private func shutterClose(_ lhs: Double, _ rhs: Double) -> Bool {
        // ULP-scaled tolerance handles boundary arithmetic without accepting an arbitrary partial cycle.
        abs(lhs - rhs) <= min(1e-9, 8 * max(lhs.ulp, rhs.ulp))
    }

    private func shutterCandidates(fps: Double, lightHz: Double, target: Double,
                                   maximum: Double) -> [ShutterCandidate]? {
        // Traditional mains presets assume twice-mains light pulses; custom Hz is already optical Hz.
        let step = 360 * fps / lightHz
        let limit = maximum / step
        guard step.isFinite, step > 0, limit.isFinite, limit < 4_503_599_627_370_496 else { return nil }
        let nearest = limit.rounded()
        let upper = shutterClose(limit, nearest) ? nearest : floor(limit)
        guard upper >= 1 else { return [] }
        let ideal = target / step
        // Only the nearest three integers can win. Bound the center before enumerating six neighbors,
        // so even a very high-frequency light source never produces an unbounded allocation or loop.
        let center = floor(min(max(ideal, 1), upper))
        var cycleCounts = Set<Double>()
        for offset in -2 ... 3 {
            cycleCounts.insert(min(max(center + Double(offset), 1), upper))
        }
        var candidates: [ShutterCandidate] = []
        for cycles in cycleCounts {
            guard let exposure = shutterExposure(seconds: cycles / lightHz, fps: fps) else { return nil }
            if exposure.angle <= maximum || shutterClose(exposure.angle, maximum) {
                candidates.append(ShutterCandidate(cycles: cycles, exposure: exposure))
            }
        }
        // Exact mathematical ties may differ by a few ULPs; rank these by the lower angle.
        return Array(candidates.sorted {
            // Outside a pair's interval, monotonic order avoids cancellation against enormous targets.
            if target >= max($0.exposure.angle, $1.exposure.angle) {
                return $0.exposure.angle > $1.exposure.angle
            }
            if target <= min($0.exposure.angle, $1.exposure.angle) {
                return $0.exposure.angle < $1.exposure.angle
            }
            let lhs = abs($0.exposure.angle - target)
            let rhs = abs($1.exposure.angle - target)
            if shutterClose(lhs, rhs) { return $0.exposure.angle < $1.exposure.angle }
            return lhs < rhs
        }.prefix(3))
    }

    private func codecMatchesCamera(
        _ codec: CodecProfile,
        camera: CameraProfile,
        resolution: Resolution
    ) -> Bool {
        // Mode restrictions intersect with camera and codec restrictions (not replace them).
        if let ids = camera.supportedCodecIds, !ids.contains(codec.id) { return false }
        if let ids = resolution.supportedCodecIds, !ids.contains(codec.id) { return false }
        if let cameraIDs = codec.supportedCameraIds, !cameraIDs.contains(camera.id) {
            return false
        }
        if codec.rateModel == .publishedTable,
           catalog.rateTable[publishedRateKey(camera: camera, codec: codec, resolution: resolution)] == nil {
            return false
        }
        if camera.manufacturer == .dji {
            return codec.supportedManufacturers?.contains(.dji) == true
        }
        return codec.supportedManufacturers?.contains(camera.manufacturer) ?? true
    }

    private func videoMbps(
        camera: CameraProfile,
        codec: CodecProfile,
        resolution: Resolution,
        fps: Double
    ) -> Double {
        switch codec.rateModel {
        case .appleTarget:
            return proResMbps(codec: codec, resolution: resolution, fps: fps)
        case .publishedTable:
            return publishedMbps(camera: camera, codec: codec, resolution: resolution, fps: fps)
        case .estimatedBitsPerPixel:
            return Double(resolution.width * resolution.height)
                * (codec.effectiveBitsPerPixel ?? 0)
                * fps / 1_000_000
        }
    }

    private func proResMbps(codec: CodecProfile, resolution: Resolution, fps: Double) -> Double {
        guard codec.id.hasPrefix("prores-") else { return 0 }
        let bucket: Double
        if fps <= 24 { bucket = 24 }
        else if fps <= 25 { bucket = 25 }
        else if fps <= 30 { bucket = 30 }
        else if fps <= 50 { bucket = 50 }
        else { bucket = 60 }

        let dimensionKey = "\(resolution.width)x\(resolution.height)"
        if let target = catalog.proResRateTable[dimensionKey]?[rateKey(bucket)]?[codec.id] {
            return target * fps / bucket
        }

        let reference = catalog.proResRateTable["1920x1080"]?["24"]?[codec.id] ?? 0
        let pixelScale = Double(resolution.width * resolution.height) / Double(1_920 * 1_080)
        return reference * pixelScale * fps / 24
    }

    /// Published MB/s rows are converted to Mb/s; an unmatched cadence scales the nearest row.
    private func publishedMbps(
        camera: CameraProfile,
        codec: CodecProfile,
        resolution: Resolution,
        fps: Double
    ) -> Double {
        if let row = catalog.rateTable[publishedRateKey(camera: camera, codec: codec, resolution: resolution)] {
            if let exact = row[rateKey(fps)] {
                return exact * 8
            }
            if let nearest = row.min(by: {
                abs((Double($0.key) ?? 0) - fps) < abs((Double($1.key) ?? 0) - fps)
            }), let nearestRate = Double(nearest.key) {
                return nearest.value * fps / nearestRate * 8
            }
        }

        return Double(resolution.width * resolution.height)
            * (codec.effectiveBitsPerPixel ?? 0)
            * fps / 1_000_000
    }

    private func normalizedRate(_ rate: Double, available: [Double]) -> Double {
        available.contains(rate) ? rate : available.last ?? rate
    }

    private func publishedRateKey(camera: CameraProfile, codec: CodecProfile, resolution: Resolution) -> String {
        "\(camera.id)|\(codec.id)|\(resolution.id)"
    }

    private func rateKey(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func positive(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    private func bounded(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

import Foundation

/// Text used outside SwiftUI views, where a `LocalizedStringKey` is not
/// available. The String Catalog owns the translations and these defaults keep
/// the app usable if a key is missing from an older bundle.
enum AppText {
    // Explicit-key lookup: the interpolated defaultValue carries the runtime
    // arguments, so catalog format strings ("…%@…") resolve in every language.
    // Keys must be literals because the underlying initializer takes StaticString.
    static func resolve(_ key: StaticString, defaultValue: String.LocalizationValue, comment: StaticString? = nil) -> String {
        let language = AppLanguagePreference.shared.language
        return String(localized: key, defaultValue: defaultValue, bundle: language.bundle, locale: language.locale, comment: comment)
    }

    // Foundation lookup needs an explicit bundle as well as SwiftUI's locale environment.
    static func localized(_ value: String.LocalizationValue, comment: StaticString? = nil) -> String {
        let language = AppLanguagePreference.shared.language
        return String(localized: value, bundle: language.bundle, locale: language.locale, comment: comment)
    }

    static func resource(_ value: LocalizedStringResource) -> String {
        var resource = value
        let language = AppLanguagePreference.shared.language
        resource.locale = language.locale
        return String(localized: resource)
    }

    static func key(_ key: String) -> String {
        AppLanguagePreference.shared.language.bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func captureParameter(_ parameter: CaptureParameter) -> String {
        resource(parameter.label)
    }

    static func adjusted(parameters: [CaptureParameter]) -> String {
        // Closure form keeps the MainActor isolation of `captureParameter`;
        // a bare function reference would drop into a nonisolated context.
        let names = parameters.map { captureParameter($0) }.formatted(.list(type: .and).locale(AppLanguagePreference.shared.language.locale))
        return resolve("feedback.adjusted",
                       defaultValue: "Compatibility adjusted: \(names).",
                       comment: "Non-blocking notice listing fields changed by camera compatibility.")
    }

    static var reset: String {
        resolve("feedback.reset", defaultValue: "Calculator reset.", comment: "Reset success feedback.")
    }

    static var resetUndone: String {
        resolve("feedback.resetUndone", defaultValue: "Reset undone.", comment: "Undo reset success feedback.")
    }

    static var comparisonAdded: String {
        resolve("feedback.comparisonAdded", defaultValue: "Added to comparison.", comment: "Comparison add success feedback.")
    }

    static var comparisonDuplicate: String {
        resolve("feedback.comparisonDuplicate", defaultValue: "This configuration is already in comparison.", comment: "Duplicate comparison feedback.")
    }

    static var comparisonFull: String {
        resolve("feedback.comparisonFull", defaultValue: "Comparison is full (4/4). Remove a setup before adding another.", comment: "Comparison limit feedback.")
    }

    static func imported(sensorFps: Double, projectFps: Double) -> String {
        // Name both values even though the action lives in the camera FPS row.
        resolve("feedback.importedFPS",
                defaultValue: "Imported: camera \(DisplayFormat.fps(sensorFps)) fps · project \(DisplayFormat.fps(projectFps)) fps",
                comment: "One-shot shutter FPS import feedback; values are sensor FPS then project FPS.")
    }

    static func recordingSummary(settings: CaptureSettings, calculation: Calculation, unit: StorageUnit, task: RecordingTask) -> String {
        // Catalog mode names are verbatim technical terms and never localized.
        let mode = calculation.mode.label
        let fps = calculation.camera.isStandaloneProRes ? settings.projectFps : settings.sensorFps
        let rate = DisplayFormat.number(unit.converted(decimalGB: calculation.sensorGbPerHour))
        let plan = DisplayFormat.compactStorage(calculation.dayTotalGb, unit: unit)
        let runtime = DisplayFormat.duration(calculation.captureRuntimeHours)
        let overdrive = settings.sensorOverdrive ? "ON" : "OFF"
        // Clipboard output answers only the active question, matching the visible result.
        let format = resolve("copy.recordingFormat",
                             defaultValue: "Camera: \(calculation.camera.name)\nFormat: \(mode) · \(calculation.resolution.label) · \(calculation.codec.name)\nFrame rate: \(DisplayFormat.fps(fps)) fps\nOverdrive: \(overdrive)\nRate: \(rate) \(unit.symbol)/h · \(DisplayFormat.number(calculation.sensorMbps)) Mb/s")
        let answer: String
        switch task {
        case .capacity:
            answer = resolve("copy.capacityAnswer", defaultValue: "Recording time: \(DisplayFormat.number(settings.shootHours, decimals: 2)) h\nRequired storage: \(plan)")
        case .runtime:
            answer = resolve("copy.runtimeAnswer", defaultValue: "Media: \(calculation.media.label)\nAvailable recording time: \(runtime)")
        }
        return format + "\n" + answer + "\n" + localized("technical.videoEstimate")
    }

    static func shutterSummary(settings: ShutterSettings, calculation: ShutterCalculation) -> String {
        let mode = resource(settings.mode.label)
        guard let exposure = calculation.exposure else {
            return resolve("copy.invalidShutterSummary", defaultValue: "Shutter result is unavailable because the input is invalid.", comment: "Clipboard text when shutter input is invalid.")
        }
        var summary = resolve("copy.shutterSummary",
                       defaultValue: "Mode: \(mode)\nAngle: \(DisplayFormat.shutterNumber(exposure.angle))°\nShutter time: \(DisplayFormat.shutterTime(exposure))\nExposure: \(DisplayFormat.exposureDuration(exposure))\nResult is a theoretical estimate; verify camera and lighting behavior with test footage.",
                       comment: "Readable shutter estimate copied to the clipboard.")
        // Copied settings carry the input context and feasibility qualification, not just a number.
        summary += "\n" + resolve("copy.shutterContext", defaultValue: "Capture FPS: \(DisplayFormat.shutterFrameRate(settings.sensorFps))\nUser-set maximum: \(DisplayFormat.shutterNumber(settings.maxAngle))°")
        if settings.mode == .matching {
            summary += "\n" + resolve("copy.shutterBaseline", defaultValue: "Baseline: \(DisplayFormat.shutterFrameRate(settings.projectFps)) fps · \(DisplayFormat.shutterNumber(settings.targetAngle))°\nGoal: \(resource(settings.match.label))")
        }
        if settings.mode == .flicker {
            // Identical output angles can come from different creative targets; keep that context.
            summary += "\n" + resolve("copy.shutterPreference", defaultValue: "Preferred angle: \(DisplayFormat.shutterNumber(settings.preferredAngle))°")
        }
        if settings.needsLight {
            let frequency = settings.light == .displays ? settings.displayRefreshRates : DisplayFormat.shutterNumber(settings.lightHz)
            summary += "\n" + resolve("copy.shutterLight", defaultValue: "Light model: \(resource(settings.light.label)) · \(frequency) Hz")
        }
        if calculation.status == .exceedsMaximum {
            summary += "\n" + shutterOverLimit(settings.maxAngle)
            if let alternative = calculation.maximumExposure, let stops = calculation.maximumExposureDifferenceStops {
                summary += "\n" + shutterMaximumAlternative(alternative, stops: stops)
            }
        }
        guard let compromise = calculation.compromise else { return summary }
        // Copy the qualification and reference angle as well as the main exposure; in matching
        // mode these are different values and must not be mistaken for the target.
        return summary + "\n" + localized("shutter.compromise.notice")
            + "\n" + localized("shutter.compromise.title")
            + ": \(DisplayFormat.shutterNumber(compromise.exposure.angle))° · \(DisplayFormat.shutterTime(compromise.exposure))"
            + "\n" + compromiseError(compromise.worstError)
            + "\n" + compromise.displays.map { displayCycleMatch($0) }.joined(separator: "\n")
            + "\n" + localized("shutter.compromise.method")
            + (compromise.approximateSearch ? "\n" + localized("shutter.compromise.approximate") : "")
    }

    static func shutterOverLimit(_ limit: Double) -> String {
        resolve("shutter.overLimit", defaultValue: "Theoretical angle exceeds the \(DisplayFormat.shutterNumber(limit))° limit. Cannot realize this exposure within the limit.",
                comment: "Shutter result exceeds the user-set angle limit.")
    }

    static func shutterRigContext(_ rig: ShutterRig) -> String {
        let camera = rig.cameraLabel.isEmpty ? localized("shutter.rig.unspecified") : rig.cameraLabel
        return resolve("shutter.rig.context", defaultValue: "Camera \(rig.id.rawValue): \(camera)")
    }

    static func shutterRestoreLabel(_ rig: ShutterRigID) -> String {
        resolve("shutter.library.restore", defaultValue: "Restore to camera \(rig.rawValue)")
    }

    static func shutterCandidateDifference(_ stops: Double) -> String {
        resolve("shutter.candidate.difference", defaultValue: "\(DisplayFormat.number(stops, decimals: 2)) stops versus target")
    }

    static func shutterLightModel(_ settings: ShutterSettings) -> String {
        switch settings.light {
        case .mains50, .mains60:
            resolve("shutter.lightModel.mains", defaultValue: "\(settings.light == .mains50 ? "50" : "60") Hz mains · assumes \(DisplayFormat.shutterNumber(settings.lightHz)) Hz light pulses")
        case .custom:
            resolve("shutter.lightModel.custom", defaultValue: "Light-pulse model: \(DisplayFormat.shutterNumber(settings.customLightHz)) Hz")
        case .displays:
            resolve("shutter.lightModel.displays", defaultValue: "Screen-cycle model: \(settings.displayRefreshRates) Hz · PWM and scan synchronization are not modeled.")
        }
    }

    static func shutterMaximumAlternative(_ exposure: ShutterExposure, stops: Double) -> String {
        resolve("shutter.maximumAlternative", defaultValue: "At the limit: \(DisplayFormat.shutterNumber(exposure.angle))° · \(DisplayFormat.shutterTime(exposure))\nExposure change: \(DisplayFormat.number(stops, decimals: 2)) stops versus target, with other exposure settings unchanged.")
    }

    static func compromiseError(_ error: Double) -> String {
        resolve("shutter.compromise.error",
                defaultValue: "Worst cycle deviation: \(DisplayFormat.shutterNumber(error)) cycles")
    }

    static func displayCycleMatch(_ display: DisplayCycleMatch) -> String {
        resolve("shutter.compromise.device",
                defaultValue: "\(DisplayFormat.shutterNumber(display.hz)) Hz · \(DisplayFormat.shutterNumber(display.cycles)) cycles · nearest \(DisplayFormat.shutterNumber(display.nearestCycles)) · deviation \(DisplayFormat.shutterNumber(display.error)) cycles")
    }
}

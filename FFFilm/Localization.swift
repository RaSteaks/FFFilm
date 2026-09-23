import Foundation

/// Text used outside SwiftUI views, where a `LocalizedStringKey` is not
/// available. The String Catalog owns the translations and these defaults keep
/// the app usable if a key is missing from an older bundle.
enum AppText {
    // Explicit-key lookup: the interpolated defaultValue carries the runtime
    // arguments, so catalog format strings ("…%@…") resolve in every language.
    // Keys must be literals because the underlying initializer takes StaticString.
    static func resolve(_ key: StaticString, defaultValue: String.LocalizationValue, comment: StaticString? = nil) -> String {
        String(localized: key, defaultValue: defaultValue, comment: comment)
    }

    static func captureParameter(_ parameter: CaptureParameter) -> String {
        String(localized: parameter.label)
    }

    static func adjusted(parameters: [CaptureParameter]) -> String {
        // Closure form keeps the MainActor isolation of `captureParameter`;
        // a bare function reference would drop into a nonisolated context.
        let names = parameters.map { captureParameter($0) }.formatted(.list(type: .and))
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
        resolve("feedback.importedFPS",
                defaultValue: "Imported sensor \(DisplayFormat.fps(sensorFps)) fps and project \(DisplayFormat.fps(projectFps)) fps from recording.",
                comment: "One-shot shutter FPS import feedback; values are sensor FPS then project FPS.")
    }

    static func recordingSummary(settings: CaptureSettings, calculation: Calculation, unit: StorageUnit) -> String {
        // Catalog mode names are verbatim technical terms and never localized.
        let mode = calculation.mode.label
        let fps = calculation.camera.isStandaloneProRes ? settings.projectFps : settings.sensorFps
        let rate = DisplayFormat.number(unit.converted(decimalGB: calculation.sensorGbPerHour))
        let plan = DisplayFormat.compactStorage(calculation.dayTotalGb, unit: unit)
        let runtime = DisplayFormat.duration(calculation.captureRuntimeHours)
        let overdrive = settings.sensorOverdrive ? "ON" : "OFF"
        return resolve("copy.recordingSummary",
                       defaultValue: "Camera: \(calculation.camera.name)\nFormat: \(mode) · \(calculation.resolution.label) · \(calculation.codec.name)\nFrame rate: \(DisplayFormat.fps(fps)) fps\nOverdrive: \(overdrive)\nMedia: \(calculation.media.label)\nRate: \(rate) \(unit.symbol)/h · \(DisplayFormat.number(calculation.sensorMbps)) Mb/s\nPlan: \(DisplayFormat.number(settings.shootHours, decimals: 2)) h · \(plan)\nAvailable recording time: \(runtime)\nVideo estimate only; verify camera firmware, codec and media before production.",
                       comment: "Readable recording estimate copied to the clipboard.")
    }

    static func shutterSummary(settings: ShutterSettings, calculation: ShutterCalculation) -> String {
        let mode = String(localized: settings.mode.label)
        guard let exposure = calculation.exposure else {
            return resolve("copy.invalidShutterSummary", defaultValue: "Shutter result is unavailable because the input is invalid.", comment: "Clipboard text when shutter input is invalid.")
        }
        return resolve("copy.shutterSummary",
                       defaultValue: "Mode: \(mode)\nAngle: \(DisplayFormat.shutterNumber(exposure.angle))°\nShutter time: \(DisplayFormat.shutterTime(exposure))\nExposure: \(DisplayFormat.exposureDuration(exposure))\nResult is a theoretical estimate; verify camera and lighting behavior with test footage.",
                       comment: "Readable shutter estimate copied to the clipboard.")
    }
}

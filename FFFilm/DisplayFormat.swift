import Foundation

enum DisplayFormat {
    static func number(_ value: Double, decimals: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }

    /// Convert from canonical decimal GB, including the matching TB/TiB threshold.
    static func compactStorage(_ gigabytes: Double, unit: StorageUnit = .decimal) -> String {
        let value = unit.converted(decimalGB: gigabytes)
        return value >= unit.radix
            ? "\(number(value / unit.radix, decimals: 2)) \(unit.largeSymbol)"
            : "\(number(value, decimals: 0)) \(unit.symbol)"
    }

    static func fps(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.2f", value).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }

    static func duration(_ hours: Double) -> String {
        let totalSeconds = max(0, Int((hours * 3_600).rounded()))
        let days = totalSeconds / 86_400
        let remaining = totalSeconds % 86_400
        let time = String(
            format: "%02d:%02d:%02d",
            remaining / 3_600,
            (remaining % 3_600) / 60,
            remaining % 60
        )
        return days > 0 ? "\(days)d \(time)" : time
    }

    static func humanDuration(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        let hour = totalMinutes / 60
        let minute = totalMinutes % 60
        return hour == 0 ? "\(minute)m" : String(format: "%dh %02dm", hour, minute)
    }

    /// Shutter readouts retain nonstandard cadences and denominators instead of snapping to integers.
    static func shutterNumber(_ value: Double) -> String {
        // Avoid displaying a positive exposure as zero, or an unreadably long reciprocal denominator.
        if value != 0, abs(value) < 0.000001 || abs(value) >= 1_000_000_000 {
            return value.formatted(.number.notation(.scientific).precision(.significantDigits(1 ... 7)))
        }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0 ... 6)))
    }

    // Keep the camera-setting readout separate from equivalent exposure-duration units.
    static func shutterTime(_ exposure: ShutterExposure) -> String {
        "1/\(shutterNumber(exposure.shutterDenominator)) s"
    }

    static func exposureDuration(_ exposure: ShutterExposure) -> String {
        "\(shutterNumber(exposure.exposureSeconds)) s · \(shutterNumber(exposure.exposureMs)) ms"
    }
}

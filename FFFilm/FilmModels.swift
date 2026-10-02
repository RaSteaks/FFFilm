#if os(macOS)
import Foundation
import CoreGraphics

/// Values are normalized to the oriented source, so preview size never changes saved crops.
nonisolated struct FilmRect: Codable, Equatable, Sendable {
    var x = 0.0, y = 0.0, width = 1.0, height = 1.0
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0.001 && height > 0.001 && x + width <= 1.000001 && y + height <= 1.000001
    }

    /// Resize one edge while keeping the opposite edge fixed inside the source.
    func resizing(_ edge: FilmCropEdge, by delta: CGFloat) -> FilmRect {
        var result = self
        switch edge {
        case .left:
            let minimum = min(0.002, width)
            result.x = min(x + width - minimum, max(0, x + delta))
            result.width = x + width - result.x
        case .right:
            let minimum = min(0.002, width)
            result.width = min(1 - x, max(minimum, width + delta))
        case .top:
            let minimum = min(0.002, height)
            result.y = min(y + height - minimum, max(0, y + delta))
            result.height = y + height - result.y
        case .bottom:
            let minimum = min(0.002, height)
            result.height = min(1 - y, max(minimum, height + delta))
        }
        return result
    }
}

nonisolated enum FilmCropEdge: Hashable, CaseIterable, Sendable { case left, right, top, bottom }

nonisolated struct FilmFrame: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var crop = FilmRect()
    var rotation = 0.0
    var valid: Bool { crop.valid && rotation.isFinite && (-360...360).contains(rotation) }
}

nonisolated struct FilmProject: Codable, Equatable, Sendable {
    /// Detection and manual drawing share this project-size ceiling.
    static let maximumFrames = 1000

    var version = 1
    var sourcePath = ""
    var bookmark: Data?
    var inputSpace = "sRGB"
    // Keep input ICC interpretation for faithful export. Codable ignores legacy grading
    // keys, so old projects reopen with geometry only; saving drops those removed keys.
    var inputProfile: Data?
    var frames: [FilmFrame] = []
    var exportJPEG = false
    var jpegQuality = 0.95
    /// Advance numeric labels so removals and custom names do not duplicate a surviving frame's number.
    var nextFrameName: String {
        let numbers = Set(frames.compactMap { Int($0.name) }.filter { $0 > 0 })
        let (next, overflow) = (numbers.max() ?? 0).addingReportingOverflow(1)
        // Names are editable; even Int.max must not overflow. There is always a free
        // positive number within numbers.count + 1 when the largest label is exhausted.
        let number = overflow ? (1...(numbers.count + 1)).first { !numbers.contains($0) }! : next
        return number < 10 ? "0\(number)" : String(number)
    }
    var valid: Bool {
        version == 1 && ["sRGB", "Adobe RGB", "Linear sRGB", "Display P3", "Custom ICC"].contains(inputSpace) && (inputSpace != "Custom ICC" || inputProfile != nil) && frames.count <= Self.maximumFrames &&
        Set(frames.map(\.id)).count == frames.count && frames.allSatisfy(\.valid) && jpegQuality.isFinite && (0.1...1).contains(jpegQuality)
    }
}

/// Observe the app preference so desktop labels refresh alongside the calculator.
@MainActor func filmText(_ chinese: String, _ english: String) -> String {
    let language = AppLanguagePreference.shared.language
    return filmText(chinese, english, language: language)
}

/// Background rendering reads the saved preference without accessing UI observation.
nonisolated func filmText(_ chinese: String, _ english: String, language: AppLanguage) -> String {
    let translated = language.bundle.localizedString(forKey: english, value: english, table: nil)
    if translated != english { return translated }
    return language == .simplifiedChinese ? chinese : english
}

nonisolated struct FilmFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
#endif

#if os(iOS)
import SwiftUI

/// All windows share look intensity. The source, calibration and selected look stay local.
@MainActor @Observable
final class FilmLookPreferences {
    static let shared = FilmLookPreferences()
    private let defaults: UserDefaults
    private let key = "fffilm.film-look-strengths.v1"
    private var values: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = (defaults.dictionary(forKey: key) as? [String: Double] ?? [:])
            .filter { (0...1).contains($0.value) }
    }

    subscript(_ look: CameraFilmLook) -> Double {
        get { values[look.rawValue] ?? 1 }
        set {
            guard (0...1).contains(newValue), newValue != self[look] else { return }
            values[look.rawValue] = newValue
            defaults.set(values, forKey: key)
        }
    }
}
#endif

import Foundation
import Observation

/// One added recording plan. Only settings are stored; results are recomputed so catalog
/// corrections also apply to entries saved before them.
struct SummaryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let settings: CaptureSettings
    let added: Date
}

/// An entry with its current calculation, for display, totals and copying.
struct SummaryItem: Identifiable {
    let entry: SummaryEntry
    let calculation: Calculation
    var id: UUID { entry.id }
}

/// The shooting-day summary. Every added setup counts toward the total, including identical
/// formats on different cameras, so entries are never deduplicated or capped.
@Observable
final class RecordingSummary {
    static let key = "fffilm.recording-summary-v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine: CalculatorEngine
    private(set) var entries: [SummaryEntry]

    private struct Payload: Codable {
        var version = 1
        var entries: [SummaryEntry]
    }

    init(defaults: UserDefaults, engine: CalculatorEngine) {
        self.defaults = defaults
        self.engine = engine
        entries = Self.load(defaults, engine: engine)
    }

    /// Picks up edits made by another window before this one changes the shared list.
    func refresh() {
        entries = Self.load(defaults, engine: engine)
    }

    func add(_ settings: CaptureSettings) {
        refresh()
        entries.append(SummaryEntry(id: UUID(), settings: engine.normalized(settings), added: .now))
        persist()
    }

    func remove(_ id: UUID) {
        refresh()
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Payload(entries: entries)) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Unknown versions and corrupt payloads read as empty; entries for cameras the catalog
    /// no longer contains are dropped rather than silently recalculated as another camera.
    private static func load(_ defaults: UserDefaults, engine: CalculatorEngine) -> [SummaryEntry] {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else { return [] }
        var ids = Set<UUID>()
        return payload.entries.compactMap { entry in
            guard ids.insert(entry.id).inserted,
                  engine.catalog.cameras.contains(where: { $0.id == entry.settings.cameraId }) else { return nil }
            return SummaryEntry(id: entry.id, settings: engine.normalized(entry.settings), added: entry.added)
        }
    }
}

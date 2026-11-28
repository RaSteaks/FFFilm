import Foundation
import Observation

/// Values printed on the handoff remain readable if a future catalog retires a mode.
struct RecordingSnapshot: Codable, Hashable {
    let cameraName, modeLabel, resolutionLabel, codecName, mediaLabel: String
    let captureFps, sensorGbPerHour, sensorMbps, captureRuntimeHours: Double
    var dayTotalGb: Double
    let standalone: Bool
    let unit: StorageUnit
    let basis: String
    var catalogRevision: String?
    var reconstructed: Bool?

    init(_ value: Calculation, unit: StorageUnit) {
        cameraName = value.camera.name; modeLabel = value.mode.label; resolutionLabel = value.resolution.label
        codecName = value.codec.name; mediaLabel = value.media.label; captureFps = value.captureFps
        sensorGbPerHour = value.sensorGbPerHour; sensorMbps = value.sensorMbps
        captureRuntimeHours = value.captureRuntimeHours; dayTotalGb = value.dayTotalGb
        standalone = value.camera.isStandaloneProRes; self.unit = unit; basis = value.rateBasis
        catalogRevision = CatalogData.referenceRevision
    }
}

struct SummaryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var settings: CaptureSettings
    let added: Date
    var rig: String?
    var snapshot: RecordingSnapshot?
    var cardAllocation: Bool?
}

struct SummaryItem: Identifiable {
    let entry: SummaryEntry
    let calculation: RecordingSnapshot
    var id: UUID { entry.id }
}

struct ShootingDay: Codable, Identifiable, Equatable {
    let id: UUID
    var project: String
    let date: Date
    var archivedUnit: StorageUnit?
    var followsCalendar: Bool?
    var title: String { [project, date.formatted(date: .abbreviated, time: .omitted)].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// Store each immutable estimate separately. An addition updates one row and the day's index;
/// opening another window or Siri reads the same index, including changes from other processes.
@Observable final class RecordingSummary {
    static let key = "fffilm.recording-summary-v1"
    static let daysKey = "fffilm.recording-days-v2"
    static let didChange = Notification.Name("FFFilmRecordingSummaryDidChange")
    private struct Book: Codable { var days: [ShootingDay]; var active: UUID; var accessed: Date }
    private struct Legacy: Codable { let version: Int; let entries: [SummaryEntry] }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine: CalculatorEngine
    @ObservationIgnored private var observer: NSObjectProtocol?
    private(set) var days: [ShootingDay] = []
    private(set) var activeDay: ShootingDay
    private(set) var entries: [SummaryEntry] = []
    private(set) var totalGb = 0.0
    @ObservationIgnored private var lastRevision: String?
    private let revisionKey = "fffilm.recording-revision-v2"
    @ObservationIgnored private var refreshedDate = Date.now

    private func refreshBeforeWrite() {
        if lastRevision != defaults.string(forKey: revisionKey) || !Calendar.current.isDateInToday(refreshedDate) { refresh() }
    }
    private var indexKey: String { "fffilm.recording-index." + activeDay.id.uuidString }
    private func rowKey(_ id: UUID) -> String { "fffilm.recording-entry." + id.uuidString }
    var items: [SummaryItem] { entries.compactMap { entry in entry.snapshot.map { SummaryItem(entry: entry, calculation: $0) } } }

    init(defaults: UserDefaults, engine: CalculatorEngine) {
        self.defaults = defaults; self.engine = engine
        activeDay = ShootingDay(id: UUID(), project: "", date: .now)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: Self.didChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as AnyObject? !== self,
                      note.userInfo?["defaults"] as AnyObject? === self.defaults else { return }
                self.refresh()
            }
        }
    }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh() {
        lastRevision = defaults.string(forKey: revisionKey); refreshedDate = .now
        if let data = defaults.data(forKey: Self.daysKey),
           let book = try? JSONDecoder().decode(Book.self, from: data),
           let day = book.days.first(where: { $0.id == book.active }) {
            days = book.days; activeDay = day
            if day.followsCalendar != false, !Calendar.current.isDateInToday(book.accessed) {
                newDay(project: day.project, date: .now, followsCalendar: true)
                return
            }
        } else {
            days = [activeDay]
            if let data = defaults.data(forKey: Self.key),
               let legacy = try? JSONDecoder().decode(Legacy.self, from: data), legacy.version == 1 {
                // v1 recorded inputs only. Preserve unknown camera IDs for manual reconciliation.
                var ids = Set<UUID>()
                let today = activeDay
                let grouped = Dictionary(grouping: legacy.entries.filter { ids.insert($0.id).inserted }) {
                    Calendar.current.startOfDay(for: $0.added)
                }
                for date in grouped.keys.sorted() {
                    if Calendar.current.isDateInToday(date) { activeDay = today }
                    else {
                        activeDay = ShootingDay(id: UUID(), project: "", date: date, archivedUnit: storedUnit)
                        days.append(activeDay)
                    }
                    entries = grouped[date, default: []].map { original in
                        var entry = original
                        let settings = entry.settings
                        let result = engine.calculate(settings: settings)
                        if entry.snapshot == nil, result.hasEstimate, engine.normalized(settings) == settings {
                            entry.snapshot = RecordingSnapshot(result, unit: storedUnit)
                            entry.snapshot?.reconstructed = true
                        }
                        write(entry)
                        return entry
                    }
                    writeIndex()
                }
                activeDay = today
            }
            writeBook()
        }
        readEntries()
    }

    private func readEntries() {
        let ids = defaults.stringArray(forKey: indexKey) ?? []
        entries = ids.compactMap { id in
            guard let uuid = UUID(uuidString: id), let data = defaults.data(forKey: rowKey(uuid)) else { return nil }
            return try? JSONDecoder().decode(SummaryEntry.self, from: data)
        }
        totalGb = entries.reduce(0) { $0 + ($1.snapshot?.dayTotalGb ?? 0) }
    }

    private var storedUnit: StorageUnit {
        defaults.string(forKey: StorageUnit.preferenceKey).flatMap(StorageUnit.init(rawValue:)) ?? .decimal
    }

    func newDay(project: String, date: Date, followsCalendar: Bool = false) {
        // Starting a new sheet seals the previous handoff, including its presentation unit.
        for index in days.indices where days[index].archivedUnit == nil { days[index].archivedUnit = storedUnit }
        activeDay = ShootingDay(id: UUID(), project: project.trimmingCharacters(in: .whitespacesAndNewlines), date: date, followsCalendar: followsCalendar)
        days.append(activeDay); entries = []; totalGb = 0
        writeBook(); notify()
    }

    func renameDay(_ name: String) {
        guard activeDay.archivedUnit == nil else { return }
        refreshBeforeWrite()
        guard let i = days.firstIndex(where: { $0.id == activeDay.id }) else { return }
        activeDay.project = name.trimmingCharacters(in: .whitespacesAndNewlines)
        days[i] = activeDay; writeBook(); notify()
    }

    func selectDay(_ day: ShootingDay) {
        guard let stored = days.first(where: { $0.id == day.id }) else { return }
        // Browsing an archive is local; other operators and Siri continue using the open day.
        activeDay = stored
        readEntries()
    }

    func add(_ settings: CaptureSettings, card: Bool = false, rig: String = "") {
        guard activeDay.archivedUnit == nil else { return }
        refreshBeforeWrite()
        let result = engine.calculate(settings: settings)
        guard result.hasEstimate else { return }
        var snapshot = RecordingSnapshot(result, unit: storedUnit)
        var saved = settings
        if card {
            // Allocate the visible card's nominal capacity, even when its runtime exceeds 24 hours.
            snapshot.dayTotalGb = result.media.capacityGb
            saved.shootHours = result.captureRuntimeHours
        }
        let entry = SummaryEntry(id: UUID(), settings: saved, added: .now, rig: rig, snapshot: snapshot, cardAllocation: card)
        write(entry); entries.append(entry); totalGb += snapshot.dayTotalGb
        writeIndex(); notify()
    }

    func edit(_ id: UUID, rig: String, hours: Double) {
        guard activeDay.archivedUnit == nil else { return }
        refreshBeforeWrite()
        guard let index = entries.firstIndex(where: { $0.id == id }), var snapshot = entries[index].snapshot else { return }
        if entries[index].cardAllocation != true {
            guard hours.isFinite, CaptureSettings.shootHoursRange.contains(hours) else { return }
            totalGb -= snapshot.dayTotalGb
            snapshot.dayTotalGb = hours * snapshot.sensorGbPerHour
            entries[index].settings.shootHours = hours
            entries[index].snapshot = snapshot; totalGb += snapshot.dayTotalGb
        }
        entries[index].rig = rig; write(entries[index]); notify()
    }

    func remove(_ id: UUID) {
        guard activeDay.archivedUnit == nil else { return }
        refreshBeforeWrite()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        totalGb -= entries.remove(at: index).snapshot?.dayTotalGb ?? 0
        if entries.isEmpty { totalGb = 0 }
        writeIndex(); defaults.removeObject(forKey: rowKey(id)); notify()
    }

    func clear() {
        guard activeDay.archivedUnit == nil else { return }
        refreshBeforeWrite()
        let removed = entries
        entries = []; totalGb = 0; writeIndex()
        for entry in removed { defaults.removeObject(forKey: rowKey(entry.id)) }
        notify()
    }

    private func write(_ entry: SummaryEntry) {
        if let data = try? JSONEncoder().encode(entry) { defaults.set(data, forKey: rowKey(entry.id)) }
    }
    private func writeBook() {
        if let data = try? JSONEncoder().encode(Book(days: days, active: activeDay.id, accessed: .now)) {
            defaults.set(data, forKey: Self.daysKey)
        }
    }
    private func writeIndex() { defaults.set(entries.map { $0.id.uuidString }, forKey: indexKey) }
    private func notify() {
        lastRevision = UUID().uuidString
        defaults.set(lastRevision, forKey: revisionKey)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["defaults": defaults])
    }
}

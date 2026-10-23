import Foundation
import Observation

enum ShutterRigID: String, CaseIterable, Codable, Identifiable {
    case a = "A", b = "B", c = "C"
    var id: String { rawValue }
}

struct ShutterRig: Codable, Equatable, Identifiable {
    let id: ShutterRigID
    var cameraLabel = ""
    var settings: ShutterSettings
}

/// A snapshot binds notes and user-reported field checks to the exact settings checked.
/// Restoring it never certifies a new lighting environment or changes the calculation model.
struct ShutterRecord: Codable, Hashable, Identifiable {
    let id: UUID
    let rig: ShutterRigID
    var title: String
    let cameraLabel: String
    let settings: ShutterSettings
    var date: Date
    var fieldChecked = false
    var conditions = ""

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ShutterSettingsMemory(settings: settings).isValid
            && (!fieldChecked || !conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && date.timeIntervalSince1970.isFinite
    }

    func matches(_ other: Self) -> Bool {
        rig == other.rig && cameraLabel == other.cameraLabel && settings == other.settings
    }
}

@Observable
final class ShutterWorkspace {
    static let rigsKey = "fffilm.shutter-rigs-v1"
    static let libraryKey = "fffilm.shutter-library-v1"
    static let recentLimit = 12
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var selectedRig: ShutterRigID
    private(set) var rigs: [ShutterRig]
    private(set) var recent: [ShutterRecord]
    private(set) var saved: [ShutterRecord]

    private struct RigMemory: Codable {
        var version = 1
        var selected: ShutterRigID
        var rigs: [ShutterRig]
        var isValid: Bool {
            version == 1 && rigs.count == ShutterRigID.allCases.count
                && Set(rigs.map(\.id)).count == rigs.count
                && rigs.allSatisfy { ShutterSettingsMemory(settings: $0.settings).isValid }
        }
    }
    private struct Library: Codable {
        var version = 1
        var recent: [ShutterRecord] = []
        var saved: [ShutterRecord] = []
    }

    init(defaults: UserDefaults, migrating settings: ShutterSettings) {
        self.defaults = defaults
        let memory = defaults.data(forKey: Self.rigsKey)
            .flatMap { try? JSONDecoder().decode(RigMemory.self, from: $0) }
        if let memory, memory.isValid {
            selectedRig = memory.selected; rigs = memory.rigs
        } else {
            selectedRig = .a
            rigs = ShutterRigID.allCases.map { ShutterRig(id: $0, settings: $0 == .a ? settings : .default) }
        }
        let library = Self.loadLibrary(defaults)
        recent = library.recent; saved = library.saved
    }

    var active: ShutterRig { rigs.first { $0.id == selectedRig }! }

    func select(_ id: ShutterRigID) {
        // Refresh the incoming slot only; another window's current editor remains independent.
        if let data = defaults.data(forKey: Self.rigsKey),
           let latest = try? JSONDecoder().decode(RigMemory.self, from: data), latest.isValid,
           let incoming = latest.rigs.first(where: { $0.id == id }),
           let index = rigs.firstIndex(where: { $0.id == id }) { rigs[index] = incoming }
        selectedRig = id
        persistActiveRig()
    }

    func update(settings: ShutterSettings, cameraLabel: String? = nil) {
        guard ShutterSettingsMemory(settings: settings).isValid,
              let index = rigs.firstIndex(where: { $0.id == selectedRig }) else { return }
        rigs[index].settings = settings
        if let cameraLabel { rigs[index].cameraLabel = cameraLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
        persistActiveRig()
    }

    private func persistActiveRig() {
        var memory = defaults.data(forKey: Self.rigsKey)
            .flatMap { try? JSONDecoder().decode(RigMemory.self, from: $0) }
        if memory?.isValid != true { memory = RigMemory(selected: selectedRig, rigs: rigs) }
        guard var memory, let index = memory.rigs.firstIndex(where: { $0.id == selectedRig }) else { return }
        // Merge only the edited slot so a stale window cannot overwrite another rig's setup.
        memory.rigs[index] = active
        memory.selected = selectedRig
        if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: Self.rigsKey) }
    }

    func refreshLibrary() {
        let latest = Self.loadLibrary(defaults)
        recent = latest.recent; saved = latest.saved
    }

    func remember(_ record: ShutterRecord) {
        guard record.isValid else { return }
        refreshLibrary()
        if recent.first?.matches(record) == true { return }
        recent.removeAll { $0.matches(record) }
        recent.insert(record, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        persistLibrary()
    }

    func save(_ record: ShutterRecord) {
        guard record.isValid else { return }
        refreshLibrary()
        saved.removeAll { $0.id == record.id }
        saved.insert(record, at: 0)
        persistLibrary()
    }

    func deleteSaved(_ id: UUID) {
        refreshLibrary()
        saved.removeAll { $0.id == id }
        persistLibrary()
    }

    private func persistLibrary() {
        if let data = try? JSONEncoder().encode(Library(recent: recent, saved: saved)) {
            defaults.set(data, forKey: Self.libraryKey)
        }
    }

    private static func loadLibrary(_ defaults: UserDefaults) -> Library {
        guard let data = defaults.data(forKey: libraryKey),
              var library = try? JSONDecoder().decode(Library.self, from: data), library.version == 1 else { return Library() }
        func valid(_ records: [ShutterRecord]) -> [ShutterRecord] {
            var ids = Set<UUID>()
            return records.filter { $0.isValid && ids.insert($0.id).inserted }
        }
        library.recent = Array(valid(library.recent).prefix(recentLimit))
        library.saved = valid(library.saved)
        return library
    }
}

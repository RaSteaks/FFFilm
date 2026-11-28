#if os(macOS)
import Foundation
import CoreGraphics

nonisolated enum FilmExportScope: String, CaseIterable, Sendable {
    case current, checked, all, strip
}

nonisolated enum FilmExportFormat: String, CaseIterable, Sendable {
    case tiff, jpeg
    var fileExtension: String { self == .tiff ? "tiff" : "jpg" }
}

nonisolated enum FilmExportNaming: String, CaseIterable, Sendable {
    case frameName, sequence
}

nonisolated enum FilmExportCollision: String, CaseIterable, Sendable {
    case keepBoth, skip
}

/// Window-local draft. Changing export options must not enter the geometry undo stack.
nonisolated struct FilmExportSettings: Equatable, Sendable {
    var scope: FilmExportScope?
    var format: FilmExportFormat = .tiff
    var qualityPercent = 95
    var prefix = ""
    var naming: FilmExportNaming = .frameName
    var startNumber = 1
    var digits = 3
    var collision: FilmExportCollision = .keepBoth
}

nonisolated struct FilmExportItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { (sourceID?.uuidString ?? "") + (frame?.id.uuidString ?? "strip") }
    var sourceID: UUID? = nil
    let frame: FilmFrame?
    let fileName: String
    let pixelSize: CGSize
    let skipped: Bool
}

/// One inventory per destination folder and per preview. Share it across scans in flat
/// exports. The final move still refuses a collision that appeared after the preview.
@MainActor final class FilmExportNames {
    private var taken: Set<String>
    private var suffixes: [String: Int] = [:]

    init(directory: URL?) throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            taken = Set(files.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        } else { taken = [] }
    }

    func reserve(stem: String, extension ext: String, collision: FilmExportCollision) -> (name: String, skipped: Bool) {
        let base = stem + "." + ext
        let key = base.precomposedStringWithCanonicalMapping.lowercased()
        if taken.insert(key).inserted { return (base, false) }
        if collision == .skip { return (base, true) }
        var suffix = suffixes[key] ?? 1
        while true {
            suffix += 1
            let name = "\(stem) (\(suffix)).\(ext)"
            if taken.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                suffixes[key] = suffix
                return (name, false)
            }
        }
    }
}

/// A plan is also the naming preview. The same immutable items become the export job.
nonisolated struct FilmExportPlan: Sendable {
    let project: FilmProject
    let directory: URL?
    let items: [FilmExportItem]
    var sources: [UUID: FilmExportSource] = [:]
    var messages: [String] = []
    var estimatedBytes: Double {
        items.lazy.filter { !$0.skipped }.reduce(0) { total, item in
            let jpeg = item.sourceID.flatMap { sources[$0]?.project.exportJPEG } ?? project.exportJPEG
            // JPEG compression depends on content; show the uncompressed working estimate.
            return total + Double(item.pixelSize.width * item.pixelSize.height) * (jpeg ? 4 : 8)
        }
    }
    var outputCount: Int { items.filter { !$0.skipped }.count }

    @MainActor static func make(project: FilmProject, selected: UUID?, checked: Set<UUID>,
                                sourceSize: CGSize, settings: FilmExportSettings, directory: URL?,
                                names sharedNames: FilmExportNames? = nil, requireExistingDirectory: Bool = true) throws -> Self {
        let prefix = settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateComponent(prefix)
        guard (2...4).contains(settings.digits),
              (1...9999).contains(settings.startNumber),
              (10...100).contains(settings.qualityPercent) else {
            throw FilmFailure(message: filmText("导出编号或质量参数无效。", "Invalid export numbering or quality."))
        }
        let frames: [FilmFrame?]
        switch settings.scope ?? (checked.isEmpty ? .current : .checked) {
        case .current: frames = project.frames.filter { $0.id == selected }.map(Optional.some)
        case .checked: frames = project.frames.filter { checked.contains($0.id) }.map(Optional.some)
        case .all: frames = project.frames.map(Optional.some)
        case .strip: frames = [nil]
        }
        guard !frames.isEmpty else {
            throw FilmFailure(message: filmText("请选择要导出的帧。", "Select frames to export."))
        }
        let access = directory?.startAccessingSecurityScopedResource() ?? false
        defer { if access { directory?.stopAccessingSecurityScopedResource() } }
        if let directory, requireExistingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FilmFailure(message: filmText("导出文件夹不可用，请重新选择。", "The export folder is unavailable. Choose it again."))
            }
        }
        let names = try sharedNames ?? FilmExportNames(directory: directory)
        var items: [FilmExportItem] = []
        for (index, frame) in frames.enumerated() {
            var token = frame.map {
                settings.naming == .sequence ? String(settings.startNumber + index)
                    : $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? "strip"
            try validateComponent(token)
            if token.allSatisfy({ $0.isASCII && $0.isNumber }) {
                token = String(repeating: "0", count: max(0, settings.digits - token.count)) + token
            }
            let stem = prefix + "_" + token
            let (name, skipped) = names.reserve(stem: stem, extension: settings.format.fileExtension, collision: settings.collision)
            guard name.utf8.count <= 255 else {
                throw FilmFailure(message: filmText("文件名过长，请缩短前缀或帧名称。", "The filename is too long. Shorten the prefix or frame name."))
            }
            let size = FilmZoom.sourceSize(width: Int(sourceSize.width), height: Int(sourceSize.height), frame: frame)
            items.append(FilmExportItem(frame: frame, fileName: name, pixelSize: size, skipped: skipped))
        }
        var snapshot = project
        snapshot.exportJPEG = settings.format == .jpeg
        snapshot.jpegQuality = Double(settings.qualityPercent) / 100
        return Self(project: snapshot, directory: directory, items: items)
    }

    @MainActor static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255, value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains("/"), !value.contains("\\"), !value.contains(":") else {
            throw FilmFailure(message: filmText("前缀和帧名称不能为空，且不能包含路径分隔符、冒号或控制字符。",
                                               "Prefixes and frame names must be nonempty and cannot contain path separators, colons or control characters."))
        }
    }
}

nonisolated struct FilmExportResult: Codable, Equatable, Identifiable, Sendable {
    enum Status: Codable, Equatable, Sendable {
        case pending, succeeded, skipped, failed(String)
    }
    var id: String { item.id }
    let item: FilmExportItem
    var status: Status
    var writtenFile: FilmSourceIdentity?
}

nonisolated struct FilmExportJob: Codable, Equatable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable { case running, cancelled, finished }
    private(set) var id = UUID()
    let project: FilmProject
    let sourceIdentifier: UUID
    var directory: URL
    var results: [FilmExportResult]
    var sources: [UUID: FilmExportSource] = [:]
    var phase = Phase.running
    var directoryBookmark: Data?
    var deferredSources: [String]?
    var activeFileName: String?
    var activeSourceID: UUID?
    var completedCount: Int { results.filter { $0.status == .succeeded }.count }
    var skippedCount: Int { results.filter { $0.status == .skipped }.count }
    var failedCount: Int { results.filter { if case .failed = $0.status { true } else { false } }.count }
    var pendingCount: Int { results.filter { $0.status == .pending }.count }
    var processedCount: Int { results.count - pendingCount }
    /// Files can be large or remote. Read only sampled signatures off the main actor.
    /// Each changed entry carries whether a conflicting file still exists at its path.
    func checkPublishedFiles(at folder: URL) -> [(Int, Bool)]? {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else { return nil }
        var changes: [(Int, Bool)] = []
        for (index, result) in results.enumerated() where result.status == .succeeded {
            let output = folder.appendingPathComponent(result.item.fileName)
            let present = FileManager.default.fileExists(atPath: output.path)
            if !present || result.writtenFile == nil || (try? FilmSourceIdentity.read(output, width: 0, height: 0)) != result.writtenFile {
                changes.append((index, present))
            }
        }
        return changes
    }

    var completedURLs: [URL] {
        results.filter { $0.status == .succeeded }.map { directory.appendingPathComponent($0.item.fileName) }
    }
}

/// The source and geometry are captured at confirmation, independent of editor navigation.
nonisolated struct FilmExportSource: Codable, Equatable, Sendable {
    let id: UUID
    var project: FilmProject
    let selected: UUID?
    let checked: Set<UUID>
    let size: CGSize
    let reviewed: Bool
}

extension FilmExportPlan {
    @MainActor static func makeBatch(sources: [FilmExportSource], settings: FilmExportSettings,
                                     organization: FilmFileOrganization, useSourceNames: Bool,
                                     directory: URL?) throws -> Self {
        let access = directory?.startAccessingSecurityScopedResource() ?? false
        defer { if access { directory?.stopAccessingSecurityScopedResource() } }
        if let directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FilmFailure(message: filmText("导出文件夹不可用，请重新选择。", "The export folder is unavailable. Choose it again."))
            }
        }
        var items: [FilmExportItem] = []
        var snapshots: [UUID: FilmExportSource] = [:]
        var messages: [String] = []
        var folders: Set<String> = []
        var inventories: [String: FilmExportNames] = [:]
        for source in sources {
            let name = URL(fileURLWithPath: source.project.sourcePath).deletingPathExtension().lastPathComponent
            if settings.scope == .checked && source.checked.isEmpty || settings.scope != .strip && source.project.frames.isEmpty {
                messages.append(name + ": " + filmText("没有符合范围的帧，跳过。", "No frames in this range; skipped."))
                continue
            }
            var folder = ""
            if organization == .folders {
                try validateComponent(name)
                folder = name
                var suffix = 1
                // Reuse an existing folder, but separate same-named sources within this batch.
                // A regular file at a folder path must never be replaced.
                func unavailable(_ value: String) -> Bool {
                    if folders.contains(value.precomposedStringWithCanonicalMapping.lowercased()) { return true }
                    guard let directory else { return false }
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent(value).path, isDirectory: &isDirectory)
                    return exists && !isDirectory.boolValue
                }
                while unavailable(folder) { suffix += 1; folder = "\(name) (\(suffix))" }
                try validateComponent(folder)
                folders.insert(folder.precomposedStringWithCanonicalMapping.lowercased())
            }
            var options = settings
            if useSourceNames { options.prefix = name }
            let destination = folder.isEmpty ? directory : directory?.appendingPathComponent(folder, isDirectory: true)
            let names = try inventories[folder] ?? FilmExportNames(directory: destination)
            inventories[folder] = names
            let plan = try make(project: source.project, selected: source.selected, checked: source.checked,
                                sourceSize: source.size, settings: options, directory: destination,
                                names: names, requireExistingDirectory: false)
            var snapshot = source; snapshot.project = plan.project; snapshots[source.id] = snapshot
            for item in plan.items {
                items.append(FilmExportItem(sourceID: source.id, frame: item.frame,
                                            fileName: folder.isEmpty ? item.fileName : folder + "/" + item.fileName,
                                            pixelSize: item.pixelSize, skipped: item.skipped))
            }
        }
        let unchecked = sources.filter { !$0.reviewed }.count
        if unchecked > 0 { messages.insert(String(format: filmText("%d 条胶片尚未检查。", "%d scans have not been reviewed."), unchecked), at: 0) }
        return Self(project: FilmProject(), directory: directory, items: items, sources: snapshots, messages: messages.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
    }
}

#endif

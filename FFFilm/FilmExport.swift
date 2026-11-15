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

nonisolated struct FilmExportItem: Identifiable, Equatable, Sendable {
    var id: String { (sourceID?.uuidString ?? "") + (frame?.id.uuidString ?? "strip") }
    var sourceID: UUID? = nil
    let frame: FilmFrame?
    let fileName: String
    let pixelSize: CGSize
    let skipped: Bool
}

/// A plan is also the naming preview. The same immutable items become the export job.
nonisolated struct FilmExportPlan: Sendable {
    let project: FilmProject
    let directory: URL?
    let items: [FilmExportItem]
    var sources: [UUID: FilmExportSource] = [:]
    var messages: [String] = []
    var outputCount: Int { items.filter { !$0.skipped }.count }

    @MainActor static func make(project: FilmProject, selected: UUID?, checked: Set<UUID>,
                                sourceSize: CGSize, settings: FilmExportSettings, directory: URL?,
                                reservedNames: Set<String> = [], requireExistingDirectory: Bool = true) throws -> Self {
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
        // Reserve names within the batch as well as on disk. Case folding also keeps
        // the preview safe on the usual case-insensitive macOS destination volumes.
        var reserved = reservedNames
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
            var suffix = 1
            var name = stem + "." + settings.format.fileExtension
            func exists(_ name: String) -> Bool {
                reserved.contains(name.precomposedStringWithCanonicalMapping.lowercased())
                    || directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } == true
            }
            let skipped = settings.collision == .skip && exists(name)
            if !skipped {
                while exists(name) {
                    suffix += 1
                    name = "\(stem) (\(suffix)).\(settings.format.fileExtension)"
                }
                reserved.insert(name.precomposedStringWithCanonicalMapping.lowercased())
            }
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

nonisolated struct FilmExportResult: Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        case pending, succeeded, skipped, failed(String)
    }
    var id: String { item.id }
    let item: FilmExportItem
    var status: Status
}

nonisolated struct FilmExportJob: Identifiable, Sendable {
    enum Phase: Sendable { case running, cancelled, finished }
    let id = UUID()
    let project: FilmProject
    let sourceIdentifier: UUID
    let directory: URL
    var results: [FilmExportResult]
    var sources: [UUID: FilmExportSource] = [:]
    var phase = Phase.running
    var activeFileName: String?
    var activeSourceID: UUID?
    var completedCount: Int { results.filter { $0.status == .succeeded }.count }
    var skippedCount: Int { results.filter { $0.status == .skipped }.count }
    var failedCount: Int { results.filter { if case .failed = $0.status { true } else { false } }.count }
    var pendingCount: Int { results.filter { $0.status == .pending }.count }
    var processedCount: Int { results.count - pendingCount }
    var completedURLs: [URL] {
        results.filter { $0.status == .succeeded }.map { directory.appendingPathComponent($0.item.fileName) }
    }
}

/// The source and geometry are captured at confirmation, independent of editor navigation.
nonisolated struct FilmExportSource: Sendable {
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
        var reserved: [String: Set<String>] = [:]
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
            let plan = try make(project: source.project, selected: source.selected, checked: source.checked,
                                sourceSize: source.size, settings: options, directory: destination,
                                reservedNames: reserved[folder, default: []], requireExistingDirectory: false)
            var snapshot = source; snapshot.project = plan.project; snapshots[source.id] = snapshot
            for item in plan.items {
                if !item.skipped { reserved[folder, default: []].insert(item.fileName.precomposedStringWithCanonicalMapping.lowercased()) }
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

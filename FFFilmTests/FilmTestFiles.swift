#if os(macOS)
import Foundation

/// XCTest's sandbox overrides TMPDIR. An explicit optional root keeps generated film
/// fixtures with a requested validation run; ordinary test runs retain system isolation.
nonisolated enum FilmTestFiles {
    static func directory() throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["FFFILM_TEST_ARTIFACT_ROOT"] else {
            return FileManager.default.temporaryDirectory
        }
        let directory = URL(fileURLWithPath: root, isDirectory: true).appending(path: "unit-fixtures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif

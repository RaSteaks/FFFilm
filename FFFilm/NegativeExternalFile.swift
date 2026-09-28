#if os(iOS)
import Foundation

/// A system-opened URL can outlive the event callback or wait for an active Photos
/// transaction. Balance its security scope only after that deferred import releases it.
nonisolated final class NegativeExternalFile: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}
#endif

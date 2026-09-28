#if os(iOS)
import Photos

/// Add-only access keeps saving independent from permission to read existing photos.
@MainActor
protocol NegativePhotoSaving {
    func requestAccess() async -> Bool
    func save(_ file: URL) async throws
}

struct NegativePhotoLibrary: NegativePhotoSaving {
    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized
    }

    func save(_ file: URL) async throws {
        // Photos reads the original encoded file. The caller retains it until this
        // transaction completes; do not move/delete it while Photos is importing.
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
        }
    }
}
#endif

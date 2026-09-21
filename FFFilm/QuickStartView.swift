import SwiftUI

/// The calculator only selects favorites; all catalog and editing actions live on the camera page.
struct QuickStartView: View {
    let store: CalculatorStore
    @State private var showsCameras = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        preset("PRORES", id: "apple-prores", selected: store.currentCamera.isStandaloneProRes)
                        ForEach(store.quickStartCameras) { camera in
                            preset(camera.name, id: camera.id, selected: camera.id == store.settings.cameraId)
                                .accessibilityIdentifier("quick-camera-\(camera.id)")
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 2, for: .scrollContent)

                // Catalog access stays visible even when many favorites extend beyond the screen.
                Button("CAMERAS", systemImage: "camera") { showsCameras = true }
                    .buttonStyle(PresetButtonStyle(selected: false))
                    .fixedSize()
                    .accessibilityLabel("Browse cameras and manage favorites")
                    .accessibilityIdentifier("camera-library")
            }
            if store.quickStartCameras.isEmpty {
                Text("Add favorites in CAMERAS to show them here.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Favorite cameras")
        .accessibilityIdentifier("quick-start")
        .sheet(isPresented: $showsCameras) { CameraLibraryView(store: store) }
    }

    private func preset(_ title: String, id: String, selected: Bool) -> some View {
        Button(title) { store.selectCamera(id) }
            .buttonStyle(PresetButtonStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

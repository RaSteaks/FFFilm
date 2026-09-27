import SwiftUI

/// The calculator only selects favorites; all catalog and editing actions live on the camera page.
struct QuickStartView: View {
    let store: CalculatorStore
    // The root presents the library outside the iOS tab bar's size-class override.
    @Binding var showsCameras: Bool

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
                Button("nav.cameras", systemImage: "camera") { showsCameras = true }
                    .buttonStyle(PresetButtonStyle(selected: false))
                    .fixedSize()
                    .accessibilityLabel(Text("camera.browseHint"))
                    .accessibilityIdentifier("camera-library")
            }
            if store.quickStartCameras.isEmpty {
                Text("camera.emptyFavorites")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("nav.favorites"))
        .accessibilityIdentifier("quick-start")
    }

    private func preset(_ title: String, id: String, selected: Bool) -> some View {
        Button(title) { store.selectCamera(id) }
            .buttonStyle(PresetButtonStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(iOS)
import SwiftUI

/// Camera controls use discovered hardware limits.
struct NegativeCameraControls: View {
    @Bindable var store: NegativeStore

    var body: some View {
        if let configuration = store.cameraConfiguration {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("negative.camera.lens", selection: Binding(get: { store.cameraSettings.lensID ?? "" }, set: store.setCameraLens)) {
                        ForEach(configuration.lenses) { lens in
                            Text(LocalizedStringKey(lens.titleKey)).tag(lens.id)
                        }
                    }
                    .accessibilityIdentifier("negative-camera-lens")
                    Picker("negative.camera.resolution", selection: Binding(get: { store.cameraSettings.resolution }, set: store.setCameraResolution)) {
                        ForEach(configuration.resolutions) { resolution in Text(resolution.rawValue).tag(resolution) }
                    }
                    .accessibilityIdentifier("negative-camera-resolution")
                }
                .pickerStyle(.menu)
                // Focus runs continuously; the user should not have to restart it.
                if !configuration.supportsFocus {
                    Text("negative.camera.fixedFocus").font(.caption)
                }
                Text(configuration.automaticMacro ? "negative.camera.autoMacroHint" : "negative.camera.manualLensHint")
                    .font(.caption).foregroundStyle(Palette.muted)
                if configuration.minimumFocusDistance > 0 {
                    HStack {
                        Text("negative.camera.minimumDistance")
                        // AVCaptureDevice reports millimeters; the displayed unit is centimeters.
                        Text(Double(configuration.minimumFocusDistance) / 10, format: .number.precision(.fractionLength(0...1)))
                            .accessibilityIdentifier("negative-camera-minimum-distance")
                        Text("cm")
                    }.font(.caption).foregroundStyle(Palette.muted)
                }
                Text("negative.camera.settingsHint").font(.caption).foregroundStyle(Palette.muted)
            }
            // Settings live in a scrollable sheet so edits never resize the viewfinder.
            .disabled(!store.canAdjustCamera)
        }
    }
}
#endif

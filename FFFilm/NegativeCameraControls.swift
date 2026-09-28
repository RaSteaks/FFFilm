#if os(iOS)
import SwiftUI

/// Camera controls use discovered hardware limits; drafts never reconfigure capture per slider tick.
struct NegativeCameraControls: View {
    @Bindable var store: NegativeStore
    @Binding var expanded: Bool
    @State private var exposureDraft: Float = 0

    var body: some View {
        if let configuration = store.cameraConfiguration {
            VStack(spacing: 8) {
                Picker("negative.camera.tapAction", selection: $store.cameraTapSamplesBase) {
                    Text("negative.camera.tapFocus").tag(false)
                    Text("negative.camera.tapBase").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("negative-camera-tap-action")

                DisclosureGroup("negative.camera.settings", isExpanded: $expanded) {
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
                        HStack {
                            Text("negative.camera.exposure")
                            Spacer()
                            Text(exposureDraft, format: .number.precision(.fractionLength(1))).monospacedDigit()
                            Text("EV")
                            Button("negative.camera.resetExposure") { exposureDraft = 0; store.setExposureBias(0) }
                                .frame(minHeight: 44)
                        }
                        if configuration.exposureRange.lowerBound < configuration.exposureRange.upperBound {
                            Slider(value: $exposureDraft, in: configuration.exposureRange, step: 0.1) { Text("negative.camera.exposure") }
                                onEditingChanged: { editing in if !editing { store.setExposureBias(exposureDraft) } }
                                .accessibilityIdentifier("negative-camera-exposure")
                        }
                        // Focus runs continuously; the user should not have to restart it.
                        if !configuration.supportsFocus {
                            Text("negative.camera.fixedFocus").font(.caption)
                        }
                        Text(configuration.automaticMacro ? "negative.camera.autoMacroHint" : "negative.camera.manualLensHint")
                            .font(.caption).foregroundStyle(Palette.muted)
                        if configuration.minimumFocusDistance > 0 {
                            HStack {
                                Text("negative.camera.minimumDistance")
                                Text(Double(configuration.minimumFocusDistance) / 10, format: .number.precision(.fractionLength(0...1)))
                                Text("cm")
                            }.font(.caption).foregroundStyle(Palette.muted)
                        }
                        Text("negative.camera.settingsHint").font(.caption).foregroundStyle(Palette.muted)
                    }.padding(.top, 8)
                }
                // Preserve each child control's accessibility identity inside the disclosure.
                .accessibilityElement(children: .contain)
            }
            .disabled(!store.canAdjustCamera)
            .onAppear { exposureDraft = store.cameraSettings.exposureBias }
            .onChange(of: store.cameraSettings) { _, settings in exposureDraft = settings.exposureBias }
        }
    }
}
#endif

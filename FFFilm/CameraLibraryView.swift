import SwiftUI

/// One shared store keeps browsing, details, favorites and the calculator strip in sync.
struct CameraLibraryView: View {
    let store: CalculatorStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matchingCameras: [CameraProfile] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.sortedCameras.filter {
            !$0.isStandaloneProRes && (search.isEmpty ||
                "\($0.manufacturer.rawValue) \($0.name)".localizedStandardContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CameraFavoritesView(store: store)
                    } label: {
                        HStack {
                            Label("Favorites", systemImage: "star.fill")
                            Spacer()
                            Text(store.quickStartCameraIds.count.formatted())
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: Layout.controlHeight)
                    }
                    .accessibilityIdentifier("camera-favorites")
                } footer: {
                    Text("Favorites appear on RATE. Open Favorites to reorder or remove them.")
                }

                if matchingCameras.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(CameraManufacturer.allCases, id: \.self) { manufacturer in
                        let cameras = matchingCameras.filter { $0.manufacturer == manufacturer }
                        if !cameras.isEmpty {
                            Section(manufacturer.rawValue) {
                                ForEach(cameras) { camera in
                                    HStack(spacing: 12) {
                                        NavigationLink(value: camera) { CameraSummary(camera: camera) }
                                            .accessibilityIdentifier("catalog-camera-\(camera.id)")
                                        Spacer(minLength: 0)
                                        CameraFavoriteButton(store: store, camera: camera, compact: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cameras")
            .searchable(text: $query, prompt: "Camera or manufacturer")
            .navigationDestination(for: CameraProfile.self) { camera in
                CameraDetailView(store: store, camera: camera)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("camera-library-done")
                }
            }
        }
        .tint(Palette.text)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 700)
        #else
        .presentationDetents([.large])
        #endif
    }
}

private struct CameraFavoritesView: View {
    let store: CalculatorStore

    var body: some View {
        List {
            if store.quickStartCameras.isEmpty {
                ContentUnavailableView("No favorite cameras", systemImage: "star",
                    description: Text("Go back to Cameras and tap a star to add a favorite."))
            } else {
                Section {
                    ForEach(store.quickStartCameras) { camera in
                        NavigationLink(value: camera) { CameraSummary(camera: camera) }
                            .accessibilityIdentifier("favorite-camera-\(camera.id)")
                            .contextMenu { CameraOrderingActions(store: store, camera: camera) }
                            .accessibilityAction(named: "Move earlier") {
                                store.shiftQuickStart(cameraID: camera.id, forward: false)
                            }
                            .accessibilityAction(named: "Move later") {
                                store.shiftQuickStart(cameraID: camera.id, forward: true)
                            }
                            .accessibilityAction(named: "Remove favorite") {
                                store.removeQuickStart(cameraID: camera.id)
                            }
                    }
                    .onMove { store.moveQuickStarts(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        // Capture IDs before deletion so removing several rows cannot shift later indices.
                        let ids = offsets.map { store.quickStartCameraIds[$0] }
                        for id in ids { store.removeQuickStart(cameraID: id) }
                    }
                } footer: {
                    Text("Order is shared with RATE. Open a camera for details and move controls. Removing a favorite keeps the camera in the catalog.")
                }
            }
        }
        .navigationTitle("Favorites")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton().disabled(store.quickStartCameras.isEmpty)
                    .accessibilityIdentifier("camera-favorites-edit")
            }
        }
        #endif
    }
}

private struct CameraDetailView: View {
    let store: CalculatorStore
    let camera: CameraProfile

    var body: some View {
        List {
            Section {
                CameraSummary(camera: camera)
                CameraFavoriteButton(store: store, camera: camera)
            }
            if let position = store.quickStartCameraIds.firstIndex(of: camera.id) {
                Section("Favorite order · \(position + 1) of \(store.quickStartCameraIds.count)") {
                    // Visible native buttons also support users who cannot perform a drag gesture.
                    CameraOrderingActions(store: store, camera: camera, includesRemoval: false)
                }
            }
            Section("Sensor") {
                LabeledContent("Format", value: camera.sensorLabel)
                LabeledContent("Dimensions", value: "\(DisplayFormat.number(camera.sensorWidthMm, decimals: 2)) × \(DisplayFormat.number(camera.sensorHeightMm, decimals: 2)) mm")
                LabeledContent("Native resolution", value: "\(camera.nativeWidth) × \(camera.nativeHeight)")
            }
            Section {
                ForEach(camera.modes) { mode in
                    DisclosureGroup {
                        if !mode.note.isEmpty {
                            Text(mode.note).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(mode.resolutions) { resolution in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(resolution.label)
                                Text("\(resolution.width) × \(resolution.height)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let maximum = resolution.maxSensorFps {
                                    Text("Up to \(DisplayFormat.number(maximum, decimals: 2)) fps")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } label: {
                        Text(mode.label).frame(minHeight: Layout.controlHeight)
                    }
                }
            } header: {
                Text("Supported recording modes")
            } footer: {
                Text("Catalog reference. Available frame rates and codecs depend on the recording mode. Verify against camera firmware.")
            }
        }
        .navigationTitle(camera.name)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("camera-detail")
    }
}

private struct CameraSummary: View {
    let camera: CameraProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.name).font(.body.weight(.medium))
            Text("\(camera.manufacturer.rawValue) · \(camera.sensorLabel)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(minHeight: Layout.controlHeight, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// Reuse the same favorite action in catalog rows and details; membership never changes RATE selection.
private struct CameraFavoriteButton: View {
    let store: CalculatorStore
    let camera: CameraProfile
    var compact = false

    private var isFavorite: Bool { store.quickStartCameraIds.contains(camera.id) }

    var body: some View {
        Button {
            if isFavorite { store.removeQuickStart(cameraID: camera.id) }
            else { store.addQuickStart(cameraID: camera.id) }
        } label: {
            Label(isFavorite ? "Remove favorite" : "Add favorite", systemImage: isFavorite ? "star.fill" : "star")
                .labelStyle(FavoriteLabelStyle(compact: compact))
                .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(isFavorite ? "Remove" : "Add") \(camera.name) \(isFavorite ? "from" : "to") favorites")
        .accessibilityValue(isFavorite ? "Favorite" : "Not favorite")
        .accessibilityIdentifier("favorite-toggle-\(camera.id)")
        .help(isFavorite ? "Remove favorite" : "Add favorite")
    }
}

private struct FavoriteLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon }
        else { Label(configuration).labelStyle(.titleAndIcon) }
    }
}

private struct CameraOrderingActions: View {
    let store: CalculatorStore
    let camera: CameraProfile
    var includesRemoval = true

    var body: some View {
        Button("Move earlier", systemImage: "arrow.up") {
            store.shiftQuickStart(cameraID: camera.id, forward: false)
        }
        .disabled(store.quickStartCameraIds.first == camera.id)
        .accessibilityIdentifier("favorite-move-earlier")
        Button("Move later", systemImage: "arrow.down") {
            store.shiftQuickStart(cameraID: camera.id, forward: true)
        }
        .disabled(store.quickStartCameraIds.last == camera.id)
        .accessibilityIdentifier("favorite-move-later")
        if includesRemoval {
            Button("Remove favorite", systemImage: "star.slash") {
                store.removeQuickStart(cameraID: camera.id)
            }
        }
    }
}

import SwiftUI

#if os(iOS)
import UIKit
#endif

private enum CameraLibraryRoute: Hashable {
    case favorites
    case camera(String)
}

/// One shared store keeps browsing, details, favorites and the calculator strip in sync.
struct CameraLibraryView: View {
    let store: CalculatorStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedRoute: CameraLibraryRoute?

    private var matchingCameras: [CameraProfile] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.sortedCameras.filter {
            !$0.isStandaloneProRes && (search.isEmpty ||
                "\($0.manufacturer.rawValue) \($0.name)".localizedStandardContains(search))
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                NavigationSplitView {
                    catalogList(split: true)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420)
                } detail: {
                    NavigationStack {
                        // Keep favorites in the detail column while a camera
                        // pushes onto its stack, including after split collapse.
                        switch selectedRoute {
                        case .favorites:
                            CameraFavoritesView(store: store)
                        case .camera(let id):
                            if let camera = store.sortedCameras.first(where: { $0.id == id }) {
                                CameraDetailView(store: store, camera: camera)
                            } else {
                                // Clear a stale selection so the split view returns to its empty state.
                                ContentUnavailableView("nav.cameras", systemImage: "camera")
                                    .task { selectedRoute = nil }
                            }
                        case nil:
                            ContentUnavailableView("nav.cameras", systemImage: "camera")
                        }
                    }
                    .navigationDestination(for: CameraProfile.self) { camera in
                        CameraDetailView(store: store, camera: camera)
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                stackLibrary
            }
            #else
            stackLibrary
            #endif
        }
        .tint(Palette.text)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 700)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var stackLibrary: some View {
        NavigationStack {
            catalogList(split: false)
                .navigationDestination(for: CameraProfile.self) { camera in
                    CameraDetailView(store: store, camera: camera)
                }
        }
    }

    private func catalogList(split: Bool) -> some View {
        Group {
            if split {
                List(selection: $selectedRoute) { catalogRows(split: true) }
            } else {
                // iPhone and macOS retain their original plain List behavior.
                List { catalogRows(split: false) }
            }
        }
        .navigationTitle("nav.cameras")
        .searchable(text: $query, prompt: Text("camera.search"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("nav.done") { dismiss() }
                    .accessibilityIdentifier("camera-library-done")
            }
        }
    }

    @ViewBuilder
    private func catalogRows(split: Bool) -> some View {
        // Filter and sort once per list update, then preserve that order within each section.
        let camerasByManufacturer = Dictionary(grouping: matchingCameras, by: \.manufacturer)
        Section {
            Group {
                if split {
                    NavigationLink(value: CameraLibraryRoute.favorites) { favoritesLabel }
                } else {
                    NavigationLink { CameraFavoritesView(store: store) } label: { favoritesLabel }
                }
            }
            .accessibilityIdentifier("camera-favorites")
        } footer: {
            Text("camera.favoriteHint")
        }

        if camerasByManufacturer.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ForEach(CameraManufacturer.allCases, id: \.self) { manufacturer in
                let cameras = camerasByManufacturer[manufacturer] ?? []
                if !cameras.isEmpty {
                    Section(manufacturer.rawValue) {
                        ForEach(cameras) { camera in
                            HStack(spacing: 12) {
                                Group {
                                    if split {
                                        NavigationLink(value: CameraLibraryRoute.camera(camera.id)) { CameraSummary(camera: camera) }
                                    } else {
                                        NavigationLink(value: camera) { CameraSummary(camera: camera) }
                                    }
                                }
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

    private var favoritesLabel: some View {
        HStack {
            Label("nav.favorites", systemImage: "star.fill")
            Spacer()
            Text(store.quickStartCameraIds.count.formatted())
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: Layout.controlHeight)
    }
}

private struct CameraFavoritesView: View {
    let store: CalculatorStore

    var body: some View {
        List {
            if store.quickStartCameras.isEmpty {
                ContentUnavailableView("camera.noFavorites", systemImage: "star",
                    description: Text("camera.noFavoritesHint"))
            } else {
                Section {
                    ForEach(store.quickStartCameras) { camera in
                        NavigationLink(value: camera) { CameraSummary(camera: camera) }
                            .accessibilityIdentifier("favorite-camera-\(camera.id)")
                            .contextMenu { CameraOrderingActions(store: store, camera: camera) }
                            .accessibilityAction(named: Text("camera.moveEarlier")) {
                                store.shiftQuickStart(cameraID: camera.id, forward: false)
                            }
                            .accessibilityAction(named: Text("camera.moveLater")) {
                                store.shiftQuickStart(cameraID: camera.id, forward: true)
                            }
                            .accessibilityAction(named: Text("camera.removeFavorite")) {
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
                    Text("camera.favoriteFooter")
                }
            }
        }
        .navigationTitle("nav.favorites")
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
                Section {
                    // Visible native buttons also support users who cannot perform a drag gesture.
                    CameraOrderingActions(store: store, camera: camera, includesRemoval: false)
                } header: {
                    HStack(spacing: 4) {
                        Text("camera.favoriteOrder")
                        Text("\(position + 1)/\(store.quickStartCameraIds.count)").monospacedDigit()
                    }
                }
            }
            Section("camera.sensor") {
                LabeledContent("camera.format", value: camera.sensorLabel)
                LabeledContent("camera.dimensions", value: "\(DisplayFormat.number(camera.sensorWidthMm, decimals: 2)) × \(DisplayFormat.number(camera.sensorHeightMm, decimals: 2)) mm")
                LabeledContent("camera.nativeResolution", value: "\(camera.nativeWidth) × \(camera.nativeHeight)")
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
                                    HStack(spacing: 4) {
                                        Text("camera.upToFPS")
                                        Text("\(DisplayFormat.number(maximum, decimals: 2)) fps").monospacedDigit()
                                    }
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
                Text("camera.supportedModes")
            } footer: {
                Text("camera.catalogFooter")
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
            Label(isFavorite ? "camera.removeFavorite" : "camera.addFavorite", systemImage: isFavorite ? "star.fill" : "star")
                .labelStyle(FavoriteLabelStyle(compact: compact))
                .frame(minWidth: Layout.controlHeight, minHeight: Layout.controlHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        // Include the row's camera name because VoiceOver focuses this button separately.
        .accessibilityLabel(Text(isFavorite ? "camera.removeFavorite" : "camera.addFavorite")
                            + Text(verbatim: " · \(camera.name)"))
        .accessibilityValue(Text(isFavorite ? "camera.favorite" : "camera.notFavorite"))
        .accessibilityIdentifier("favorite-toggle-\(camera.id)")
        .help(Text(isFavorite ? "camera.removeFavorite" : "camera.addFavorite"))
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
        Button("camera.moveEarlier", systemImage: "arrow.up") {
            store.shiftQuickStart(cameraID: camera.id, forward: false)
        }
        .disabled(store.quickStartCameraIds.first == camera.id)
        .accessibilityIdentifier("favorite-move-earlier")
        Button("camera.moveLater", systemImage: "arrow.down") {
            store.shiftQuickStart(cameraID: camera.id, forward: true)
        }
        .disabled(store.quickStartCameraIds.last == camera.id)
        .accessibilityIdentifier("favorite-move-later")
        if includesRemoval {
            Button("camera.removeFavorite", systemImage: "star.slash") {
                store.removeQuickStart(cameraID: camera.id)
            }
        }
    }
}

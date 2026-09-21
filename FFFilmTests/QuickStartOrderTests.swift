import Foundation
import Testing
@testable import FFFilm

@MainActor
struct QuickStartOrderTests {
    @Test("Favorite reordering persists without changing the capture selection")
    func reorderAndReload() throws {
        let suite = "FFFilm.QuickStartOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CalculatorStore(defaults: defaults)
        let original = store.quickStartCameraIds
        let first = try #require(original.first)
        let last = try #require(original.last)
        let capture = store.settings

        #expect(store.moveQuickStart(cameraID: first, relativeTo: last, after: true))
        #expect(store.quickStartCameraIds == Array(original.dropFirst()) + [first])
        #expect(store.settings == capture)
        #expect(CalculatorStore(defaults: defaults).quickStartCameraIds == store.quickStartCameraIds)

        let currentFirst = try #require(store.quickStartCameraIds.first)
        #expect(store.moveQuickStart(cameraID: first, relativeTo: currentFirst, after: false))
        #expect(store.quickStartCameraIds == original)
        #expect(CalculatorStore(defaults: defaults).quickStartCameraIds == original)
    }

    @Test("Insertion edges, keyboard alternatives and invalid targets preserve list integrity")
    func edgesAndNoOps() throws {
        let suite = "FFFilm.QuickStartOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CalculatorStore(defaults: defaults)
        let original = store.quickStartCameraIds
        let first = try #require(original.first)
        let last = try #require(original.last)
        #expect(!store.moveQuickStart(cameraID: first, relativeTo: first, after: false))
        #expect(!store.moveQuickStart(cameraID: "apple-prores", relativeTo: first, after: false))
        #expect(!store.moveQuickStart(cameraID: first, relativeTo: "missing", after: false))
        store.shiftQuickStart(cameraID: first, forward: false)
        store.shiftQuickStart(cameraID: last, forward: true)
        #expect(store.quickStartCameraIds == original)
        store.shiftQuickStart(cameraID: first, forward: true)
        #expect(store.quickStartCameraIds[1] == first)
        store.shiftQuickStart(cameraID: first, forward: false)
        #expect(store.quickStartCameraIds == original)
        #expect(store.moveQuickStart(cameraID: last, relativeTo: first, after: false))
        #expect(store.quickStartCameraIds == [last] + Array(original.dropLast()))
        #expect(Set(store.quickStartCameraIds) == Set(original))
    }
    @Test("Native list multi-row moves use original offsets and persist")
    func nativeListMoves() throws {
        let suite = "FFFilm.Favorites.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CalculatorStore(defaults: defaults)
        let original = store.quickStartCameraIds
        let capture = store.settings
        store.moveQuickStarts(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        #expect(store.quickStartCameraIds == [original[1], original[3], original[0], original[2]])
        #expect(CalculatorStore(defaults: defaults).quickStartCameraIds == store.quickStartCameraIds)
        store.moveQuickStarts(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        let moved = store.quickStartCameraIds
        store.moveQuickStarts(fromOffsets: IndexSet([99]), toOffset: 0)
        store.moveQuickStarts(fromOffsets: IndexSet([0]), toOffset: 99)
        store.moveQuickStarts(fromOffsets: IndexSet(), toOffset: 0)
        #expect(store.quickStartCameraIds == moved)
        #expect(store.settings == capture)
    }

    @Test("Existing shortcuts migrate; favorites have no five-camera cap and empty stays empty")
    func favoritesMembershipAndMigration() throws {
        let suite = "FFFilm.Favorites.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Keep the existing storage key so the new library retains the user's saved order.
        defaults.set(["burano", "alexa35", "burano", "missing", "apple-prores"], forKey: "fffilm.quick-start-camera-ids")
        let store = CalculatorStore(defaults: defaults)
        #expect(store.quickStartCameraIds == ["burano", "alexa35"])
        let capture = store.settings
        for camera in store.sortedCameras { store.addQuickStart(cameraID: camera.id) }
        let all = store.sortedCameras.filter { !$0.isStandaloneProRes }
        #expect(store.quickStartCameraIds.count == all.count)
        #expect(store.quickStartCameraIds.count > 5)
        #expect(!store.canAddQuickStart)
        store.addQuickStart(cameraID: "missing")
        #expect(CalculatorStore(defaults: defaults).quickStartCameraIds == store.quickStartCameraIds)
        for camera in all { store.removeQuickStart(cameraID: camera.id) }
        #expect(CalculatorStore(defaults: defaults).quickStartCameraIds.isEmpty)
        #expect(store.canAddQuickStart)
        #expect(store.settings == capture)
    }

}

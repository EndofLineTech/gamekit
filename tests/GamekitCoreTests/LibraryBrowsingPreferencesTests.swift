import Foundation
import Testing
@testable import GamekitCore

@Suite("Local library browsing preferences")
struct LibraryBrowsingPreferencesTests {
    @Test("View, sort, size, sidebar and stable favorites survive reopen without altering other metadata")
    func roundTrip() async throws {
        let parent = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("Gamekit")
        let store = LibraryPreferencesStore(root: root)
        #expect(try await store.load() == LibraryBrowsingPreferences())
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let first = SteamGameInstallationID(environmentID: SteamInstallationRecipe.environmentID, appID: GameFixtures.primary.appId)
        let second = SteamGameInstallationID(environmentID: SteamInstallationRecipe.environmentID, appID: GameFixtures.other.appId)
        _ = try await store.setFavorite(first, enabled: true)
        _ = try await store.setFavorite(second, enabled: true)
        _ = try await store.setViewMode(.list)
        _ = try await store.setSortOrder(.reportedSize)
        _ = try await store.setCoverSize(220)
        _ = try await store.setSidebarVisible(false)
        let reopened = try await LibraryPreferencesStore(root: root).load()
        #expect(await store.loadForBrowsing().savedPreferencesUnavailable == false)
        #expect(reopened.viewMode == .list && reopened.sortOrder == .reportedSize)
        #expect(reopened.coverSize == 220 && !reopened.sidebarVisible)
        #expect(reopened.favorites == [first, second])
        let game = InstalledSteamGame(id: first.appID, name: GameFixtures.primary.name, installDirectory: "directory",
            buildID: nil, state: .ready, sizeOnDiskBytes: nil, artwork: nil)
        let presented = SteamLibraryGame(installed: game, environmentID: first.environmentID)
        #expect(reopened.favorites(in: []) == []) // An uninstalled favorite is not an installed tile.
        #expect(reopened.favorites(in: [presented]) == [presented])
        _ = try await store.setViewMode(.grid)
        #expect(try await store.load().favorites == [first, second])
        _ = try await store.setFavorite(first, enabled: false)
        #expect(try await store.load().favorites == [second])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/GamePresentation.json").path))
    }

    @Test("Corrupt, unknown and invalid preference documents are preserved and edits refused")
    func invalidDocument() async throws {
        let parent = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("Gamekit")
        let store = LibraryPreferencesStore(root: root)
        _ = try await store.setViewMode(.grid)
        let file = root.appendingPathComponent("Metadata/LibraryBrowsing.json")
        let current = try Data(contentsOf: file)
        for bytes in [Data("invalid".utf8),
                      Data(String(decoding: current, as: UTF8.self).replacingOccurrences(of: "\"grid\"", with: "\"unknown\"").utf8),
                      Data(String(decoding: current, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99").utf8),
                      Data(String(decoding: current, as: UTF8.self).replacingOccurrences(of: "\"coverSize\" : 145", with: "\"coverSize\" : 900").utf8)] {
            try bytes.write(to: file)
            await #expect(throws: LibraryPreferencesError.invalidDocument) { try await store.load() }
            let fallback = await store.loadForBrowsing()
            #expect(fallback.savedPreferencesUnavailable)
            #expect(fallback.preferences == LibraryBrowsingPreferences())
            await #expect(throws: LibraryPreferencesError.invalidDocument) { try await store.setViewMode(.list) }
            #expect(try Data(contentsOf: file) == bytes)
        }
        try current.write(to: file)
        await #expect(throws: LibraryPreferencesError.invalidCoverSize) { try await store.setCoverSize(100) }
        let otherEnvironment = SteamGameInstallationID(environmentID: try EnvironmentID("other"), appID: 1)
        await #expect(throws: LibraryPreferencesError.invalidFavorite) { try await store.setFavorite(otherEnvironment, enabled: true) }
        #expect(try Data(contentsOf: file) == current)
    }
}

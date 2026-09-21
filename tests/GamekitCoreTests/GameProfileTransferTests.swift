import Foundation
import Testing
@testable import GamekitCore

@Suite("Manual JSON profile transfer")
struct GameProfileTransferTests {
    private func data(revision: Int, note: String) throws -> Data {
        let profile = try #require(GameProfileStore.bundled(appID: GameFixtures.renderer.appId))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object["revision"] = revision; object["notes"] = note
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func localOverrideRoundTripsAndSurvivesDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameProfileStore(root: root), id = GameFixtures.renderer.appId
        let metadata = root.appendingPathComponent("Metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        let preferences = try GameFixtures.preferences(game: GameFixtures.renderer, backend: "metal3")
        let preferenceFile = metadata.appendingPathComponent("GameCompatibility.json")
        try preferences.write(to: preferenceFile)
        try await store.importProfile(data(revision: 1, note: "Manual edit"), appID: id)
        #expect(GameProfileStore.resolved(appID: id, root: root)?.isLocal == true)
        #expect(GameProfileStore.resolved(appID: id, root: root)?.profile.notes == "Manual edit")
        #expect(try await store.accept(data(revision: 99, note: "Wiki update"), appID: id) == false)
        let exported = try await store.exportProfile(appID: id, name: "Fixture")
        #expect(try GameProfile.decode(exported, appID: id).notes == "Manual edit")
        try await store.importProfile(data(revision: 1, note: "Second edit without revision bump"), appID: id)
        #expect(GameProfileStore.resolved(appID: id, root: root)?.profile.revision == 1)
        try await store.removeImportedProfile(appID: id)
        #expect(GameProfileStore.resolved(appID: id, root: root)?.isLocal == false)
        #expect(GameProfileStore.resolved(appID: id, root: root)?.profile.notes == "Wiki update")
        #expect(try Data(contentsOf: preferenceFile) == preferences)
    }

    @Test func invalidImportsPreservePreviousAndFileReadsAreBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameProfileStore(root: root), id = GameFixtures.renderer.appId
        let file = root.appendingPathComponent("selected.json")
        try data(revision: 1, note: "Accepted").write(to: file)
        try await store.importProfile(from: file, appID: id)
        await #expect(throws: (any Error).self) { try await store.importProfile(from: file, appID: 42) }
        try Data(repeating: 32, count: GameProfile.maximumBytes + 1).write(to: file)
        await #expect(throws: (any Error).self) { try await store.importProfile(from: file, appID: id) }
        await #expect(throws: (any Error).self) { try await store.importProfile(Data("{}".utf8), appID: id) }
        #expect(GameProfileStore.resolved(appID: id, root: root)?.profile.notes == "Accepted")
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("target.json")
        try data(revision: 2, note: "Target").write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await store.importProfile(from: file, appID: id) }
    }

    @Test func exportWithoutProfileCreatesValidatedEmptyTemplate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameProfileStore(root: root)
        let exported = try await store.exportProfile(appID: 42, name: "Offline fixture")
        let profile = try GameProfile.decode(exported, appID: 42)
        #expect(profile.name == "Offline fixture" && profile.launchArguments.isEmpty && !profile.execution.hasSettings)
        #expect(GameProfileStore.resolved(appID: 42, root: root) == nil)
    }

    @Test func largeValidImportRemainsReimportableAfterExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameProfileStore(root: root)
        let template = try await store.exportProfile(appID: 42, name: "Large fixture")
        var object = try #require(JSONSerialization.jsonObject(with: template) as? [String: Any])
        let argument = "-" + String(repeating: "/", count: 510)
        object["launchArguments"] = Dictionary(uniqueKeysWithValues: GraphicsBackend.allCases.map { ($0.rawValue, Array(repeating: argument, count: 15)) })
        object["notes"] = String(repeating: "n", count: 1200)
        let input = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        try #require(input.count <= GameProfile.maximumBytes)
        try await store.importProfile(input, appID: 42)
        let exported = try await store.exportProfile(appID: 42, name: "Large fixture")
        #expect(exported.count <= GameProfile.maximumBytes)
        #expect(try GameProfile.decode(exported, appID: 42) == GameProfile.decode(input, appID: 42))
    }
}

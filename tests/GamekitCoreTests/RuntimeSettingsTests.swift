import Foundation
import Testing
@testable import GamekitCore

@Suite("Local runtime selection")
struct RuntimeSettingsTests {
    @Test("Backend selection survives reopen and runtime changes without changing prefix or caches")
    func graphicsPersistence() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let settings = RuntimeSettingsStore(store: store)
        let bundle = parent.appendingPathComponent("Custom.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let record = try await store.create(EnvironmentRecord(id: EnvironmentID("steam"), name: "Preserved Steam",
            runtime: RuntimeProfile.sikarugir.identity))
        let prefix = store.prefixURL(for: record.id)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let marker = prefix.appendingPathComponent("game-settings")
        try Data("preserve cursor settings".utf8).write(to: marker)
        try await settings.select(bundle, revision: .textInput1)
        let before = try await settings.layout()
        try await settings.selectGraphicsBackend(.metal3)
        let reopened = RuntimeSettingsStore(store: store)
        let saved = try await reopened.layout()
        #expect(saved.graphicsBackend == .metal3)
        #expect(saved.environment()["D3DM_MTL4"] == "0")
        #expect(saved.bundle == before.bundle && saved.profile.revision == .textInput1)
        #expect(saved.dataRoot == before.dataRoot && saved.steamApplicationBundle == before.steamApplicationBundle)
        try await reopened.select(nil, revision: .original)
        #expect(try await reopened.layout().graphicsBackend == .metal3)
        try await reopened.selectGraphicsBackend(.automatic)
        #expect(try await reopened.layout().environment()["D3DM_MTL4"] == nil)
        #expect(try await reopened.layout().bundle == RuntimeLayout(dataRoot: store.root).bundle)
        #expect(try await store.load(record.id) == record)
        #expect(try Data(contentsOf: marker) == Data("preserve cursor settings".utf8))
    }

    @Test("An execution lease rejects backend changes and preserves the saved selection")
    func backendExecutionLock() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let record = try await store.create(EnvironmentRecord(id: EnvironmentID("steam"), name: "Steam"))
        try FileManager.default.createDirectory(at: store.prefixURL(for: record.id), withIntermediateDirectories: true)
        let settings = RuntimeSettingsStore(store: store)
        try await settings.selectGraphicsBackend(.automatic)
        let path = store.root.appendingPathComponent("Metadata/RuntimeSelection.json")
        let before = try Data(contentsOf: path)
        let lease = try await store.executionLease(for: record.id)
        defer { withExtendedLifetime(lease) {} }
        await #expect(throws: EnvironmentStoreError.busy) { try await settings.selectGraphicsBackend(.metal3) }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test("Legacy selections default to automatic graphics", arguments: [
        #"{"schemaVersion":1}"#,
        #"{"schemaVersion":2,"revision":"text-input-1"}"#
    ])
    func legacyGraphics(document: String) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let metadata = store.root.appendingPathComponent("Metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data(document.utf8).write(to: metadata.appendingPathComponent("RuntimeSelection.json"))
        #expect(try await RuntimeSettingsStore(store: store).layout().graphicsBackend == .automatic)
    }

    @Test("Unknown or incomplete backend selections are rejected", arguments: [
        #"{"schemaVersion":3,"revision":"text-input-1","graphicsBackend":"future"}"#,
        #"{"schemaVersion":3,"revision":"text-input-1"}"#,
        #"{"schemaVersion":2,"revision":"text-input-1","graphicsBackend":"metal3"}"#
    ])
    func invalidGraphics(document: String) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let metadata = store.root.appendingPathComponent("Metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data(document.utf8).write(to: metadata.appendingPathComponent("RuntimeSelection.json"))
        await #expect(throws: (any Error).self) { try await RuntimeSettingsStore(store: store).layout() }
    }

    @Test("Component revision selection persists and rolls back without migrating the prefix")
    func componentRevision() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let record = try await store.create(EnvironmentRecord(id: EnvironmentID("steam"), name: "Steam",
            runtime: RuntimeProfile.sikarugir.identity))
        let prefix = store.prefixURL(for: record.id)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let save = prefix.appendingPathComponent("preserved-save")
        try Data("keep".utf8).write(to: save)
        let settings = RuntimeSettingsStore(store: store)
        let old = try await settings.layout()
        try await settings.select(nil, revision: .textInput1)
        let updated = try await RuntimeSettingsStore(store: store).layout()
        #expect(updated.profile.revision == .textInput1)
        #expect(updated.profile.identity == old.profile.identity)
        #expect(updated.profile.hashes["Contents/SharedSupport/wine/lib/wine/x86_64-windows/msctf.dll"]
            == "bb8db266526cff89c2bc6a436482b24c632c13596c1864adb4cb2e42e58fca8b")
        #expect(updated.steamApplicationBundle != old.steamApplicationBundle)
        #expect(updated.gameApplicationsRoot != old.gameApplicationsRoot)
        #expect(try Data(contentsOf: save) == Data("keep".utf8))
        #expect(try await store.load(record.id) == record)
        try await settings.select(nil, revision: .original)
        #expect(try await settings.layout().steamApplicationBundle == old.steamApplicationBundle)
        #expect(try Data(contentsOf: save) == Data("keep".utf8))
    }

    @Test("Schema-one selections keep the original runtime and cache namespace")
    func legacySelection() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let metadata = store.root.appendingPathComponent("Metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: metadata.appendingPathComponent("RuntimeSelection.json"))
        let layout = try await RuntimeSettingsStore(store: store).layout()
        #expect(layout.profile.revision == .original)
        #expect(layout.steamApplicationBundle == store.root.appendingPathComponent("Launchers/Windows Steam.app"))
    }

    @Test("Runtime selection persists a local bundle while leaving managed storage fixed")
    func persistence() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let selected = parent.appendingPathComponent("Selected Runtime.app")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let settings = RuntimeSettingsStore(store: store)
        try await settings.select(selected)
        let reopened = RuntimeSettingsStore(store: store)
        let layout = try await reopened.layout()
        #expect(layout.bundle.resolvingSymlinksInPath() == selected.resolvingSymlinksInPath())
        #expect(layout.dataRoot == store.root)
        try await settings.select(nil)
        #expect(try await reopened.layout().bundle == RuntimeLayout(dataRoot: store.root).bundle)
    }

    @Test("A live installation lease prevents runtime selection changes")
    func activeOperation() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let lease = try await store.installationLease()
        defer { withExtendedLifetime(lease) {} }
        let settings = RuntimeSettingsStore(store: store)
        await #expect(throws: EnvironmentStoreError.busy) { try await settings.select(nil) }
        await #expect(throws: EnvironmentStoreError.busy) { try await settings.select(nil, revision: .textInput1) }
        await #expect(throws: EnvironmentStoreError.busy) { try await settings.selectGraphicsBackend(.metal3) }
    }

    @Test("A runtime selection symlink is refused without changing saved settings")
    func redirectedSelection() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let link = parent.appendingPathComponent("Redirect.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
        let settings = RuntimeSettingsStore(store: store)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await settings.select(link) }
        #expect(try await settings.layout().bundle == RuntimeLayout(dataRoot: store.root).bundle)
    }

    @Test("Persistent lifecycle receipts prevent selecting another runtime")
    func receiptPinsSelection() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let directory = store.root.appendingPathComponent("Metadata/Lifecycle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("steam.json"))
        let settings = RuntimeSettingsStore(store: store)
        #expect(try await settings.isSelectionLocked())
        await #expect(throws: EnvironmentStoreError.busy) { try await settings.select(nil) }
        await #expect(throws: EnvironmentStoreError.busy) { try await settings.selectGraphicsBackend(.metal3) }
    }
}

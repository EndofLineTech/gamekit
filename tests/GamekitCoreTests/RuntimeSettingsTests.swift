import Foundation
import Testing
@testable import GamekitCore

@Suite("Local runtime selection")
struct RuntimeSettingsTests {
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
    }
}

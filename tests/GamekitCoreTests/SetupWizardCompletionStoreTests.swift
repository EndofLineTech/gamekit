import Foundation
import Testing
@testable import GamekitCore

@Suite("First-run wizard completion")
struct SetupWizardCompletionStoreTests {
    @Test("Only completing prerequisites records durable first-run completion")
    func persistsAndReopens() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Gamekit")
        let store = try SetupWizardCompletionStore(root: root)
        #expect(try await !store.isComplete())
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try await store.markComplete()
        try await store.markComplete()
        #expect(try await SetupWizardCompletionStore(root: root).isComplete())
    }

    @Test("Changed or redirected completion records are not accepted or overwritten")
    func refusesUnsafeRecord() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let metadata = parent.appendingPathComponent("Gamekit/Metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = metadata.appendingPathComponent("SetupWizardCompletion.json")
        try Data("invalid".utf8).write(to: file)
        let store = try SetupWizardCompletionStore(root: parent.appendingPathComponent("Gamekit"))
        await #expect(throws: SetupWizardCompletionError.invalidDocument) { try await store.isComplete() }
        await #expect(throws: SetupWizardCompletionError.invalidDocument) { try await store.markComplete() }
        #expect(try Data(contentsOf: file) == Data("invalid".utf8))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: parent.appendingPathComponent("outside"))
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await store.isComplete() }
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("outside").path))
    }
}

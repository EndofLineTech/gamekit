import Foundation

public enum SetupWizardCompletionError: Error, Equatable { case invalidDocument }

/// Records completion of the prerequisites, independently of optional launcher installs.
/// A completed first-run wizard is never automatically offered again.
public actor SetupWizardCompletionStore {
    private struct Receipt: Codable {
        let schemaVersion: Int
        let completed: Bool
    }

    private let root: URL
    private let filename = "SetupWizardCompletion.json"

    public init(root: URL = EnvironmentStore.applicationSupportRoot) throws {
        self.root = try ManagedDirectory.canonicalRoot(root)
    }

    private func metadata(create: Bool) throws -> ManagedDirectory? {
        guard let directory = try ManagedDirectory.openRoot(root, create: create) else { return nil }
        return try directory.directory("Metadata", create: create)
    }

    private func read(_ directory: ManagedDirectory?) throws -> Bool {
        guard let data = try directory?.read(filename, maximumBytes: 1024) else { return false }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schemaVersion == 1, receipt.completed else { throw SetupWizardCompletionError.invalidDocument }
        return true
    }

    public func isComplete() throws -> Bool { try read(metadata(create: false)) }

    public func markComplete() throws {
        guard let directory = try metadata(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            guard try !read(directory) else { return }
            let data = try JSONEncoder().encode(Receipt(schemaVersion: 1, completed: true))
            try directory.write(data, to: filename, createOnly: true, beforeCommit: {})
        }
    }
}

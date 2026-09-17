import Foundation

/// A local selection only: it neither installs a runtime nor changes the prefix.
/// Component revisions use the same base Wine/prefix identity. Selection is an
/// atomic pointer switch while stopped; each revision has its own launcher cache.
public actor RuntimeSettingsStore {
    private struct Settings: Codable {
        var schemaVersion = 2
        let bundle: URL?
        let revision: RuntimeRevision?
    }
    private let store: EnvironmentStore
    public init(store: EnvironmentStore) { self.store = store }

    private func metadata(create: Bool) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(store.root, create: create) else { return nil }
        return try root.directory("Metadata", create: create)
    }
    public func layout() throws -> RuntimeLayout {
        guard let bytes = try metadata(create: false)?.read("RuntimeSelection.json") else { return RuntimeLayout(dataRoot: store.root) }
        let settings = try JSONDecoder().decode(Settings.self, from: bytes)
        guard (settings.schemaVersion == 1 && settings.revision == nil)
                || (settings.schemaVersion == 2 && settings.revision != nil)
        else { throw MetadataError.unsupportedSchema(settings.schemaVersion) }
        if let bundle = settings.bundle {
            guard bundle.isFileURL, bundle.path.hasPrefix("/"), bundle.path != "/", !bundle.path.utf8.contains(0),
                  bundle.user == nil, bundle.password == nil, bundle.query == nil, bundle.fragment == nil else { throw EnvironmentStoreError.unsafePath }
        }
        return RuntimeLayout(dataRoot: store.root, profile: (settings.revision ?? .original).profile, bundle: settings.bundle)
    }

    public func isSelectionLocked() throws -> Bool {
        guard let directory = try metadata(create: false)?.directory("Lifecycle") else { return false }
        return try directory.names().contains { $0.hasSuffix(".json") }
    }

    public func select(_ supplied: URL?, revision: RuntimeRevision = .original) async throws {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        guard !(try isSelectionLocked()) else { throw EnvironmentStoreError.busy }
        let oldLayout = try layout()
        let records = try await store.loadAll()
        var executionLocks: [ManagedFileLock] = []
        defer { withExtendedLifetime(executionLocks) {} }
        if let environments = try metadata(create: false)?.directory("Environments") {
            for record in records {
                executionLocks.append(try environments.acquireLock(".execution-\(record.id.rawValue).lock"))
                let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: oldLayout)
                guard snapshot.complete, snapshot.processes.isEmpty else { throw EnvironmentStoreError.busy }
            }
        }
        let bundle: URL?
        if let supplied {
            bundle = try ManagedDirectory.canonicalRoot(supplied)
            _ = try ManagedDirectory.openRoot(bundle!, create: false) // reject redirection, allow a missing selection to be explained by validation
        } else { bundle = nil }
        guard let directory = try metadata(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try directory.write(JSONEncoder().encode(Settings(bundle: bundle, revision: revision)), to: "RuntimeSelection.json", createOnly: false, beforeCommit: {})
        }
    }
}

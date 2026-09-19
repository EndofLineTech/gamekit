import Foundation

/// A local selection only: it neither installs a runtime nor changes the prefix.
/// Component revisions use the same base Wine/prefix identity. Selection is an
/// atomic pointer switch while stopped; each revision has its own launcher cache.
public actor RuntimeSettingsStore {
    private struct Settings: Codable {
        var schemaVersion = 3
        let bundle: URL?
        let revision: RuntimeRevision?
        let graphicsBackend: D3DMetalBackend?
    }
    private let store: EnvironmentStore
    public init(store: EnvironmentStore) { self.store = store }

    private func metadata(create: Bool) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(store.root, create: create) else { return nil }
        return try root.directory("Metadata", create: create)
    }
    private func readSettings() throws -> Settings? {
        guard let bytes = try metadata(create: false)?.read("RuntimeSelection.json") else { return nil }
        let settings = try JSONDecoder().decode(Settings.self, from: bytes)
        guard (settings.schemaVersion == 1 && settings.revision == nil && settings.graphicsBackend == nil)
                || (settings.schemaVersion == 2 && settings.revision != nil && settings.graphicsBackend == nil)
                || (settings.schemaVersion == 3 && settings.revision != nil && settings.graphicsBackend != nil)
        else { throw MetadataError.unsupportedSchema(settings.schemaVersion) }
        if let bundle = settings.bundle {
            guard bundle.isFileURL, bundle.path.hasPrefix("/"), bundle.path != "/", !bundle.path.utf8.contains(0),
                  bundle.user == nil, bundle.password == nil, bundle.query == nil, bundle.fragment == nil else { throw EnvironmentStoreError.unsafePath }
        }
        return settings
    }
    private func layout(_ settings: Settings?) -> RuntimeLayout {
        RuntimeLayout(dataRoot: store.root, profile: (settings?.revision ?? .original).profile, bundle: settings?.bundle,
                      graphicsBackend: settings?.graphicsBackend ?? .automatic)
    }
    public func layout() throws -> RuntimeLayout {
        layout(try readSettings())
    }

    public func isSelectionLocked() throws -> Bool {
        guard let directory = try metadata(create: false)?.directory("Lifecycle") else { return false }
        return try directory.names().contains { $0.hasSuffix(".json") }
    }

    private enum Change {
        case runtime(URL?, RuntimeRevision, D3DMetalBackend?)
        case graphics(D3DMetalBackend)
    }

    public func select(_ supplied: URL?, revision: RuntimeRevision = .original, graphicsBackend: D3DMetalBackend? = nil) async throws {
        try await update(.runtime(supplied, revision, graphicsBackend))
    }

    /// Saved for the entire managed Steam environment, not an individual game.
    /// Existing persistent sessions must be stopped before any change.
    public func selectGraphicsBackend(_ backend: D3DMetalBackend) async throws {
        try await update(.graphics(backend))
    }

    private func update(_ change: Change) async throws {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        guard !(try isSelectionLocked()) else { throw EnvironmentStoreError.busy }
        let current = try readSettings()
        let oldLayout = layout(current)
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
        var bundle = current?.bundle
        var revision = current?.revision ?? .original
        var graphicsBackend = current?.graphicsBackend ?? .automatic
        switch change {
        case .runtime(let supplied, let selectedRevision, let backend):
            if let supplied {
                let canonical = try ManagedDirectory.canonicalRoot(supplied)
                _ = try ManagedDirectory.openRoot(canonical, create: false)
                bundle = canonical
            } else { bundle = nil }
            revision = selectedRevision
            if let backend { graphicsBackend = backend }
        case .graphics(let backend):
            graphicsBackend = backend
        }
        try GraphicsPayload(backend: graphicsBackend)?.validate(layout: RuntimeLayout(dataRoot: store.root,
            profile: revision.profile, bundle: bundle, graphicsBackend: graphicsBackend))
        guard let directory = try metadata(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try directory.write(JSONEncoder().encode(Settings(bundle: bundle, revision: revision, graphicsBackend: graphicsBackend)), to: "RuntimeSelection.json", createOnly: false, beforeCommit: {})
        }
    }
}

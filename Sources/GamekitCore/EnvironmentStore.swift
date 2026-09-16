import Darwin
import Foundation

/// Per-record atomic metadata storage. Prefix creation is exclusive and requires
/// the installation coordinator's persisted creatingPrefix stage; prefixes are never reset.
public actor EnvironmentStore {
    public nonisolated let root: URL
    private let beforeCommit: @Sendable () throws -> Void

    public static var applicationSupportRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Gamekit", isDirectory: true)
    }

    public init(root: URL = EnvironmentStore.applicationSupportRoot) throws {
        self.root = try Self.canonicalRoot(root)
        beforeCommit = {}
    }

    /// Fault injection at the boundary between the completed temporary write and publication.
    init(root: URL, beforeCommit: @escaping @Sendable () throws -> Void) throws {
        self.root = try Self.canonicalRoot(root)
        self.beforeCommit = beforeCommit
    }

    private static func canonicalRoot(_ supplied: URL) throws -> URL {
        try ManagedDirectory.canonicalRoot(supplied)
    }

    /// Informational locator, not authorization for unguarded filesystem mutation.
    public nonisolated func prefixURL(for id: EnvironmentID) -> URL {
        root.appendingPathComponent("Environments", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
    }

    private func directories(create: Bool) throws -> (root: ManagedDirectory, metadata: ManagedDirectory)? {
        guard let rootDirectory = try ManagedDirectory.openRoot(root, create: create),
              let metadata = try rootDirectory.directory("Metadata", create: create),
              let environments = try metadata.directory("Environments", create: create) else { return nil }
        return (rootDirectory, environments)
    }

    private func load(_ id: EnvironmentID, from directory: ManagedDirectory) throws -> EnvironmentRecord? {
        guard let data = try directory.read("\(id.rawValue).json") else { return nil }
        let record = try EnvironmentDocument.decode(data)
        guard record.id == id else { throw EnvironmentStoreError.identityMismatch }
        return record
    }

    public func load(_ id: EnvironmentID) throws -> EnvironmentRecord? {
        guard let directory = try directories(create: false) else { return nil }
        return try load(id, from: directory.metadata)
    }

    public func loadAll() throws -> [EnvironmentRecord] {
        guard let directory = try directories(create: false) else { return [] }
        return try directory.metadata.names().filter { $0.hasSuffix(".json") }.map { name in
            let id = try EnvironmentID(String(name.dropLast(5)))
            guard let record = try load(id, from: directory.metadata) else { throw EnvironmentStoreError.notFound }
            return record
        }
    }

    private func inspectFiles(_ record: EnvironmentRecord, in rootDirectory: ManagedDirectory) throws -> EnvironmentFiles {
        try record.validate()
        guard let environments = try rootDirectory.directory("Environments"),
              let prefix = try environments.directory(record.id.rawValue) else {
            return EnvironmentFiles(prefixExists: false, executableExists: false)
        }
        var directory = prefix
        let parts = record.steamExecutable.components
        for part in parts.dropLast() {
            guard let next = try directory.directory(part) else {
                return EnvironmentFiles(prefixExists: true, executableExists: false)
            }
            directory = next
        }
        return EnvironmentFiles(prefixExists: true, executableExists: try directory.containsRegularFile(parts[parts.count - 1]))
    }

    public func create(_ record: EnvironmentRecord) throws -> EnvironmentRecord {
        try record.validate()
        guard record.revision == 0 else { throw EnvironmentStoreError.conflict }
        guard let directory = try directories(create: true) else { throw EnvironmentStoreError.notFound }
        return try directory.metadata.withWriteLock {
            if try directory.metadata.containsRegularFile("\(record.id.rawValue).json") {
                throw EnvironmentStoreError.alreadyExists
            }
            if try inspectFiles(record, in: directory.root).prefixExists { throw EnvironmentStoreError.prefixAlreadyExists }
            let data = try EnvironmentDocument.encode(record)
            try directory.metadata.write(data, to: "\(record.id.rawValue).json", createOnly: true, beforeCommit: beforeCommit)
            return try EnvironmentDocument.decode(data)
        }
    }

    public func save(_ record: EnvironmentRecord) throws -> EnvironmentRecord {
        try record.validate()
        guard let directory = try directories(create: false) else { throw EnvironmentStoreError.notFound }
        return try directory.metadata.withWriteLock {
            guard let current = try load(record.id, from: directory.metadata) else { throw EnvironmentStoreError.notFound }
            guard current.revision == record.revision, current.createdAt == record.createdAt else {
                throw EnvironmentStoreError.conflict
            }
            // A running operation pins its runtime and executable selection. Progress
            // and display-name updates can still be recorded by the coordinator.
            let selectionChanged = current.runtime != record.runtime || current.steamExecutable != record.steamExecutable || current.installationRecipeVersion != record.installationRecipeVersion
            let installLock = selectionChanged ? try directory.metadata.acquireLock(".installation.lock") : nil
            defer { withExtendedLifetime(installLock) {} }
            if selectionChanged, let lifecycle = try directory.root.directory("Metadata")?.directory("Lifecycle"),
               try lifecycle.containsRegularFile("\(record.id.rawValue).json") {
                // Persistent Steam can outlive Gamekit's execution lease. Retain
                // its selected runtime until scoped Stop clears the launch receipt.
                throw EnvironmentStoreError.busy
            }
            let selectionLock = selectionChanged
                ? try directory.metadata.acquireLock(".execution-\(record.id.rawValue).lock") : nil
            defer { withExtendedLifetime(selectionLock) {} }
            _ = try inspectFiles(record, in: directory.root)
            var updated = record
            updated.revision += 1
            updated.updatedAt = max(current.updatedAt, max(record.updatedAt, Date()))
            let data = try EnvironmentDocument.encode(updated)
            try directory.metadata.write(data, to: "\(record.id.rawValue).json", createOnly: false, beforeCommit: beforeCommit)
            return try EnvironmentDocument.decode(data)
        }
    }

    public func checkedPrefixURL(for id: EnvironmentID) throws -> URL {
        guard let directory = try directories(create: false),
              let record = try load(id, from: directory.metadata) else { throw EnvironmentStoreError.notFound }
        _ = try inspectFiles(record, in: directory.root)
        return prefixURL(for: id)
    }

    func installationLease() throws -> ManagedFileLock {
        guard let directory = try directories(create: true) else { throw EnvironmentStoreError.notFound }
        return try directory.metadata.acquireLock(".installation.lock")
    }

    func createInstallationPrefix(_ record: EnvironmentRecord) throws {
        guard let directory = try directories(create: false) else { throw EnvironmentStoreError.notFound }
        try directory.metadata.withWriteLock {
            guard let current = try load(record.id, from: directory.metadata), current == record,
                  current.installation == .installing(.creatingPrefix), current.installationRecipeVersion == 1
            else { throw EnvironmentStoreError.conflict }
            guard let environments = try directory.root.directory("Environments", create: true) else { throw EnvironmentStoreError.notFound }
            _ = try environments.createExclusiveDirectory(record.id.rawValue)
        }
    }

    func installationFiles(_ id: EnvironmentID) throws -> EnvironmentFiles {
        guard let directory = try directories(create: false), let record = try load(id, from: directory.metadata)
        else { throw EnvironmentStoreError.notFound }
        return try inspectFiles(record, in: directory.root)
    }

    func executionLease(for id: EnvironmentID) throws -> EnvironmentExecutionLease {
        guard let directory = try directories(create: false) else { throw EnvironmentStoreError.notFound }
        return try directory.metadata.withWriteLock {
            guard let record = try load(id, from: directory.metadata),
                  let environments = try directory.root.directory("Environments"),
                  let prefix = try environments.directory(id.rawValue) else { throw EnvironmentStoreError.notFound }
            _ = try inspectFiles(record, in: directory.root)
            let lock = try directory.metadata.acquireLock(".execution-\(id.rawValue).lock")
            return EnvironmentExecutionLease(record: record, root: root, prefix: prefixURL(for: id),
                                             pinnedPrefix: prefix, identity: try prefix.identity(), lock: lock)
        }
    }

    /// Process/runtime observations are supplied by E3.3's scoped detector. Unknown
    /// observations stay unverified; only a positively idle process set interrupts work.
    public func reconcile(_ id: EnvironmentID, process: ProcessObservation,
                          prerequisites: PrerequisiteObservation, at now: Date = Date(),
                          expectedRevision: Int? = nil) throws -> ReconciledEnvironment {
        guard let directory = try directories(create: false),
              let original = try load(id, from: directory.metadata) else { throw EnvironmentStoreError.notFound }
        if let expectedRevision, original.revision != expectedRevision { throw EnvironmentStoreError.conflict }
        let files = try inspectFiles(original, in: directory.root)
        let result = EnvironmentReconciler.reconcile(original, files: files, process: process,
                                                    prerequisites: prerequisites, at: now)
        // An idle scan can race a new operation. Never persist interruption while
        // a current process coordinator owns the environment's execution lease.
        let interruptionLock: ManagedFileLock?
        let installationLock: ManagedFileLock?
        if case .installing = original.installation, case .interrupted = result.record.installation {
            installationLock = try directory.metadata.acquireLock(".installation.lock")
            interruptionLock = try directory.metadata.acquireLock(".execution-\(id.rawValue).lock")
        } else { interruptionLock = nil; installationLock = nil }
        defer { withExtendedLifetime(interruptionLock) {}; withExtendedLifetime(installationLock) {} }
        let persisted = result.record == original ? original : try save(result.record)
        return ReconciledEnvironment(record: persisted, files: files, state: result.state)
    }
}

/// The immutable lease is only issued for a registered, existing, checked prefix.
final class EnvironmentExecutionLease: @unchecked Sendable {
    let record: EnvironmentRecord
    let root: URL
    let prefix: URL
    private let identity: (device: Int32, inode: UInt64)
    var prefixIdentity: (device: Int32, inode: UInt64) { identity }
    private let pinnedPrefix: ManagedDirectory
    private let lock: ManagedFileLock
    init(record: EnvironmentRecord, root: URL, prefix: URL, pinnedPrefix: ManagedDirectory,
         identity: (device: Int32, inode: UInt64), lock: ManagedFileLock) {
        self.record = record; self.root = root; self.prefix = prefix
        self.pinnedPrefix = pinnedPrefix; self.identity = identity; self.lock = lock
    }
    func validate() throws {
        guard let root = try ManagedDirectory.openRoot(root, create: false),
              let environments = try root.directory("Environments"),
              let current = try environments.directory(record.id.rawValue),
              try current.identity() == identity else { throw EnvironmentStoreError.unsafePath }
    }
}

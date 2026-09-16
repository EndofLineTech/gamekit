import Foundation

public enum SteamRecoveryError: Error, Equatable {
    case confirmationRequired, unsupportedRecord, activeProcesses, observationUnavailable, pendingReset, invalidJournal, cleanupFailed
}
enum SteamRecoveryCheckpoint: Sendable { case prepared, archived, metadataReset, libraryMoved }
private struct RecoveryDirectoryIdentity: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    init(_ directory: ManagedDirectory) throws { let value = try directory.identity(); device = value.device; inode = value.inode }
}
private struct PreservedSteamLibrary: Codable {
    let name: String
    let identity: RecoveryDirectoryIdentity
}
private struct SteamResetJournal: Codable {
    enum Phase: String, Codable { case prepared, ready, restoring, restored }
    var schemaVersion = 1
    let id: EnvironmentID
    let token: UUID
    var createdAt = Date()
    let original: EnvironmentRecord
    let prefixIdentity: RecoveryDirectoryIdentity?
    let libraries: [PreservedSteamLibrary]
    var newPrefixIdentity: RecoveryDirectoryIdentity?
    var phase: Phase = .prepared
}

/// Transaction journal plus same-volume directory moves. Old prefixes are archived,
/// never recursively deleted; downloaded libraries are moved back without copying.
struct SteamRecoveryArchive {
    let root: URL
    let id: EnvironmentID
    private func rootDirectory() throws -> ManagedDirectory {
        guard let directory = try ManagedDirectory.openRoot(root, create: false) else { throw EnvironmentStoreError.notFound }
        return directory
    }
    private func journalDirectory(create: Bool) throws -> ManagedDirectory? {
        guard let metadata = try rootDirectory().directory("Metadata", create: create) else { return nil }
        return try metadata.directory("Recovery", create: create)
    }
    private func read() throws -> SteamResetJournal? {
        guard let data = try journalDirectory(create: false)?.read(id.rawValue + ".json") else { return nil }
        let journal = try JSONDecoder().decode(SteamResetJournal.self, from: data)
        guard journal.schemaVersion == 1, journal.id == id, journal.original.id == id,
              journal.original.installationRecipeVersion == 1, journal.original.steamExecutable == .steamDefault,
              Set(journal.libraries.map(\.name)).count == journal.libraries.count,
              journal.libraries.allSatisfy({ ["steamapps", "depotcache"].contains($0.name) }) else { throw SteamRecoveryError.invalidJournal }
        return journal
    }
    private func write(_ journal: SteamResetJournal) throws {
        guard let directory = try journalDirectory(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try directory.write(JSONEncoder().encode(journal), to: id.rawValue + ".json", createOnly: false, temporaryPrefix: ".recovery-", beforeCommit: {})
        }
    }
    private func archiveDirectory(_ journal: SteamResetJournal, create: Bool) throws -> ManagedDirectory {
        guard let recovery = try rootDirectory().directory("Recovery", create: create),
              let environment = try recovery.directory(id.rawValue, create: create),
              let archive = try environment.directory(journal.token.uuidString.lowercased(), create: create)
        else { throw EnvironmentStoreError.notFound }
        return archive
    }
    private static func steamDirectory(_ prefix: ManagedDirectory, create: Bool) throws -> ManagedDirectory? {
        var current = prefix
        for component in RelativePath.steamDefault.components.dropLast() {
            guard let next = try current.directory(component, create: create) else { return nil }
            current = next
        }
        return current
    }
    var resetPending: Bool {
        get throws { try read().map { $0.phase != .restored } ?? false }
    }
    var resetNeedsCompletion: Bool {
        get throws { try read()?.phase == .prepared }
    }

    func reset(store: EnvironmentStore, checkpoint: @Sendable (SteamRecoveryCheckpoint) throws -> Void) async throws -> EnvironmentRecord {
        var journal: SteamResetJournal
        if let saved = try read(), saved.phase != .restored { journal = saved }
        else {
            guard let record = try await store.load(id), record.installationRecipeVersion == 1,
                  record.steamExecutable == .steamDefault else { throw SteamRecoveryError.unsupportedRecord }
            let prefix = try rootDirectory().directory("Environments")?.directory(id.rawValue)
            let steam = try prefix.flatMap { try Self.steamDirectory($0, create: false) }
            let libraries = try ["steamapps", "depotcache"].compactMap { name -> PreservedSteamLibrary? in
                guard let library = try steam?.directory(name) else { return nil }
                return try PreservedSteamLibrary(name: name, identity: RecoveryDirectoryIdentity(library))
            }
            journal = try SteamResetJournal(id: id, token: UUID(), original: record,
                prefixIdentity: prefix.map { try RecoveryDirectoryIdentity($0) }, libraries: libraries)
            let archive = try archiveDirectory(journal, create: true)
            try archive.write(EnvironmentDocument.encode(record), to: "original-record.json", createOnly: true, beforeCommit: {})
            try write(journal)
            try checkpoint(.prepared)
        }
        guard journal.phase == .prepared else {
            guard let record = try await store.load(id) else { throw EnvironmentStoreError.notFound }
            return record
        }
        guard let current = try await store.load(id),
              current == journal.original || (current.installation == .notStarted && current.revision == journal.original.revision + 1 &&
                current.createdAt == journal.original.createdAt && current.runtime == journal.original.runtime && current.installationRecipeVersion == 1)
        else { throw EnvironmentStoreError.conflict }
        let archive = try archiveDirectory(journal, create: false)
        let environments = try rootDirectory().directory("Environments")
        let active = try environments?.directory(id.rawValue)
        let archived = try archive.directory("prefix")
        if let expected = journal.prefixIdentity {
            if let archived {
                guard active == nil, try RecoveryDirectoryIdentity(archived) == expected else { throw EnvironmentStoreError.identityMismatch }
            } else {
                guard let active, let environments, try RecoveryDirectoryIdentity(active) == expected else { throw EnvironmentStoreError.identityMismatch }
                try environments.moveDirectory(id.rawValue, to: archive, as: "prefix")
            }
        } else if active != nil || archived != nil { throw EnvironmentStoreError.identityMismatch }
        try checkpoint(.archived)
        guard var record = try await store.load(id) else { throw EnvironmentStoreError.notFound }
        if record == journal.original {
            record.installation = .notStarted
            record = try await store.save(record)
        } else {
            guard record.installation == .notStarted, record.revision == journal.original.revision + 1,
                  record.createdAt == journal.original.createdAt, record.runtime == journal.original.runtime,
                  record.installationRecipeVersion == 1 else { throw EnvironmentStoreError.conflict }
        }
        // A previous launch receipt names the archived prefix, not its replacement.
        if let lifecycle = try rootDirectory().directory("Metadata")?.directory("Lifecycle") {
            try lifecycle.withWriteLock { try lifecycle.removeRegularFile(id.rawValue + ".json") }
        }
        try checkpoint(.metadataReset)
        journal.phase = .ready
        try write(journal)
        return record
    }

    static func restoreLibraries(root: URL, id: EnvironmentID,
                                 checkpoint: @Sendable (SteamRecoveryCheckpoint) throws -> Void = { _ in }) throws {
        let storage = SteamRecoveryArchive(root: root, id: id)
        guard var journal = try storage.read(), journal.phase != .restored else { return }
        guard journal.phase != .prepared else { throw SteamRecoveryError.pendingReset }
        guard let prefix = try storage.rootDirectory().directory("Environments")?.directory(id.rawValue) else { throw EnvironmentStoreError.notFound }
        let identity = try RecoveryDirectoryIdentity(prefix)
        if let expected = journal.newPrefixIdentity {
            guard identity == expected else { throw EnvironmentStoreError.identityMismatch }
        } else {
            journal.newPrefixIdentity = identity; journal.phase = .restoring
            try storage.write(journal)
        }
        let archive = try storage.archiveDirectory(journal, create: false)
        let oldSteam = try archive.directory("prefix").flatMap { try Self.steamDirectory($0, create: false) }
        guard let newSteam = try Self.steamDirectory(prefix, create: true) else { throw EnvironmentStoreError.notFound }
        for library in journal.libraries {
            let source = try oldSteam?.directory(library.name)
            let destination = try newSteam.directory(library.name)
            if let source {
                guard destination == nil, try RecoveryDirectoryIdentity(source) == library.identity, let oldSteam else { throw EnvironmentStoreError.conflict }
                try oldSteam.moveDirectory(library.name, to: newSteam, as: library.name)
                try checkpoint(.libraryMoved)
            } else {
                guard let destination, try RecoveryDirectoryIdentity(destination) == library.identity else { throw EnvironmentStoreError.identityMismatch }
            }
        }
        journal.phase = .restored
        try storage.write(journal)
    }
}

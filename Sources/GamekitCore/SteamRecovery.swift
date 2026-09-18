import Foundation

public enum SteamRecoveryAction: String, Sendable { case install, resumeInstaller, verifySteam, alreadyInstalled }
struct SteamRecoveryDriver: Sendable {
    let observe: @Sendable (EnvironmentRecord, URL) async -> RuntimeProcessSnapshot
    let stop: @Sendable (EnvironmentRecord, URL, String) async throws -> Void
}

/// User-directed recovery with distinct preserving and destructive reset policies.
/// Process uncertainty always refuses mutation.
public actor SteamRecovery {
    private let store: EnvironmentStore
    private let id: EnvironmentID
    private let driver: SteamRecoveryDriver
    private let quietInterval: TimeInterval
    private let checkpoint: @Sendable (SteamRecoveryCheckpoint) throws -> Void
    private var busy = false
    public init(store: EnvironmentStore, layout: RuntimeLayout, id: EnvironmentID = SteamInstallationRecipe.environmentID) {
        self.store = store; self.id = id; quietInterval = 2; checkpoint = { _ in }
        driver = .init(observe: { record, prefix in await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout) },
            stop: { record, prefix, token in
                guard let original = try ManagedDirectory.openRoot(prefix, create: false) else { throw EnvironmentStoreError.notFound }
                let identity = try original.identity()
                let report = try await RuntimeDetector().detect(layout, selection: record.runtime)
                guard report.prerequisites == .ready else { throw RuntimeSessionError.prerequisitesNotReady }
                let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
                guard snapshot.complete, snapshot.processes.allSatisfy({ $0.sessionID == token }) else { throw SteamRecoveryError.activeProcesses }
                guard let current = try ManagedDirectory.openRoot(prefix, create: false), try current.identity() == identity else { throw EnvironmentStoreError.identityMismatch }
                let result = try await ProcessExecutor().run(.init(executable: layout.wineserver, arguments: ["-k"],
                    environment: layout.environment(prefix: prefix, session: token), workingDirectory: prefix, timeout: 10, outputLimit: 8192))
                guard [.exited(0), .exited(1)].contains(result.termination), result.stderr.isEmpty else { throw SteamRecoveryError.cleanupFailed }
            })
    }
    init(store: EnvironmentStore, driver: SteamRecoveryDriver, quietInterval: TimeInterval = 0,
         checkpoint: @escaping @Sendable (SteamRecoveryCheckpoint) throws -> Void = { _ in }) {
        self.store = store; self.driver = driver; self.quietInterval = quietInterval; self.checkpoint = checkpoint
        id = SteamInstallationRecipe.environmentID
    }
    private func record() async throws -> EnvironmentRecord {
        guard let record = try await store.load(id), record.installationRecipeVersion == 1,
              record.runtime == RuntimeProfile.sikarugir.identity, record.steamExecutable == .steamDefault
        else { throw SteamRecoveryError.unsupportedRecord }
        return record
    }
    private func idle(_ record: EnvironmentRecord, prefix: URL? = nil) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(quietInterval))
        repeat {
            let snapshot = await driver.observe(record, prefix ?? store.prefixURL(for: id))
            guard snapshot.complete else { throw SteamRecoveryError.observationUnavailable }
            guard snapshot.processes.isEmpty else { throw SteamRecoveryError.activeProcesses }
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(100))
        } while true
    }
    private func executionLeaseIfPresent() async throws -> EnvironmentExecutionLease? {
        if try await store.installationFiles(id).prefixExists { return try await store.executionLease(for: id) }
        return nil
    }

    public func resetPreservingDownloads(confirmed: Bool) async throws -> EnvironmentRecord {
        try await reset(confirmed: confirmed, discardDownloads: false)
    }

    public func archives() async throws -> [SteamRecoveryArchiveInfo] {
        guard !busy else { throw EnvironmentStoreError.busy }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let complete = try await store.load(id)?.installation == .installed
        return try SteamRecoveryArchive(root: store.root, id: id).inspect(installationComplete: complete)
    }

    public func cleanArchive(_ archiveID: String, confirmed: Bool) async throws {
        guard confirmed else { throw SteamRecoveryError.confirmationRequired }
        guard let token = UUID(uuidString: archiveID), token.uuidString.lowercased() == archiveID else { throw SteamRecoveryError.invalidJournal }
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record()
        let execution = try await executionLeaseIfPresent()
        defer { withExtendedLifetime(execution) {} }
        try await idle(record)
        try await idle(record, prefix: store.root.appendingPathComponent("Recovery/\(id.rawValue)/\(archiveID)/prefix"))
        try execution?.validate()
        try Task.checkCancellation()
        try SteamRecoveryArchive(root: store.root, id: id).clean(archiveID, installationComplete: record.installation == .installed, checkpoint: checkpoint)
    }

    public func resetRemovingDownloads(confirmed: Bool) async throws -> EnvironmentRecord {
        try await reset(confirmed: confirmed, discardDownloads: true)
    }

    private func reset(confirmed: Bool, discardDownloads: Bool) async throws -> EnvironmentRecord {
        guard confirmed else { throw SteamRecoveryError.confirmationRequired }
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record()
        let execution = try await executionLeaseIfPresent()
        defer { withExtendedLifetime(execution) {} }
        try await idle(record)
        try execution?.validate()
        try Task.checkCancellation()
        return try await SteamRecoveryArchive(root: store.root, id: id).reset(store: store, discardDownloads: discardDownloads, checkpoint: checkpoint)
    }

    /// Prepares a durable, stage-appropriate action. It never launches anything;
    /// the UI then calls the corresponding installation coordinator method.
    public func prepareRetry() async throws -> SteamRecoveryAction {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        var record = try await record()
        let execution = try await executionLeaseIfPresent()
        defer { withExtendedLifetime(execution) {} }
        try await idle(record); try execution?.validate()
        let archive = SteamRecoveryArchive(root: store.root, id: id)
        if try archive.resetNeedsCompletion { record = try await archive.reset(store: store, checkpoint: checkpoint) }
        let files = try await store.installationFiles(id)
        let action: SteamRecoveryAction
        if record.installation == .installed && files.executableExists { return .alreadyInstalled }
        if !files.prefixExists { action = .install; record.installation = .notStarted }
        else if files.executableExists {
            guard record.installer != nil else { throw SteamRecoveryError.unsupportedRecord }
            action = .verifySteam; record.installation = .interrupted(.validatingInstallation)
        }
        else { action = .resumeInstaller; record.installation = .interrupted(.runningInstaller) }
        _ = try await store.save(record)
        return action
    }

    /// Explicit user-authorized adoption of one interrupted setup's tagged prefix
    /// for cancellation only. Untagged/mixed sessions are never swept.
    public func stopInterruptedSetup(confirmed: Bool) async throws {
        guard confirmed else { throw SteamRecoveryError.confirmationRequired }
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        var record = try await record()
        guard record.installation != .installed else { throw SteamRecoveryError.unsupportedRecord }
        let execution = try await store.executionLease(for: id)
        defer { withExtendedLifetime(execution) {} }
        try execution.validate()
        let snapshot = await driver.observe(record, execution.prefix)
        guard snapshot.complete else { throw SteamRecoveryError.observationUnavailable }
        if !snapshot.processes.isEmpty {
            guard let token = snapshot.processes.first?.sessionID, UUID(uuidString: token) != nil,
                  snapshot.processes.allSatisfy({ $0.sessionID == token }) else { throw SteamRecoveryError.activeProcesses }
            try await driver.stop(record, execution.prefix, token)
        }
        for attempt in 0..<30 {
            try execution.validate()
            let remaining = await driver.observe(record, execution.prefix)
            if remaining.complete && remaining.processes.isEmpty {
                if case .installing(let stage) = record.installation {
                    record.installation = .interrupted(stage); _ = try await store.save(record)
                }
                return
            }
            if attempt == 29 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let token = snapshot.processes.first?.sessionID else { throw SteamRecoveryError.cleanupFailed }
        let pinnedRecord = record
        let observe = driver.observe
        try await ScopedProcessTermination.finish {
            try execution.validate()
            let remaining = await observe(pinnedRecord, execution.prefix)
            guard remaining.complete else { throw SteamRecoveryError.observationUnavailable }
            guard remaining.processes.allSatisfy({ $0.sessionID == token }) else { throw SteamRecoveryError.activeProcesses }
            return remaining.processes
        }
        if case .installing(let stage) = record.installation {
            record.installation = .interrupted(stage); _ = try await store.save(record)
        }
    }
}

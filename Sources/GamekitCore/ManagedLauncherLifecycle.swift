import Foundation

public enum ManagedLauncherState: String, Sendable {
    case notInstalled, stopped, starting, running, unverified, foreignActivity
}
public enum ManagedLauncherStopResult: Sendable { case alreadyStopped, stopped }
public enum ManagedLauncherLifecycleError: Error, Equatable {
    case notInstalled, foreignActivity, observationUnavailable, scopeChanged, cleanupFailed
}

struct ManagedLauncherLifecycleDriver: Sendable {
    let preflight: @Sendable () async throws -> Void
    let observe: @Sendable (EnvironmentRecord, URL) async -> RuntimeProcessSnapshot
    let spawn: @Sendable (CommandRequest) async throws -> Void
    let execute: @Sendable (CommandRequest) async throws -> CommandResult
    var runtimeAvailable: @Sendable () -> Bool = { true }
}

private struct ManagedLauncherReceipt: Codable {
    let schemaVersion: Int
    let id: EnvironmentID
    let token: UUID
    let device: Int32
    let inode: UInt64
    let runtime: RuntimeIdentity
}

/// Persist a separate prefix-and-token receipt for each launcher. Neither a
/// saved PID nor a living wineserver is proof that the client is ours.
public actor ManagedLauncherLifecycle {
    private let store: EnvironmentStore
    private let layout: RuntimeLayout
    private let profile: LauncherProfile
    private let driver: ManagedLauncherLifecycleDriver
    private var busy = false
    private var emptySince: ContinuousClock.Instant?

    public init(store: EnvironmentStore, layout: RuntimeLayout, profile: LauncherProfile) throws {
        try profile.validate()
        self.store = store; self.layout = layout; self.profile = profile
        driver = .init(preflight: {
            let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
            guard report.prerequisites == .ready else { throw RuntimeSessionError.prerequisitesNotReady }
        }, observe: { record, prefix in await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout) },
        spawn: { request in try await SteamApplicationBundle.launch(request, layout: layout, launcher: profile) },
        execute: { try await ProcessExecutor().run($0) },
        runtimeAvailable: { RuntimeDetector.safeBundle(layout) && RuntimeDetector.containedRegularFile(layout.wine, root: layout.bundle)
            && RuntimeDetector.containedRegularFile(layout.wineserver, root: layout.bundle) })
    }

    init(store: EnvironmentStore, layout: RuntimeLayout, profile: LauncherProfile,
         driver: ManagedLauncherLifecycleDriver) throws {
        try profile.validate()
        self.store = store; self.layout = layout; self.profile = profile; self.driver = driver
    }

    private var filename: String { profile.id.rawValue + ".json" }
    private func receipts(create: Bool) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(store.root, create: false),
              let metadata = try root.directory("Metadata", create: create) else { return nil }
        return try metadata.directory("Lifecycle", create: create)
    }
    private func savedReceipt() throws -> ManagedLauncherReceipt? {
        guard let data = try receipts(create: false)?.read(filename) else { return nil }
        let receipt = try JSONDecoder().decode(ManagedLauncherReceipt.self, from: data)
        guard receipt.schemaVersion == 1, receipt.id == profile.id, receipt.runtime == layout.profile.identity
        else { throw ManagedLauncherLifecycleError.scopeChanged }
        return receipt
    }
    private func receipt() throws -> ManagedLauncherReceipt? {
        guard let receipt = try savedReceipt() else { return nil }
        guard let prefix = try ManagedDirectory.openRoot(store.prefixURL(for: profile.id), create: false),
              try prefix.identity() == (receipt.device, receipt.inode)
        else { throw ManagedLauncherLifecycleError.scopeChanged }
        return receipt
    }
    private func installed() async throws -> EnvironmentRecord {
        guard let record = try await store.load(profile.id), record.installation == .installed,
              record.installationRecipeVersion == 1, record.runtime == layout.profile.identity,
              record.steamExecutable == profile.executable,
              record.installer?.source == profile.installer.url,
              record.installer?.sha256 == profile.installer.sha256,
              try await store.installationFiles(profile.id).executableExists
        else { throw ManagedLauncherLifecycleError.notInstalled }
        return record
    }
    private func state(_ snapshot: RuntimeProcessSnapshot, receipt: ManagedLauncherReceipt?) -> ManagedLauncherState {
        guard snapshot.complete else { emptySince = nil; return .unverified }
        if snapshot.processes.isEmpty {
            guard receipt != nil else { emptySince = nil; return .stopped }
            if emptySince == nil { emptySince = .now }
            return emptySince!.duration(to: .now) >= .seconds(5) ? .stopped : .starting
        }
        emptySince = nil
        guard let receipt, snapshot.processes.allSatisfy({ $0.sessionID == receipt.token.uuidString }) else { return .foreignActivity }
        return snapshot.processes.contains(where: { $0.role == .launcher || $0.role == .launcherUI }) ? .running : .starting
    }

    public func status() async throws -> ManagedLauncherState {
        let record: EnvironmentRecord
        do { record = try await installed() } catch ManagedLauncherLifecycleError.notInstalled { return .notInstalled }
        guard driver.runtimeAvailable() else { return .unverified }
        return state(await driver.observe(record, store.prefixURL(for: profile.id)), receipt: try receipt())
    }

    public func diagnosticProcesses() async throws -> RuntimeProcessSnapshot {
        let record = try await installed()
        guard let owned = try receipt() else { throw ManagedLauncherLifecycleError.observationUnavailable }
        let snapshot = await driver.observe(record, store.prefixURL(for: profile.id))
        guard snapshot.complete, try receipt()?.token == owned.token,
              snapshot.processes.allSatisfy({ $0.sessionID == owned.token.uuidString })
        else { throw ManagedLauncherLifecycleError.observationUnavailable }
        return snapshot
    }

    public func launch() async throws -> ManagedLauncherState {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: profile.id)
        defer { withExtendedLifetime(lease) {} }
        let current = state(await driver.observe(record, lease.prefix), receipt: try receipt())
        if current == .running || current == .starting { return current }
        guard current == .stopped else {
            throw current == .foreignActivity ? ManagedLauncherLifecycleError.foreignActivity : .observationUnavailable
        }
        try await driver.preflight()
        try Task.checkCancellation(); try lease.validate()
        let checked = state(await driver.observe(record, lease.prefix), receipt: try receipt())
        if checked == .running || checked == .starting { return checked }
        guard checked == .stopped else {
            throw checked == .foreignActivity ? ManagedLauncherLifecycleError.foreignActivity : .observationUnavailable
        }
        let receipt = ManagedLauncherReceipt(schemaVersion: 1, id: profile.id, token: UUID(),
            device: lease.prefixIdentity.device, inode: lease.prefixIdentity.inode, runtime: layout.profile.identity)
        guard let directory = try receipts(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try directory.write(JSONEncoder().encode(receipt), to: filename, createOnly: false,
                                beforeCommit: { try lease.validate() })
        }
        let executable = lease.prefix.appendingPathComponent(profile.executable.rawValue)
        try await driver.spawn(.init(executable: layout.wine, arguments: [executable.path],
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: executable.deletingLastPathComponent(), timeout: nil, outputMode: .discard))
        emptySince = .now
        return state(await driver.observe(record, lease.prefix), receipt: receipt)
    }

    /// Return only the PID of a currently verified owned client. The native UI
    /// performs focus handoff; no URL or untrusted executable is dispatched here.
    public func show() async throws -> Int32 {
        let snapshot = try await diagnosticProcesses()
        guard let client = snapshot.processes.first(where: { $0.role == .launcher }) else {
            throw ManagedLauncherLifecycleError.observationUnavailable
        }
        return client.identity.pid
    }

    public func stop() async throws -> ManagedLauncherStopResult {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: profile.id)
        defer { withExtendedLifetime(lease) {} }
        let owned = try receipt()
        let snapshot = try await ownedSnapshot(record, lease: lease, receipt: owned)
        guard let owned else { return .alreadyStopped }
        let wasRunning = !snapshot.processes.isEmpty
        if wasRunning {
            try await driver.preflight()
            try Task.checkCancellation(); try lease.validate()
            guard try receipt()?.token == owned.token else { throw ManagedLauncherLifecycleError.scopeChanged }
            let result = try await driver.execute(.init(executable: layout.wineserver, arguments: ["-k"],
                environment: layout.environment(prefix: lease.prefix, session: owned.token.uuidString),
                workingDirectory: lease.prefix, timeout: 10, outputLimit: 8192))
            // Wine may emit nonfatal renderer output during shutdown. Only a
            // complete empty owned inventory below can retire the receipt.
            guard result.termination == .exited(0) || result.termination == .exited(1)
            else { throw ManagedLauncherLifecycleError.cleanupFailed }
        }
        for _ in 0..<40 {
            let remaining = try await ownedSnapshot(record, lease: lease, receipt: owned)
            if remaining.processes.isEmpty {
                try lease.validate()
                guard let directory = try receipts(create: false) else { throw ManagedLauncherLifecycleError.scopeChanged }
                try directory.withWriteLock {
                    guard try receipt()?.token == owned.token else { throw ManagedLauncherLifecycleError.scopeChanged }
                    try lease.validate()
                    try directory.removeRegularFile(filename)
                }
                emptySince = nil
                return wasRunning ? .stopped : .alreadyStopped
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ManagedLauncherLifecycleError.cleanupFailed
    }

    /// An explicit recovery for a quiescent, registered prefix whose device
    /// number changed across a restart. Never adopt a replacement inode or
    /// retire the receipt while any process is observed in this prefix.
    public func recoverStoppedReceipt() async throws {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: profile.id)
        defer { withExtendedLifetime(lease) {} }
        guard driver.runtimeAvailable(), let old = try savedReceipt(),
              old.inode == lease.prefixIdentity.inode, old.device != lease.prefixIdentity.device
        else { throw ManagedLauncherLifecycleError.scopeChanged }
        let snapshot = await driver.observe(record, lease.prefix)
        guard snapshot.complete else { throw ManagedLauncherLifecycleError.observationUnavailable }
        guard snapshot.processes.isEmpty else { throw ManagedLauncherLifecycleError.foreignActivity }
        try Task.checkCancellation(); try lease.validate()
        guard let directory = try receipts(create: false) else { throw ManagedLauncherLifecycleError.scopeChanged }
        try directory.withWriteLock {
            guard let saved = try savedReceipt(), saved.token == old.token,
                  saved.device == old.device, saved.inode == old.inode else { throw ManagedLauncherLifecycleError.scopeChanged }
            try lease.validate()
            try directory.removeRegularFile(filename)
        }
        emptySince = nil
    }

    private func ownedSnapshot(_ record: EnvironmentRecord, lease: EnvironmentExecutionLease,
                               receipt: ManagedLauncherReceipt?) async throws -> RuntimeProcessSnapshot {
        try lease.validate()
        let snapshot = await driver.observe(record, lease.prefix)
        try lease.validate()
        guard snapshot.complete else { throw ManagedLauncherLifecycleError.observationUnavailable }
        guard let receipt else {
            guard snapshot.processes.isEmpty else { throw ManagedLauncherLifecycleError.foreignActivity }
            return snapshot
        }
        guard snapshot.processes.allSatisfy({ $0.sessionID == receipt.token.uuidString }) else {
            throw ManagedLauncherLifecycleError.foreignActivity
        }
        return snapshot
    }
}

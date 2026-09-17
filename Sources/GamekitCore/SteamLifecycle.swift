import Foundation

public enum SteamLifecycleState: String, Sendable { case notInstalled, stopped, starting, running, unverified, foreignActivity }
public enum SteamStopResult: String, Sendable { case alreadyStopped, graceful, forced }
public enum SteamLifecycleError: Error, Equatable { case notInstalled, foreignActivity, observationUnavailable, scopeChanged, cleanupFailed }

struct SteamLifecycleDriver: Sendable {
    let preflight: @Sendable () async throws -> Void
    let observe: @Sendable (EnvironmentRecord, URL) async -> RuntimeProcessSnapshot
    let spawn: @Sendable (CommandRequest) async throws -> Void
    let execute: @Sendable (CommandRequest) async throws -> CommandResult
    var runtimeAvailable: @Sendable () -> Bool = { true }
    var signalRemaining: @Sendable ([ScopedRuntimeProcess], Int32) async throws -> Void = { _, _ in throw SteamLifecycleError.cleanupFailed }
}

private struct SteamLaunchReceipt: Codable {
    let schemaVersion: Int
    let id: EnvironmentID
    let token: UUID
    let device: Int32
    let inode: UInt64
    let runtime: RuntimeIdentity
}

/// Persistent session ownership is a prefix identity plus a fresh launch token,
/// never a saved PID. Each control operation reacquires a short-lived execution lease.
public actor SteamLifecycle {
    private let store: EnvironmentStore
    private let layout: RuntimeLayout
    private let id: EnvironmentID
    private let driver: SteamLifecycleDriver
    private let gracefulTimeout: TimeInterval
    private var busy = false
    private var emptySince: ContinuousClock.Instant?

    public init(store: EnvironmentStore, layout: RuntimeLayout, id: EnvironmentID = SteamInstallationRecipe.environmentID) {
        self.store = store; self.layout = layout; self.id = id; gracefulTimeout = 30
        driver = .init(preflight: {
            let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
            guard report.prerequisites == .ready else { throw RuntimeSessionError.prerequisitesNotReady }
        }, observe: { record, prefix in await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout) },
        spawn: { request in
            try await SteamApplicationBundle.launch(request, layout: layout)
            guard let record = try await store.load(id), let token = request.environment["GAMEKIT_SESSION_ID"] else { throw SteamLifecycleError.notInstalled }
            for _ in 0..<120 {
                try Task.checkCancellation()
                let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: id), layout: layout)
                guard snapshot.complete else { try await Task.sleep(for: .milliseconds(250)); continue }
                guard snapshot.processes.allSatisfy({ $0.sessionID == token }) else { throw SteamLifecycleError.foreignActivity }
                if snapshot.processes.contains(where: { $0.role == .steamUI }) {
                    try await Task.sleep(for: .seconds(2))
                    let steam = store.prefixURL(for: id).appendingPathComponent(record.steamExecutable.rawValue)
                    _ = try await ProcessExecutor().run(.init(executable: layout.wine, arguments: [steam.path, "steam://open/main"],
                        environment: request.environment, workingDirectory: steam.deletingLastPathComponent(), timeout: 10, outputLimit: 8192))
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }, execute: { try await ProcessExecutor().run($0) },
        runtimeAvailable: { RuntimeDetector.safeBundle(layout) && RuntimeDetector.containedRegularFile(layout.wine, root: layout.bundle)
            && RuntimeDetector.containedRegularFile(layout.wineserver, root: layout.bundle) },
        signalRemaining: { try ScopedProcessTermination.signal($0, signal: $1) })
    }
    init(store: EnvironmentStore, driver: SteamLifecycleDriver, gracefulTimeout: TimeInterval = 30) {
        self.store = store; self.driver = driver; self.gracefulTimeout = gracefulTimeout
        layout = RuntimeLayout(dataRoot: store.root); id = SteamInstallationRecipe.environmentID
    }

    private func receipts(create: Bool) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(store.root, create: false),
              let metadata = try root.directory("Metadata", create: create) else { return nil }
        return try metadata.directory("Lifecycle", create: create)
    }
    private var filename: String { id.rawValue + ".json" }
    private func receipt() throws -> SteamLaunchReceipt? {
        guard let data = try receipts(create: false)?.read(filename) else { return nil }
        let receipt = try JSONDecoder().decode(SteamLaunchReceipt.self, from: data)
        guard receipt.schemaVersion == 1, receipt.id == id, receipt.runtime == layout.profile.identity else { throw SteamLifecycleError.scopeChanged }
        guard let prefix = try ManagedDirectory.openRoot(store.prefixURL(for: id), create: false),
              try prefix.identity() == (receipt.device, receipt.inode) else { throw SteamLifecycleError.scopeChanged }
        return receipt
    }
    private func installed() async throws -> EnvironmentRecord {
        guard let record = try await store.load(id), record.installation == .installed,
              record.installationRecipeVersion == 1, record.runtime == layout.profile.identity,
              try await store.installationFiles(id).executableExists else { throw SteamLifecycleError.notInstalled }
        return record
    }
    private func state(_ snapshot: RuntimeProcessSnapshot, receipt: SteamLaunchReceipt?) -> SteamLifecycleState {
        guard snapshot.complete else { emptySince = nil; return .unverified }
        if snapshot.processes.isEmpty {
            guard receipt != nil else { emptySince = nil; return .stopped }
            // Do not interpret a short updater handoff gap as permission to launch again.
            if emptySince == nil { emptySince = .now }
            return emptySince!.duration(to: .now) >= .seconds(5) ? .stopped : .starting
        }
        emptySince = nil
        guard let receipt, snapshot.processes.allSatisfy({ $0.sessionID == receipt.token.uuidString }) else { return .foreignActivity }
        return snapshot.processes.contains { $0.role == .steam || $0.role == .steamUI } ? .running : .starting
    }
    public func status() async throws -> SteamLifecycleState {
        let record: EnvironmentRecord
        do { record = try await installed() } catch SteamLifecycleError.notInstalled { return .notInstalled }
        guard driver.runtimeAvailable() else { return .unverified }
        let receipt = try receipt()
        return state(await driver.observe(record, store.prefixURL(for: id)), receipt: receipt)
    }

    public func launch() async throws -> SteamLifecycleState {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        let current = state(await driver.observe(record, lease.prefix), receipt: try receipt())
        if current == .running || current == .starting { return current }
        guard current != .foreignActivity else { throw SteamLifecycleError.foreignActivity }
        guard current == .stopped else { throw SteamLifecycleError.observationUnavailable }
        try await driver.preflight()
        try Task.checkCancellation(); try lease.validate()
        let rechecked = state(await driver.observe(record, lease.prefix), receipt: try receipt())
        if rechecked == .running || rechecked == .starting { return rechecked }
        guard rechecked == .stopped else {
            throw rechecked == .foreignActivity ? SteamLifecycleError.foreignActivity : .observationUnavailable
        }
        let receipt = SteamLaunchReceipt(schemaVersion: 1, id: id, token: UUID(), device: lease.prefixIdentity.device,
            inode: lease.prefixIdentity.inode, runtime: layout.profile.identity)
        guard let directory = try receipts(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try directory.write(JSONEncoder().encode(receipt), to: filename, createOnly: false, beforeCommit: { try lease.validate() })
        }
        try publishGameNames(record: record, lease: lease, receipt: receipt)
        let steam = lease.prefix.appendingPathComponent(record.steamExecutable.rawValue)
        // Suppress the separate bootstrapper UI, then explicitly open the main
        // web UI. This avoids retaining an empty client-side Dock application.
        try await driver.spawn(.init(executable: layout.wine, arguments: [steam.path, "-silent"],
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: steam.deletingLastPathComponent(), timeout: nil, outputMode: .discard))
        emptySince = .now
        return state(await driver.observe(record, lease.prefix), receipt: receipt)
    }

    private func ownedSnapshot(_ record: EnvironmentRecord, lease: EnvironmentExecutionLease,
                               receipt: SteamLaunchReceipt) async throws -> RuntimeProcessSnapshot {
        try lease.validate()
        let snapshot = await driver.observe(record, lease.prefix)
        try lease.validate()
        guard snapshot.complete else { throw SteamLifecycleError.observationUnavailable }
        guard snapshot.processes.allSatisfy({ $0.sessionID == receipt.token.uuidString }) else { throw SteamLifecycleError.foreignActivity }
        return snapshot
    }
    public func show() async throws {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        guard let receipt = try receipt() else { throw SteamLifecycleError.foreignActivity }
        try await driver.preflight()
        guard try await !ownedSnapshot(record, lease: lease, receipt: receipt).processes.isEmpty else { throw SteamLifecycleError.notInstalled }
        let steam = lease.prefix.appendingPathComponent(record.steamExecutable.rawValue)
        let result = try await driver.execute(.init(executable: layout.wine, arguments: [steam.path, "steam://open/main"],
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: steam.deletingLastPathComponent(), timeout: 10, outputLimit: 8192))
        guard result.termination == .exited(0) else { throw SteamLifecycleError.observationUnavailable }
    }

    /// Send a numeric AppID to the owned Windows client, never the host's Steam
    /// URL handler or a manifest-supplied executable. Success means request sent.
    public func launchGame(appID: UInt32) async throws {
        let initial = try await installed()
        guard try SteamGameLibrary.scan(prefix: store.prefixURL(for: id), steamExecutable: initial.steamExecutable)
            .games.contains(where: { $0.id == appID && $0.state == .ready }) else { throw SteamGameLibraryError.notInstalled }
        _ = try await launch()
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        guard let receipt = try receipt() else { throw SteamLifecycleError.foreignActivity }
        try await driver.preflight()
        var clientReady = false
        for _ in 0..<120 {
            try Task.checkCancellation()
            let snapshot = try await ownedSnapshot(record, lease: lease, receipt: receipt)
            if snapshot.processes.contains(where: { $0.role == .steam || $0.role == .steamUI }) { clientReady = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard clientReady else { throw SteamLifecycleError.observationUnavailable }
        guard try SteamGameLibrary.scan(prefix: lease.prefix, steamExecutable: record.steamExecutable)
            .games.contains(where: { $0.id == appID && $0.state == .ready }) else { throw SteamGameLibraryError.notInstalled }
        try publishGameNames(record: record, lease: lease, receipt: receipt)
        try lease.validate()
        let steam = lease.prefix.appendingPathComponent(record.steamExecutable.rawValue)
        let result = try await driver.execute(.init(executable: layout.wine,
            arguments: [steam.path, "-applaunch", String(appID)],
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: steam.deletingLastPathComponent(), timeout: 10, outputLimit: 8192))
        guard result.termination == .exited(0) else { throw SteamLifecycleError.observationUnavailable }
    }
    private func publishGameNames(record: EnvironmentRecord, lease: EnvironmentExecutionLease, receipt: SteamLaunchReceipt) throws {
        guard layout.hasGameIdentityHelper else { return }
        let games = try SteamGameLibrary.scan(prefix: lease.prefix, steamExecutable: record.steamExecutable).games
        try GameDockNames.publish(root: store.root, prefix: lease.prefix, session: receipt.token, games: games,
                                  validate: { try lease.validate() })
    }

    /// Refresh the map for games installed through Steam while Gamekit is open.
    public func refreshGameNames() async throws {
        guard layout.hasGameIdentityHelper else { return }
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        guard let receipt = try receipt() else { return }
        _ = try await ownedSnapshot(record, lease: lease, receipt: receipt)
        try publishGameNames(record: record, lease: lease, receipt: receipt)
    }

    public func stop() async throws -> SteamStopResult {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        guard let receipt = try receipt() else {
            let snapshot = await driver.observe(record, lease.prefix)
            guard snapshot.complete else { throw SteamLifecycleError.observationUnavailable }
            guard snapshot.processes.isEmpty else { throw SteamLifecycleError.foreignActivity }
            return .alreadyStopped
        }
        let before = try await ownedSnapshot(record, lease: lease, receipt: receipt)
        if before.processes.isEmpty {
            let quietUntil = ContinuousClock.now.advanced(by: .seconds(min(2, gracefulTimeout)))
            var quiet = true
            while ContinuousClock.now < quietUntil {
                try await Task.sleep(for: .milliseconds(100))
                if try await !ownedSnapshot(record, lease: lease, receipt: receipt).processes.isEmpty { quiet = false; break }
            }
            if quiet { try clearReceipt(); return .alreadyStopped }
        }
        // Even an empty instant may be a handoff. Keep checking through the normal
        // graceful interval instead of deleting ownership and racing a late child.
        try await driver.preflight()
        _ = try await ownedSnapshot(record, lease: lease, receipt: receipt)
        let deadline = ContinuousClock.now.advanced(by: .seconds(gracefulTimeout))
        if !before.processes.isEmpty {
            let steam = lease.prefix.appendingPathComponent(record.steamExecutable.rawValue)
            _ = try await driver.execute(.init(executable: layout.wine, arguments: [steam.path, "-shutdown"],
                environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
                workingDirectory: steam.deletingLastPathComponent(), timeout: gracefulTimeout, outputLimit: 8192))
        }
        var emptyAt: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            let snapshot = try await ownedSnapshot(record, lease: lease, receipt: receipt)
            if snapshot.processes.isEmpty {
                if emptyAt == nil { emptyAt = .now }
                if emptyAt!.duration(to: .now) >= .seconds(min(2, gracefulTimeout / 2)) {
                    try clearReceipt(); return .graceful
                }
            } else { emptyAt = nil }
            try await Task.sleep(for: .milliseconds(100))
        }
        let remaining = try await ownedSnapshot(record, lease: lease, receipt: receipt)
        if remaining.processes.isEmpty { try clearReceipt(); return .graceful }
        let result = try await driver.execute(.init(executable: layout.wineserver, arguments: ["-k"],
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: lease.prefix, timeout: 10, outputLimit: 8192))
        guard [.exited(0), .exited(1)].contains(result.termination), result.stderr.isEmpty else { throw SteamLifecycleError.cleanupFailed }
        for _ in 0..<30 {
            if try await ownedSnapshot(record, lease: lease, receipt: receipt).processes.isEmpty {
                try clearReceipt(); return .forced
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Wine device services can outlive the server. Escalate only against fresh
        // token-owned identities, using kernel PID-version checked audit tokens.
        try await driver.signalRemaining(try await ownedSnapshot(record, lease: lease, receipt: receipt).processes, SIGTERM)
        try await Task.sleep(for: .milliseconds(500))
        try await driver.signalRemaining(try await ownedSnapshot(record, lease: lease, receipt: receipt).processes, SIGKILL)
        for _ in 0..<30 {
            if try await ownedSnapshot(record, lease: lease, receipt: receipt).processes.isEmpty {
                try clearReceipt(); return .forced
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SteamLifecycleError.cleanupFailed
    }
    private func clearReceipt() throws {
        if let directory = try receipts(create: false) {
            try directory.withWriteLock { try directory.removeRegularFile(filename) }
        }
        emptySince = nil
    }
}

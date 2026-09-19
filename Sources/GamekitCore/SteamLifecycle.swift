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
            // Observed cold starts exceed 45s. Do not abandon opening Steam's
            // UI at 30s while -silent can leave a later Cloud/login prompt hidden.
            // This waits for presentation only; it never retries a game request.
            for _ in 0..<360 {
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

    /// Read-only diagnostic observation; no lease is held for the duration of a
    /// capture, so diagnostics cannot prevent the user from stopping Steam.
    public func diagnosticProcesses() async throws -> RuntimeProcessSnapshot {
        let record = try await installed()
        guard let before = try receipt() else { throw SteamLifecycleError.observationUnavailable }
        let snapshot = await driver.observe(record, store.prefixURL(for: id))
        guard snapshot.complete, try receipt()?.token == before.token,
              snapshot.processes.allSatisfy({ $0.sessionID == before.token.uuidString }) else {
            throw SteamLifecycleError.observationUnavailable
        }
        return snapshot
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
        if layout.profile.revision == .driverVersion1 && layout.hasGameIdentityHelper,
           let game = try SteamGameLibrary.scan(prefix: lease.prefix, steamExecutable: record.steamExecutable).games.first(where: { $0.id == 553850 && $0.state == .ready }) {
            // Prepare routing even when the user opens Steam first and starts
            // Helldivers from its library rather than from Gamekit's tile.
            _ = try await SteamApplicationBundle.configured(layout: layout, game: .init(appID: game.id, name: game.name)).prepare()
            try Task.checkCancellation(); try lease.validate()
        }
        let receipt = SteamLaunchReceipt(schemaVersion: 1, id: id, token: UUID(), device: lease.prefixIdentity.device,
            inode: lease.prefixIdentity.inode, runtime: layout.profile.identity)
        guard let directory = try receipts(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try directory.write(JSONEncoder().encode(receipt), to: filename, createOnly: false, beforeCommit: { try lease.validate() })
        }
        try await publishGameNames(record: record, lease: lease, receipt: receipt)
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
    @discardableResult public func launchGame(appID: UInt32) async throws -> SteamGameLaunchObservation {
        let initial = try await installed()
        guard let game = try SteamGameLibrary.scan(prefix: store.prefixURL(for: id), steamExecutable: initial.steamExecutable)
            .games.first(where: { $0.id == appID && $0.state == .ready }) else { throw SteamGameLibraryError.notInstalled }
        let logs = store.prefixURL(for: id).appendingPathComponent(initial.steamExecutable.rawValue)
            .deletingLastPathComponent().appendingPathComponent("logs")
        let launchLog = try? SteamLaunchLogTail(directory: logs)
        if layout.hasGameIdentityHelper {
            _ = try await SteamApplicationBundle.configured(layout: layout, game: .init(appID: game.id, name: game.name)).prepare()
        }
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
        try await publishGameNames(record: record, lease: lease, receipt: receipt)
        try lease.validate()
        let steam = lease.prefix.appendingPathComponent(record.steamExecutable.rawValue)
        let backend = try (GameCompatibilityPreferences.read(root: store.root).graphicsBackends[String(appID)] ?? .inherit)
            .effectiveBackend(shared: layout.graphicsBackend)
        let result = try await driver.execute(.init(executable: layout.wine,
            arguments: [steam.path, "-applaunch", String(appID)] + backend.launchOptions(appID: appID),
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: steam.deletingLastPathComponent(), timeout: 10, outputLimit: 8192))
        guard result.termination == .exited(0) else { throw SteamLifecycleError.observationUnavailable }
        return SteamGameLaunchObservation(appID: appID, tail: launchLog) { [self] in
            guard let current = try await self.receipt(), current.token == receipt.token else { throw SteamLifecycleError.scopeChanged }
            let snapshot = try await self.diagnosticProcesses()
            guard snapshot.processes.allSatisfy({ $0.sessionID == receipt.token.uuidString }) else { throw SteamLifecycleError.foreignActivity }
        }
    }
    private func publishGameNames(record: EnvironmentRecord, lease: EnvironmentExecutionLease, receipt: SteamLaunchReceipt) async throws {
        guard layout.hasGameIdentityHelper else { return }
        let games = try SteamGameLibrary.scan(prefix: lease.prefix, steamExecutable: record.steamExecutable).games
        var loaders: [String: String] = [:]
        for game in games {
            let bundle = try SteamApplicationBundle.configured(layout: layout, game: .init(appID: game.id, name: game.name))
            if game.state == .ready && bundle.hasAlternativeGraphics {
                _ = try await bundle.prepare()
                try Task.checkCancellation(); try lease.validate()
            }
            if FileManager.default.fileExists(atPath: bundle.bundleURL.path) {
                try bundle.validate(bundle.bundleURL)
                loaders[String(game.id)] = bundle.executable.path
            }
        }
        try GameDockNames.publish(root: store.root, prefix: lease.prefix, session: receipt.token, games: games,
                                  steamExecutable: record.steamExecutable, loaders: loaders,
                                  defaultLoader: SteamApplicationBundle(layout: layout).executable.path,
                                  graphicsBackend: layout.graphicsBackend,
                                  libraryLayout: layout,
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
        try await publishGameNames(record: record, lease: lease, receipt: receipt)
    }

    /// Shutdown can race an exiting process between the observer's identity
    /// reads. Retry observation only, never act on a partial inventory. The
    /// budget is shared by the whole Stop operation, including escalation.
    private func shutdownSnapshot(_ record: EnvironmentRecord, lease: EnvironmentExecutionLease,
                                  receipt: SteamLaunchReceipt?, retries: inout Int) async throws -> (snapshot: RuntimeProcessSnapshot, hadGap: Bool) {
        var hadGap = false
        while true {
            try Task.checkCancellation()
            try lease.validate()
            let snapshot = await driver.observe(record, lease.prefix)
            try lease.validate()
            try Task.checkCancellation()
            guard snapshot.processes.allSatisfy({ receipt != nil && $0.sessionID == receipt?.token.uuidString }) else {
                throw SteamLifecycleError.foreignActivity
            }
            if snapshot.complete { return (snapshot, hadGap) }
            guard retries > 0 else { throw SteamLifecycleError.observationUnavailable }
            retries -= 1
            hadGap = true
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public func stop() async throws -> SteamStopResult {
        guard !busy else { throw EnvironmentStoreError.busy }
        busy = true; defer { busy = false }
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await installed()
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        var observationRetries = 3
        guard let receipt = try receipt() else {
            _ = try await shutdownSnapshot(record, lease: lease, receipt: nil, retries: &observationRetries)
            return .alreadyStopped
        }
        let before = try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries).snapshot
        if before.processes.isEmpty {
            var quietUntil = ContinuousClock.now.advanced(by: .seconds(min(2, gracefulTimeout)))
            var quiet = true
            while ContinuousClock.now < quietUntil {
                try await Task.sleep(for: .milliseconds(100))
                let observed = try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries)
                if !observed.snapshot.processes.isEmpty { quiet = false; break }
                if observed.hadGap { quietUntil = .now.advanced(by: .seconds(min(2, gracefulTimeout))) }
            }
            if quiet { try clearReceipt(); return .alreadyStopped }
        }
        // Even an empty instant may be a handoff. Keep checking through the normal
        // graceful interval instead of deleting ownership and racing a late child.
        try await driver.preflight()
        _ = try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries)
        let deadline = ContinuousClock.now.advanced(by: .seconds(gracefulTimeout))
        if !before.processes.isEmpty {
            let steam = lease.prefix.appendingPathComponent(record.steamExecutable.rawValue)
            _ = try await driver.execute(.init(executable: layout.wine, arguments: [steam.path, "-shutdown"],
                environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
                workingDirectory: steam.deletingLastPathComponent(), timeout: gracefulTimeout, outputLimit: 8192))
        }
        var emptyAt: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            let observed = try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries)
            let snapshot = observed.snapshot
            if observed.hadGap { emptyAt = nil }
            if snapshot.processes.isEmpty {
                if emptyAt == nil { emptyAt = .now }
                if emptyAt!.duration(to: .now) >= .seconds(min(2, gracefulTimeout / 2)) {
                    try clearReceipt(); return .graceful
                }
            } else { emptyAt = nil }
            try await Task.sleep(for: .milliseconds(100))
        }
        let remaining = try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries).snapshot
        if remaining.processes.isEmpty { try clearReceipt(); return .graceful }
        let result = try await driver.execute(.init(executable: layout.wineserver, arguments: ["-k"],
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: lease.prefix, timeout: 10, outputLimit: 8192))
        guard [.exited(0), .exited(1)].contains(result.termination), result.stderr.isEmpty else { throw SteamLifecycleError.cleanupFailed }
        for _ in 0..<30 {
            if try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries).snapshot.processes.isEmpty {
                try clearReceipt(); return .forced
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Wine device services can outlive the server. Escalate only against fresh
        // token-owned identities, using kernel PID-version checked audit tokens.
        try await driver.signalRemaining(try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries).snapshot.processes, SIGTERM)
        try await Task.sleep(for: .milliseconds(500))
        try await driver.signalRemaining(try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries).snapshot.processes, SIGKILL)
        for _ in 0..<30 {
            if try await shutdownSnapshot(record, lease: lease, receipt: receipt, retries: &observationRetries).snapshot.processes.isEmpty {
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

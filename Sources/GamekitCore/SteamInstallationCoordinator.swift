import Foundation

public enum SteamInstallationError: Error, Equatable {
    case recoveryRequired, prerequisitesNotReady, commandFailed, timedOut, steamNotObserved, confirmationDeclined
}

public enum SteamInstallationRecipe {
    public static let version = 1
    public static let environmentID = try! EnvironmentID("steam")
    // E2's baseline Windows command initializes Wine without registry overrides.
    public static let initializeArguments = ["cmd", "/c", "ver"]
}

struct SteamInstallationProcess: Sendable {
    let leaderExit: @Sendable () async -> CommandTermination?
    let snapshot: @Sendable () async throws -> RuntimeProcessSnapshot
    let stop: @Sendable () async throws -> Void
}
struct SteamInstallationDriver: Sendable {
    let preflight: @Sendable () async throws -> Void
    let acquire: @Sendable () async throws -> InstallerArtifact
    let artifactURL: @Sendable (InstallerArtifact) async throws -> URL
    let start: @Sendable (EnvironmentRecord, [String], TimeInterval, DiagnosticOperation?) async throws -> SteamInstallationProcess
}

/// Fresh installation only. Restart/retry of a partial prefix requires explicit
/// recovery. The confirmation callback means a person has seen a usable Steam UI.
public actor SteamInstallationCoordinator {
    private let store: EnvironmentStore
    private let driver: SteamInstallationDriver
    private let diagnostics: DiagnosticStore?
    private var running = false
    private var lease: ManagedFileLock?
    private var process: SteamInstallationProcess?
    public private(set) var diagnosticsUnavailable = false

    public init(store: EnvironmentStore, layout: RuntimeLayout, acquisition: SteamInstallerAcquisition,
                diagnostics: DiagnosticStore? = nil) {
        self.store = store; self.diagnostics = diagnostics
        driver = SteamInstallationDriver(preflight: {
            let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
            guard report.prerequisites == .ready else { throw SteamInstallationError.prerequisitesNotReady }
        }, acquire: { try await acquisition.acquire() }, artifactURL: { try await acquisition.validatedURL(for: $0) },
        start: { record, arguments, timeout, operation in
            let session = try await RuntimeSession.start(store: store, id: record.id, layout: layout,
                arguments: arguments, timeout: timeout, onOutput: { operation?.receive($0) })
            return SteamInstallationProcess(leaderExit: { await session.command.observedLeaderExit() },
                snapshot: { try await session.snapshot() }, stop: { _ = try await session.stop() })
        })
    }
    init(store: EnvironmentStore, driver: SteamInstallationDriver, diagnostics: DiagnosticStore? = nil) {
        self.store = store; self.driver = driver; self.diagnostics = diagnostics
    }

    public func install(id: EnvironmentID = SteamInstallationRecipe.environmentID,
                        onStage: @escaping @Sendable (InstallationStage) async -> Void = { _ in },
                        confirmUsableUI: @escaping @Sendable () async throws -> Bool) async throws -> EnvironmentRecord {
        try await execute(id: id, verificationOnly: false, onStage: onStage, confirmUsableUI: confirmUsableUI)
    }

    /// Explicitly retries only bootstrap/UI verification after that phase failed or
    /// was interrupted. Never reruns an installer or initializes an existing prefix.
    public func verifyExistingInstallation(id: EnvironmentID = SteamInstallationRecipe.environmentID,
                        onStage: @escaping @Sendable (InstallationStage) async -> Void = { _ in },
                        confirmUsableUI: @escaping @Sendable () async throws -> Bool) async throws -> EnvironmentRecord {
        try await execute(id: id, verificationOnly: true, onStage: onStage, confirmUsableUI: confirmUsableUI)
    }

    public func resumeInstaller(id: EnvironmentID = SteamInstallationRecipe.environmentID,
                        onStage: @escaping @Sendable (InstallationStage) async -> Void = { _ in },
                        confirmUsableUI: @escaping @Sendable () async throws -> Bool) async throws -> EnvironmentRecord {
        try await execute(id: id, verificationOnly: false, resumeExisting: true, onStage: onStage, confirmUsableUI: confirmUsableUI)
    }

    private func execute(id: EnvironmentID, verificationOnly: Bool,
                         resumeExisting: Bool = false,
                         onStage: @escaping @Sendable (InstallationStage) async -> Void,
                         confirmUsableUI: @escaping @Sendable () async throws -> Bool) async throws -> EnvironmentRecord {
        guard !running, process == nil else { throw EnvironmentStoreError.busy }
        running = true
        defer { running = false; if process == nil { lease = nil } }
        lease = try await store.installationLease()
        guard try !SteamRecoveryArchive(root: store.root, id: id).resetNeedsCompletion else { throw SteamRecoveryError.pendingReset }
        let existing = try await store.load(id)
        if let existing {
            let files = try await store.installationFiles(id)
            guard existing.installationRecipeVersion == SteamInstallationRecipe.version,
                  existing.runtime == RuntimeProfile.sikarugir.identity, existing.steamExecutable == .steamDefault
            else { throw SteamInstallationError.recoveryRequired }
            if resumeExisting {
                guard files.prefixExists, !files.executableExists,
                      [.interrupted(.creatingPrefix), .interrupted(.runningInstaller), .failed(.installerFailed)].contains(existing.installation)
                else { throw SteamInstallationError.recoveryRequired }
            } else if !verificationOnly && existing.installation == .notStarted && !files.prefixExists {
                // Explicit recovery prepared this existing record for a fresh prefix.
            } else if !verificationOnly {
                guard files.prefixExists, files.executableExists else { throw SteamInstallationError.recoveryRequired }
                guard existing.installation == .installed else { throw SteamInstallationError.recoveryRequired }
                return existing
            } else {
                guard files.prefixExists, files.executableExists, existing.installer != nil,
                      [.failed(.bootstrapFailed), .interrupted(.bootstrappingSteam), .interrupted(.validatingInstallation)].contains(existing.installation)
                else { throw SteamInstallationError.recoveryRequired }
            }
        } else if verificationOnly || resumeExisting {
            throw SteamInstallationError.recoveryRequired
        }
        try Task.checkCancellation()
        try await driver.preflight()
        var record: EnvironmentRecord
        if let existing { record = existing }
        else {
            record = try await store.create(EnvironmentRecord(id: id, name: "Windows Steam", runtime: RuntimeProfile.sikarugir.identity,
                installation: .installing(.downloadingInstaller), installationRecipeVersion: SteamInstallationRecipe.version))
        }
        var stage: InstallationStage = verificationOnly ? .bootstrappingSteam : .downloadingInstaller
        let operation: DiagnosticOperation?
        do { operation = try await diagnostics?.begin(stage: verificationOnly ? .bootstrap : .download, context: .init(component: .installer, environmentID: id, runtimeSelection: record.runtime)) }
        catch { operation = nil; diagnosticsUnavailable = true }
        do {
            if !verificationOnly {
                record = try await advance(record, to: .downloadingInstaller, operation: operation)
                await onStage(stage)
                let artifact = try await driver.acquire()
                try Task.checkCancellation()
                record.installer = artifact.provenance
                stage = .creatingPrefix
                record = try await advance(record, to: stage, operation: operation)
                await onStage(stage)
                if resumeExisting { _ = try await store.checkedPrefixURL(for: id) }
                else { try await store.createInstallationPrefix(record) }
                try await runCommand(record, arguments: SteamInstallationRecipe.initializeArguments, timeout: 180, operation: operation)
                try SteamRecoveryArchive.restoreLibraries(root: store.root, id: id)
                stage = .runningInstaller
                record = try await advance(record, to: stage, operation: operation)
                await onStage(stage)
                let artifactURL = try await driver.artifactURL(artifact)
                try await runCommand(record, arguments: [artifactURL.path], timeout: 1200, operation: operation)
            }
            if verificationOnly { try SteamRecoveryArchive.restoreLibraries(root: store.root, id: id) }
            guard try await store.installationFiles(id).executableExists else { throw SteamInstallationError.commandFailed }
            stage = .bootstrappingSteam
            record = try await advance(record, to: stage, operation: operation)
            await onStage(stage)
            let prefix = try await store.checkedPrefixURL(for: id)
            process = try await driver.start(record, [prefix.appendingPathComponent(record.steamExecutable.rawValue).path], 1200, operation)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1200))
            while !(try await steamObserved()) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw SteamInstallationError.timedOut }
                // A launcher exit is not a failure verdict while the updater hands off.
                try await Task.sleep(for: .milliseconds(250))
            }
            stage = .validatingInstallation
            record = try await advance(record, to: stage, operation: operation)
            await onStage(stage)
            let confirmed = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { try await confirmUsableUI() }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw SteamInstallationError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            guard confirmed else { throw SteamInstallationError.confirmationDeclined }
            try Task.checkCancellation()
            guard try await steamObserved(), try await store.installationFiles(id).executableExists else {
                throw SteamInstallationError.steamNotObserved
            }
            // Setup verification ends with scoped cleanup. Ongoing launch/stop UI is E4.3.
            try await stopProcess()
            record.installation = .installed
            record = try await store.save(record)
            await finishDiagnostic(operation, outcome: .exited(0))
            return record
        } catch {
            let original = error
            do { try await stopProcess() }
            catch {
                // Retain the lease and process on cleanup refusal. Never declare idle
                // or permit another install merely because the async task ended.
                await finishDiagnostic(operation, outcome: .executionFailed)
                throw error
            }
            let persistedStage: InstallationStage
            if case .installing(let value) = record.installation { persistedStage = value } else { persistedStage = stage }
            let cancelled = original is CancellationError || original as? SteamInstallationError == .confirmationDeclined
            record.installation = cancelled ? .interrupted(persistedStage) : .failed(persistedStage == .downloadingInstaller ? .downloadFailed :
                (persistedStage == .bootstrappingSteam || persistedStage == .validatingInstallation ? .bootstrapFailed : .installerFailed))
            do { _ = try await store.save(record) }
            catch { await finishDiagnostic(operation, outcome: .executionFailed); throw error }
            await finishDiagnostic(operation, outcome: cancelled ? .cancelled : original as? SteamInstallationError == .timedOut ? .timedOut : .executionFailed)
            throw original
        }
    }

    private func advance(_ record: EnvironmentRecord, to stage: InstallationStage, operation: DiagnosticOperation?) async throws -> EnvironmentRecord {
        try Task.checkCancellation()
        var updated = record; updated.installation = .installing(stage)
        let saved = try await store.save(updated)
        if let operation {
            do { try await diagnostics?.transition(operation, to: stage == .downloadingInstaller ? .download : stage == .bootstrappingSteam ? .bootstrap : stage == .validatingInstallation ? .rendering : .installation) }
            catch { diagnosticsUnavailable = true }
        }
        return saved
    }
    private func runCommand(_ record: EnvironmentRecord, arguments: [String], timeout: TimeInterval, operation: DiagnosticOperation?) async throws {
        process = try await driver.start(record, arguments, timeout, operation)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while let process {
            try Task.checkCancellation()
            if let result = await process.leaderExit() {
                guard result == .exited(0) else { throw SteamInstallationError.commandFailed }
                try await stopProcess()
                return
            }
            guard ContinuousClock.now < deadline else { throw SteamInstallationError.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func steamObserved() async throws -> Bool {
        guard let process else { return false }
        let snapshot = try await process.snapshot()
        return snapshot.complete && snapshot.processes.contains { $0.role == .steam }
    }
    private func stopProcess() async throws {
        guard let process else { return }
        try await Task.detached { try await process.stop() }.value
        self.process = nil
    }
    private func finishDiagnostic(_ operation: DiagnosticOperation?, outcome: DiagnosticOutcome) async {
        if let operation {
            do { _ = try await diagnostics?.finish(operation, outcome: outcome) }
            catch { diagnosticsUnavailable = true }
        }
    }
}

import Foundation

public enum ManagedLauncherInstallationError: Error, Equatable {
    case recoveryRequired, prerequisitesNotReady, commandFailed, timedOut, clientNotObserved
}

struct ManagedLauncherInstallProcess: Sendable {
    let leaderExit: @Sendable () async -> CommandTermination?
    let snapshot: @Sendable () async throws -> RuntimeProcessSnapshot
    let stop: @Sendable () async throws -> Void
}

struct ManagedLauncherInstallationDriver: Sendable {
    let preflight: @Sendable () async throws -> Void
    let acquire: @Sendable () async throws -> InstallerArtifact
    let artifactURL: @Sendable (InstallerArtifact) async throws -> URL
    let start: @Sendable (EnvironmentRecord, [String], TimeInterval) async throws -> ManagedLauncherInstallProcess
    let uiReady: @Sendable (RuntimeProcessSnapshot) -> Bool
    var readinessStability: TimeInterval = 3
}

/// Separate launcher installation state and prefix, with the same global
/// installation lease and fail-closed scoped cleanup used for managed Steam.
public actor ManagedLauncherInstallationCoordinator {
    private enum Mode { case install, resume, verify }
    private let store: EnvironmentStore
    private let layout: RuntimeLayout
    private let profile: LauncherProfile
    private let driver: ManagedLauncherInstallationDriver
    private let diagnostics: DiagnosticStore?
    private var running = false
    private var lease: ManagedFileLock?
    private var process: ManagedLauncherInstallProcess?
    public private(set) var diagnosticsUnavailable = false

    public init(store: EnvironmentStore, layout: RuntimeLayout, profile: LauncherProfile,
                acquisition suppliedAcquisition: ManagedLauncherInstallerAcquisition? = nil,
                diagnostics: DiagnosticStore? = nil) throws {
        try profile.validate()
        self.store = store; self.layout = layout; self.profile = profile; self.diagnostics = diagnostics
        let acquisition = try suppliedAcquisition ?? ManagedLauncherInstallerAcquisition(profile: profile, root: store.root)
        guard acquisition.root == store.root else { throw EnvironmentStoreError.identityMismatch }
        driver = .init(preflight: {
            let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
            guard report.prerequisites == .ready else { throw ManagedLauncherInstallationError.prerequisitesNotReady }
        }, acquire: { try await acquisition.acquire() }, artifactURL: { try await acquisition.validatedURL(for: $0) },
        start: { record, arguments, timeout in
            let session = try await RuntimeSession.start(store: store, id: record.id, layout: layout,
                                                         arguments: arguments, timeout: timeout)
            return ManagedLauncherInstallProcess(leaderExit: { await session.command.observedLeaderExit() },
                snapshot: { try await session.snapshot() }, stop: { _ = try await session.stop() })
        }, uiReady: { snapshot in
            snapshot.complete && snapshot.processes.contains(where: { $0.role == .launcher }) &&
                snapshot.processes.contains(where: { $0.role == .launcherUI })
        })
    }

    init(store: EnvironmentStore, layout: RuntimeLayout, profile: LauncherProfile,
         driver: ManagedLauncherInstallationDriver, diagnostics: DiagnosticStore? = nil) throws {
        try profile.validate()
        self.store = store; self.layout = layout; self.profile = profile; self.driver = driver; self.diagnostics = diagnostics
    }

    public func install(onStage: @escaping @Sendable (InstallationStage) async -> Void = { _ in }) async throws -> EnvironmentRecord {
        try await execute(.install, onStage: onStage)
    }

    /// Retry is explicit: an existing prefix is never initialized a second time.
    public func resumeInstaller(onStage: @escaping @Sendable (InstallationStage) async -> Void = { _ in }) async throws -> EnvironmentRecord {
        try await execute(.resume, onStage: onStage)
    }

    /// A failed bootstrap can be verified without reinstalling or resetting data.
    public func verifyExistingInstallation(onStage: @escaping @Sendable (InstallationStage) async -> Void = { _ in }) async throws -> EnvironmentRecord {
        try await execute(.verify, onStage: onStage)
    }

    private func execute(_ mode: Mode, onStage: @escaping @Sendable (InstallationStage) async -> Void) async throws -> EnvironmentRecord {
        guard !running, process == nil else { throw EnvironmentStoreError.busy }
        running = true
        defer { running = false; if process == nil { lease = nil } }
        lease = try await store.installationLease()
        let id = profile.id
        let existing = try await store.load(id)
        if let existing {
            let files = try await store.installationFiles(id)
            guard existing.runtime == layout.profile.identity, existing.steamExecutable == profile.executable,
                  existing.installationRecipeVersion == 1 else { throw ManagedLauncherInstallationError.recoveryRequired }
            switch mode {
            case .install:
                if existing.installation == .installed, files.prefixExists, files.executableExists { return existing }
                guard !files.prefixExists,
                      existing.installation == .notStarted || existing.installation == .failed(.downloadFailed) ||
                        existing.installation == .interrupted(.downloadingInstaller)
                else { throw ManagedLauncherInstallationError.recoveryRequired }
            case .resume:
                guard files.prefixExists, !files.executableExists, existing.installer != nil,
                      existing.installation == .interrupted(.creatingPrefix) ||
                        existing.installation == .interrupted(.runningInstaller) ||
                        existing.installation == .interrupted(.downloadingInstaller) ||
                        existing.installation == .failed(.downloadFailed) ||
                        existing.installation == .failed(.installerFailed)
                else { throw ManagedLauncherInstallationError.recoveryRequired }
            case .verify:
                guard files.prefixExists, files.executableExists, existing.installer != nil,
                      existing.installation == .interrupted(.runningInstaller) ||
                        existing.installation == .failed(.installerFailed) ||
                        existing.installation == .interrupted(.bootstrappingLauncher) ||
                        existing.installation == .interrupted(.validatingInstallation) ||
                        existing.installation == .failed(.bootstrapFailed)
                else { throw ManagedLauncherInstallationError.recoveryRequired }
            }
        } else if mode != .install { throw ManagedLauncherInstallationError.recoveryRequired }

        try Task.checkCancellation()
        try await driver.preflight()
        var record: EnvironmentRecord
        if let existing { record = existing }
        else {
            record = try await store.create(EnvironmentRecord(id: id, name: profile.name, runtime: layout.profile.identity,
                steamExecutable: profile.executable, installation: .installing(.downloadingInstaller), installationRecipeVersion: 1))
        }
        var stage: InstallationStage = mode == .verify ? .bootstrappingLauncher : .downloadingInstaller
        let operation: DiagnosticOperation?
        do { operation = try await diagnostics?.begin(stage: mode == .verify ? .bootstrap : .download,
            context: .init(component: .installer, environmentID: id, runtimeSelection: record.runtime)) }
        catch { operation = nil; diagnosticsUnavailable = true }
        do {
            if mode != .verify {
                record = try await advance(record, to: .downloadingInstaller, operation: operation)
                await onStage(.downloadingInstaller)
                let artifact = try await driver.acquire()
                guard artifact.provenance.source == profile.installer.url,
                      artifact.provenance.sha256 == profile.installer.sha256 else { throw InstallerAcquisitionError.invalidReceipt }
                try Task.checkCancellation()
                record.installer = artifact.provenance
                if mode == .install {
                    stage = .creatingPrefix
                    record = try await advance(record, to: stage, operation: operation)
                    await onStage(stage)
                    try await store.createInstallationPrefix(record)
                    try await runCommand(record, arguments: ["cmd", "/c", "ver"], timeout: 180)
                } else { _ = try await store.checkedPrefixURL(for: id) }
                stage = .runningInstaller
                record = try await advance(record, to: stage, operation: operation)
                await onStage(stage)
                let url = try await driver.artifactURL(artifact)
                try await runCommand(record, arguments: [url.path] + profile.installer.arguments, timeout: 1200)
            }
            guard try await store.installationFiles(id).executableExists else { throw ManagedLauncherInstallationError.commandFailed }
            stage = .bootstrappingLauncher
            record = try await advance(record, to: stage, operation: operation)
            await onStage(stage)
            let executable = try await store.checkedPrefixURL(for: id).appendingPathComponent(profile.executable.rawValue)
            process = try await driver.start(record, [executable.path], 1200)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1200))
            var readySince: ContinuousClock.Instant?
            stage = .validatingInstallation
            record = try await advance(record, to: stage, operation: operation)
            await onStage(stage)
            while true {
                try Task.checkCancellation()
                guard let process else { throw ManagedLauncherInstallationError.clientNotObserved }
                let snapshot = try await process.snapshot()
                if driver.uiReady(snapshot) {
                    if readySince == nil { readySince = .now }
                    if readySince!.duration(to: .now) >= .seconds(driver.readinessStability) { break }
                } else { readySince = nil }
                guard .now < deadline else { throw ManagedLauncherInstallationError.timedOut }
                try await Task.sleep(for: .milliseconds(250))
            }
            try await stopProcess()
            guard try await store.installationFiles(id).executableExists else { throw ManagedLauncherInstallationError.commandFailed }
            record.installation = .installed
            record = try await store.save(record)
            await finishDiagnostic(operation, outcome: .exited(0))
            return record
        } catch {
            let original = error
            do { try await stopProcess() }
            catch { await finishDiagnostic(operation, outcome: .executionFailed); throw error }
            if case .installing(let persistedStage) = record.installation { stage = persistedStage }
            record.installation = original is CancellationError ? .interrupted(stage) : .failed(stage == .downloadingInstaller
                ? .downloadFailed : stage == .bootstrappingLauncher || stage == .validatingInstallation ? .bootstrapFailed : .installerFailed)
            do { _ = try await store.save(record) }
            catch { await finishDiagnostic(operation, outcome: .executionFailed); throw error }
            await finishDiagnostic(operation, outcome: original is CancellationError ? .cancelled : .executionFailed)
            throw original
        }
    }

    private func advance(_ record: EnvironmentRecord, to stage: InstallationStage,
                         operation: DiagnosticOperation?) async throws -> EnvironmentRecord {
        try Task.checkCancellation()
        var updated = record; updated.installation = .installing(stage)
        let saved = try await store.save(updated)
        if let operation {
            do { try await diagnostics?.transition(operation, to: stage == .downloadingInstaller ? .download
                : stage == .bootstrappingLauncher ? .bootstrap : stage == .validatingInstallation ? .rendering : .installation) }
            catch { diagnosticsUnavailable = true }
        }
        return saved
    }

    private func runCommand(_ record: EnvironmentRecord, arguments: [String], timeout: TimeInterval) async throws {
        process = try await driver.start(record, arguments, timeout)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while let process {
            try Task.checkCancellation()
            if let result = await process.leaderExit() {
                guard result == .exited(0) else { throw ManagedLauncherInstallationError.commandFailed }
                try await stopProcess()
                return
            }
            guard .now < deadline else { throw ManagedLauncherInstallationError.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
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

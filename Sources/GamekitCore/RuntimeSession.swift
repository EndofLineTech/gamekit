import Foundation

public enum RuntimeSessionError: Error, Equatable {
    case prerequisitesNotReady, observationUnavailable, prefixBusy, scopeChanged, cleanupFailed
}
public enum RuntimeSessionEnd: Sendable { case completed, stopped, cancelled, timedOut }

/// One exclusive operation in an already registered prefix. The launcher's exit
/// does not imply its detached Wine/Steam children have exited.
public actor RuntimeSession {
    public nonisolated let sessionID: String
    public nonisolated let command: RunningCommand
    private var lease: EnvironmentExecutionLease?
    private let layout: RuntimeLayout
    private var deadline: Task<Void, Never>?
    private var stopTask: Task<CommandResult, any Error>?
    public private(set) var end: RuntimeSessionEnd?
    public private(set) var cleanupError: RuntimeSessionError?

    private init(lease: EnvironmentExecutionLease, layout: RuntimeLayout, command: RunningCommand, token: String) {
        self.lease = lease; self.layout = layout; self.command = command; sessionID = token
    }

    public static func start(store: EnvironmentStore, id: EnvironmentID, layout: RuntimeLayout,
                             arguments: [String], workingDirectory: URL? = nil, timeout: TimeInterval = 60,
                             onOutput: (@Sendable (CommandOutput) -> Void)? = nil) async throws -> RuntimeSession {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw CommandError.invalidRequest }
        let lease = try await store.executionLease(for: id)
        let report = try await RuntimeDetector().detect(layout, selection: lease.record.runtime)
        guard report.prerequisites == .ready else { throw RuntimeSessionError.prerequisitesNotReady }
        return try await launch(lease: lease, layout: layout, arguments: arguments,
                                workingDirectory: workingDirectory, timeout: timeout, onOutput: onOutput)
    }

    // Tests exercise real OS handoffs with their own fixture executable, not a forged
    // production runtime. Public starts always pass the real prerequisite detector.
    static func startFixture(store: EnvironmentStore, id: EnvironmentID, layout: RuntimeLayout,
                             arguments: [String], timeout: TimeInterval = 60) async throws -> RuntimeSession {
        try await launch(lease: store.executionLease(for: id), layout: layout, arguments: arguments,
                         workingDirectory: nil, timeout: timeout, onOutput: nil)
    }

    private static func launch(lease: EnvironmentExecutionLease, layout: RuntimeLayout, arguments: [String],
                               workingDirectory: URL?, timeout: TimeInterval,
                               onOutput: (@Sendable (CommandOutput) -> Void)?) async throws -> RuntimeSession {
        try Task.checkCancellation()
        try lease.validate()
        let snapshot = RuntimeProcessObserver().snapshot(record: lease.record, prefix: lease.prefix, layout: layout)
        guard snapshot.complete else { throw RuntimeSessionError.observationUnavailable }
        guard snapshot.processes.isEmpty else { throw RuntimeSessionError.prefixBusy }
        let token = UUID().uuidString
        let command = try await ProcessExecutor().start(CommandRequest(
            executable: layout.wine, arguments: arguments, environment: layout.environment(prefix: lease.prefix, session: token),
            workingDirectory: workingDirectory ?? lease.prefix, timeout: nil
        ), onOutput: onOutput)
        let session = RuntimeSession(lease: lease, layout: layout, command: command, token: token)
        await session.armDeadline(timeout)
        if Task.isCancelled {
            _ = try await Task.detached { try await session.stop(reason: .cancelled) }.value
            throw CancellationError()
        }
        return session
    }

    private func armDeadline(_ timeout: TimeInterval) {
        deadline = Task { [self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                _ = try await stop(reason: .timedOut)
            } catch is CancellationError {} catch {}
            // stop records cleanup refusal for inspection rather than killing a
            // foreign process or a replacement prefix to hide the failure.
        }
    }

    public func snapshot() throws -> RuntimeProcessSnapshot {
        guard let lease else { return .init(processes: [], complete: true) }
        try lease.validate()
        return RuntimeProcessObserver().snapshot(record: lease.record, prefix: lease.prefix, layout: layout)
    }

    /// Wait for the whole prefix to quiesce, not just the original launcher. Task
    /// cancellation waits for scoped cleanup before propagating CancellationError.
    public func waitUntilStopped() async throws -> RuntimeSessionEnd {
        do {
            while end == nil {
                try Task.checkCancellation()
                if let cleanupError { throw cleanupError }
                let current = try snapshot()
                if current.complete && current.processes.isEmpty,
                   await command.completedResult() != nil, end == nil, stopTask == nil {
                    end = .completed; lease = nil
                    deadline?.cancel(); deadline = nil
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return end ?? .completed
        } catch is CancellationError {
            _ = try await Task.detached { try await self.stop(reason: .cancelled) }.value
            throw CancellationError()
        }
    }

    public func stop() async throws -> CommandResult { try await stop(reason: .stopped) }
    public func cancel() async throws -> CommandResult { try await stop(reason: .cancelled) }

    private func stop(reason: RuntimeSessionEnd) async throws -> CommandResult {
        if let stopTask { return try await stopTask.value }
        let task = Task { try await performStop(reason) }
        stopTask = task
        do { return try await task.value }
        catch { stopTask = nil; throw error }
    }

    private func performStop(_ reason: RuntimeSessionEnd) async throws -> CommandResult {
        guard let lease else { return await command.result() }
        do {
            try lease.validate()
            let before = try snapshot()
            guard before.complete else { throw RuntimeSessionError.observationUnavailable }
            guard before.processes.allSatisfy({ $0.sessionID == sessionID }) else { throw RuntimeSessionError.prefixBusy }
            if !before.processes.isEmpty {
                // Use Wine's per-prefix server protocol, never a kill-by-name/PID
                // sweep of observed processes. Include the required dependency paths.
                let request = CommandRequest(executable: layout.wineserver, arguments: ["-k"],
                                             environment: layout.environment(prefix: lease.prefix, session: sessionID),
                                             workingDirectory: lease.prefix, timeout: 10, outputLimit: 8192)
                let stopped = try await Task.detached { try await ProcessExecutor().run(request) }.value
                guard stopped.termination == .exited(0) || stopped.termination == .exited(1),
                      stopped.stderr.isEmpty else { throw RuntimeSessionError.cleanupFailed }
            }
            command.cancel() // only this command's still-owned process group
            let result = await command.result()
            for _ in 0..<30 {
                let remaining = try snapshot()
                if remaining.complete && remaining.processes.isEmpty {
                    end = reason; cleanupError = nil; self.lease = nil
                    deadline?.cancel(); deadline = nil
                    return result
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RuntimeSessionError.cleanupFailed
        } catch {
            cleanupError = (error as? RuntimeSessionError) ?? .scopeChanged
            command.cancel()
            throw error
        }
    }
}

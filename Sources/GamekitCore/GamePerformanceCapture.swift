import Foundation

public enum PerformanceCaptureError: Error, Equatable { case scopeChanged, unavailable, incomplete }
public struct PerformanceCaptureResult: Sendable {
    public let id: UUID
    public let samples: Int
}

/// The helper can only read identity-pinned counters. Cancellation terminates
/// that helper's own process group, never the observed game or Wine session.
public struct GamePerformanceCapture: Sendable {
    private let helper: URL
    private let diagnostics: DiagnosticStore
    private let observe: @Sendable () async throws -> RuntimeProcessSnapshot

    public init(helper: URL, diagnostics: DiagnosticStore, lifecycle: SteamLifecycle) {
        self.helper = helper; self.diagnostics = diagnostics
        observe = { try await lifecycle.diagnosticProcesses() }
    }
    init(helper: URL, diagnostics: DiagnosticStore,
         observe: @escaping @Sendable () async throws -> RuntimeProcessSnapshot) {
        self.helper = helper; self.diagnostics = diagnostics; self.observe = observe
    }

    private func verify(_ target: ScopedRuntimeProcess) async throws {
        guard target.role == .other, let token = target.sessionID, UUID(uuidString: token) != nil else { throw PerformanceCaptureError.scopeChanged }
        let snapshot = try await observe()
        guard snapshot.complete, snapshot.processes.allSatisfy({ $0.sessionID == token }),
              snapshot.processes.contains(where: { $0.identity == target.identity && $0.role == .other && $0.sessionID == token })
        else { throw PerformanceCaptureError.scopeChanged }
    }

    public func capture(target: ScopedRuntimeProcess, appID: UInt32, duration: Int = 60) async throws -> PerformanceCaptureResult {
        try Task.checkCancellation()
        guard appID > 0, (1...60).contains(duration), helper.isFileURL, helper.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw PerformanceCaptureError.unavailable }
        try await verify(target)
        let operation = try await diagnostics.begin(stage: .performanceCapture, context: .init(component: .application))
        var command: RunningCommand?
        do {
            try Task.checkCancellation()
            let gameHeader = try JSONSerialization.data(withJSONObject: ["event": "game", "appID": appID], options: [.sortedKeys]) + Data([10])
            operation.receive(.init(channel: .stdout, bytes: gameHeader))
            let identity = target.identity
            let request = CommandRequest(executable: helper,
                arguments: [String(identity.pid), String(identity.startSeconds), String(identity.startMicroseconds), String(duration)],
                timeout: Double(duration + 10), outputLimit: 262144)
            let running = try await ProcessExecutor().start(request, onOutput: { operation.receive($0) })
            command = running
            while await running.completedResult() == nil {
                try Task.checkCancellation()
                try await verify(target)
                try await Task.sleep(for: .milliseconds(500))
            }
            try Task.checkCancellation()
            let result = await running.result()
            let summary = try await diagnostics.finish(operation, result: result)
            guard result.termination == .exited(0), !summary.outputTruncated, !result.stdoutTruncated, !result.outputIncomplete else { throw PerformanceCaptureError.incomplete }
            let samples = result.stdoutText.split(separator: "\n").filter { line in
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
                return record["event"] as? String == "sample" && record["pid"] as? Int32 == identity.pid
            }.count
            return .init(id: summary.id, samples: samples)
        } catch {
            command?.cancel()
            let result = await command?.result()
            _ = try? await diagnostics.finish(operation, outcome: error is CancellationError ? .cancelled : .executionFailed,
                                               command: result, outputIncomplete: true)
            throw error
        }
    }
}

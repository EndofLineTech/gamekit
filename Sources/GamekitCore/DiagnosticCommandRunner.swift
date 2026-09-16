import Foundation

public enum DiagnosticStorageIssue: String, Sendable { case recordingUnavailable, writeFailed }
public struct DiagnosticExecution: Sendable {
    public let command: CommandResult?
    public let launchError: (any Error)?
    public let summary: DiagnosticSummary?
    public let storageIssue: DiagnosticStorageIssue?
    public func value() throws -> CommandResult {
        if let command { return command }
        throw launchError ?? CommandError.invalidRequest
    }
}

/// Logging is a separate result channel: a disk failure must not be misreported
/// as missing Rosetta or an invalid runtime by a caller performing a probe.
public struct DiagnosticCommandRunner: Sendable {
    private let store: DiagnosticStore
    public init(store: DiagnosticStore) { self.store = store }

    public func run(_ request: CommandRequest, stage: DiagnosticStage,
                    context: DiagnosticContext = .init()) async -> DiagnosticExecution {
        let operation: DiagnosticOperation?
        var issue: DiagnosticStorageIssue?
        do { operation = try await store.begin(stage: stage, context: context) }
        catch { operation = nil; issue = .recordingUnavailable }
        do {
            let result = try await ProcessExecutor().run(request, onOutput: { operation?.receive($0) })
            var summary: DiagnosticSummary?
            if let operation {
                do { summary = try await store.finish(operation, result: result) }
                catch { issue = .writeFailed }
            }
            return .init(command: result, launchError: nil, summary: summary, storageIssue: issue)
        } catch {
            let outcome: DiagnosticOutcome
            if error is CancellationError { outcome = .cancelled }
            else if let commandError = error as? CommandError {
                switch commandError {
                case .invalidRequest: outcome = .invalidRequest
                case .spawn(let code): outcome = .launchFailed(code)
                }
            } else { outcome = .executionFailed }
            var summary: DiagnosticSummary?
            if let operation {
                do { summary = try await store.finish(operation, outcome: outcome) }
                catch { issue = .writeFailed }
            }
            return .init(command: nil, launchError: error, summary: summary, storageIssue: issue)
        }
    }
}

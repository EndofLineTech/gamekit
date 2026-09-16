import Foundation

/// All mutable capture state is lock-protected. The process callback performs only
/// bounded in-memory work; checkpoints are written by DiagnosticStore, not here.
public final class DiagnosticOperation: @unchecked Sendable {
    public let id: UUID
    let owner: UUID
    private let lock = NSLock()
    private let context: DiagnosticContext
    private let startedAt: Date
    private let startTick = DispatchTime.now().uptimeNanoseconds
    private let policy: DiagnosticsPolicy
    private var stage: DiagnosticStage
    private var events: [DiagnosticStageEvent]
    private var eventsDropped = 0
    private var stdout = Data(), stderr = Data(), stdoutTail = Data(), stderrTail = Data()
    private var stdoutBytes = 0, stderrBytes = 0
    private var observed: DiagnosticSignatureObservation?
    private var closed = false
    private var checkpointFailed = false

    init(owner: UUID, stage: DiagnosticStage, context: DiagnosticContext, policy: DiagnosticsPolicy, at date: Date) {
        id = UUID(); self.owner = owner; self.stage = stage; self.context = context
        self.policy = policy; startedAt = date
        events = [.init(stage: stage, elapsedSeconds: 0)]
    }
    private var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - startTick) / 1_000_000_000 }

    public func receive(_ output: CommandOutput) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let isOut = output.channel == .stdout
        if isOut {
            stdoutBytes = adding(stdoutBytes, output.bytes.count)
            stdout.append(output.bytes.prefix(max(0, policy.bytesPerStream - stdout.count)))
        } else {
            stderrBytes = adding(stderrBytes, output.bytes.count)
            stderr.append(output.bytes.prefix(max(0, policy.bytesPerStream - stderr.count)))
        }
        // ProcessExecutor emits <=16 KiB chunks; larger explicit inputs are scanned
        // in bounded slices too, so a late signature is not silently discarded.
        var search = isOut ? stdoutTail : stderrTail
        for offset in stride(from: 0, to: output.bytes.count, by: 16_384) {
            search.append(output.bytes[offset..<min(output.bytes.count, offset + 16_384)])
            if let found = Self.signature(in: String(decoding: search, as: UTF8.self)),
               observed.map({ found.priority < $0.signature.priority }) ?? true {
                observed = .init(signature: found, stage: stage)
            }
            search = Data(search.suffix(512))
        }
        if isOut { stdoutTail = search } else { stderrTail = search }
    }

    private func adding(_ a: Int, _ b: Int) -> Int {
        let sum = a.addingReportingOverflow(b)
        return sum.overflow ? Int.max : sum.partialValue
    }

    static func signature(in value: String) -> DiagnosticSignature? {
        value.split(whereSeparator: \.isNewline).compactMap { lineSignature(String($0).lowercased()) }
            .min { $0.priority < $1.priority }
    }

    private static func lineSignature(_ text: String) -> DiagnosticSignature? {
        if text.contains("wine_unix_call_dispatcher=absent") ||
            (text.contains("__wine_unix_call_dispatcher") && (text.contains("not found") || text.contains("missing"))) { return .missingUnixDispatcher }
        if text.contains("unhandled page fault") || text.contains("unhandled exception") { return .unhandledException }
        if text.contains("error=1114") || text.contains("dll initialization failed") { return .dllInitialization }
        if text.contains("permission denied") || text.contains("access denied") { return .permissionDenied }
        if text.contains("connection refused") || text.contains("could not resolve host") { return .networkFailure }
        if text.hasPrefix("fail ") || text.contains("\nfail ") { return .explicitFailure }
        return nil
    }

    func transition(to next: DiagnosticStage) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, next != stage else { return }
        stage = next
        if events.count == policy.maximumStageEvents { events.remove(at: 1); eventsDropped += 1 }
        events.append(.init(stage: next, elapsedSeconds: elapsed))
    }
    func noteCheckpointFailure() { lock.lock(); checkpointFailed = true; lock.unlock() }

    func snapshot(at now: Date, outcome: DiagnosticOutcome? = nil, command: CommandResult? = nil,
                  outputIncomplete: Bool = false, finish: Bool = false) -> DiagnosticRecord {
        lock.lock(); defer { lock.unlock() }
        if finish { closed = true }
        return DiagnosticRecord(id: id, context: context, startedAt: startedAt, updatedAt: max(startedAt, now),
                                elapsedSeconds: elapsed, stage: stage, events: events, eventsDropped: eventsDropped,
                                stdout: stdout, stderr: stderr, stdoutBytes: stdoutBytes, stderrBytes: stderrBytes,
                                signature: observed, outcome: outcome,
                                commandTermination: command.map { DiagnosticOutcome($0.termination) }, commandDurationSeconds: command?.duration,
                                outputIncomplete: outputIncomplete,
                                checkpointFailed: checkpointFailed)
    }
}

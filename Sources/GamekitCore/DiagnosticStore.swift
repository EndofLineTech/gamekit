import Foundation

public enum DiagnosticStoreError: Error, Equatable {
    case invalidPolicy, invalidRecord, capacityReached, unknownOperation, notFound
}

/// Private local records; export is a distinct allowlisted representation. All
/// catalog writes/pruning share a lock, and active operations keep their own lease.
public actor DiagnosticStore {
    public nonisolated let base: URL
    private let policy: DiagnosticsPolicy
    private let clock: @Sendable () -> Date
    private let owner = UUID()
    private struct Active {
        let operation: DiagnosticOperation
        let lease: ManagedFileLock
    }
    private var active: [UUID: Active] = [:]
    private var timer: Task<Void, Never>?

    public static var defaultBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Gamekit")
    }

    public init(base: URL = DiagnosticStore.defaultBase, policy: DiagnosticsPolicy = .init(),
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        try policy.validate()
        self.base = try ManagedDirectory.canonicalRoot(base)
        self.policy = policy; self.clock = clock
    }
    deinit { timer?.cancel() }

    private func directory(create: Bool) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(base, create: create) else { return nil }
        return try root.directory("Operations", create: create)
    }
    private func filename(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }
    private func lockname(_ id: UUID) -> String { ".operation-" + id.uuidString.lowercased() + ".lock" }
    private func codec() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    private func read(_ id: UUID, from directory: ManagedDirectory) throws -> DiagnosticRecord {
        guard let data = try directory.read(filename(id)) else { throw DiagnosticStoreError.notFound }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let record = try decoder.decode(DiagnosticRecord.self, from: data)
        try record.validate()
        guard record.id == id else { throw DiagnosticStoreError.invalidRecord }
        return record
    }
    private func records(in directory: ManagedDirectory) throws -> [DiagnosticRecord] {
        try directory.names().compactMap { name in
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))), name == filename(id) else { return nil }
            return try read(id, from: directory)
        }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt < $1.updatedAt
        }
    }
    private func write(_ record: DiagnosticRecord, to directory: ManagedDirectory, create: Bool = false) throws {
        try record.validate()
        let data = try codec().encode(record)
        try directory.write(data, to: filename(record.id), createOnly: create,
                            temporaryPrefix: ".diagnostic-", beforeCommit: {})
    }

    /// Called only with the catalog write lock, so no cooperating writer can have
    /// an in-flight temporary file here. Unknown files/symlinks are never swept.
    private func prune(_ directory: ManagedDirectory, targetCount: Int) throws {
        let existing = try records(in: directory) // fail closed on corrupt owned records
        var count = existing.count
        for record in existing {
            let expired = clock().timeIntervalSince(record.updatedAt) > policy.maximumAge
            guard expired || count > targetCount else { continue }
            let lease: ManagedFileLock
            do { lease = try directory.acquireLock(lockname(record.id)) }
            catch EnvironmentStoreError.busy { continue }
            try withExtendedLifetime(lease) {
                try directory.removeRegularFile(filename(record.id))
                try directory.removeRegularFile(lockname(record.id))
            }
            count -= 1
        }
        for name in try directory.names() {
            if name.hasPrefix(".diagnostic-"), name.hasSuffix(".tmp"),
               UUID(uuidString: String(name.dropFirst(".diagnostic-".count).dropLast(4))) != nil {
                try directory.removeRegularFile(name)
            } else if name.hasPrefix(".operation-"), name.hasSuffix(".lock"),
                      let id = UUID(uuidString: String(name.dropFirst(".operation-".count).dropLast(5))),
                      !(try directory.containsRegularFile(filename(id))) {
                do {
                    let lease = try directory.acquireLock(name)
                    try withExtendedLifetime(lease) { try directory.removeRegularFile(name) }
                } catch EnvironmentStoreError.busy { continue }
            }
        }
    }

    public func begin(stage: DiagnosticStage, context: DiagnosticContext = .init()) throws -> DiagnosticOperation {
        try context.validate()
        guard let directory = try directory(create: true) else { throw DiagnosticStoreError.notFound }
        let operation = try directory.withWriteLock {
            try prune(directory, targetCount: policy.maximumOperations - 1)
            guard try records(in: directory).count < policy.maximumOperations else { throw DiagnosticStoreError.capacityReached }
            let operation = DiagnosticOperation(owner: owner, stage: stage, context: context, policy: policy, at: clock())
            let lease = try directory.acquireLock(lockname(operation.id))
            do { try write(operation.snapshot(at: clock()), to: directory, create: true) }
            catch { try? directory.removeRegularFile(lockname(operation.id)); throw error }
            active[operation.id] = Active(operation: operation, lease: lease)
            return operation
        }
        startTimer()
        return operation
    }

    private func requireActive(_ operation: DiagnosticOperation) throws {
        guard operation.owner == owner, active[operation.id]?.operation === operation else {
            throw DiagnosticStoreError.unknownOperation
        }
    }
    public func transition(_ operation: DiagnosticOperation, to stage: DiagnosticStage) throws {
        try requireActive(operation)
        operation.transition(to: stage)
        try checkpoint(operation)
    }
    public func checkpoint(_ operation: DiagnosticOperation) throws {
        try requireActive(operation)
        do {
            guard let directory = try directory(create: false) else { throw DiagnosticStoreError.notFound }
            try directory.withWriteLock { try write(operation.snapshot(at: clock()), to: directory) }
        } catch { operation.noteCheckpointFailure(); throw error }
    }
    public func finish(_ operation: DiagnosticOperation, outcome: DiagnosticOutcome,
                       command: CommandResult? = nil, outputIncomplete: Bool = false) throws -> DiagnosticSummary {
        try requireActive(operation)
        let record = operation.snapshot(at: clock(), outcome: outcome, command: command,
                                        outputIncomplete: outputIncomplete || (command?.outputIncomplete ?? false), finish: true)
        defer {
            active.removeValue(forKey: operation.id)
            if active.isEmpty { timer?.cancel(); timer = nil }
        }
        guard let directory = try directory(create: false) else { throw DiagnosticStoreError.notFound }
        try directory.withWriteLock { try write(record, to: directory) }
        return record.summary
    }
    public func finish(_ operation: DiagnosticOperation, result: CommandResult) throws -> DiagnosticSummary {
        try finish(operation, outcome: DiagnosticOutcome(result.termination), command: result)
    }

    public func summaries() throws -> [DiagnosticSummary] {
        guard let directory = try directory(create: false) else { return [] }
        return try directory.withWriteLock {
            try prune(directory, targetCount: policy.maximumOperations)
            return try records(in: directory).reversed().map(\.summary)
        }
    }
    public func localOutput(_ id: UUID) throws -> DiagnosticLocalOutput {
        guard let directory = try directory(create: false) else { throw DiagnosticStoreError.notFound }
        let record = try read(id, from: directory)
        return DiagnosticLocalOutput(stdout: record.stdout, stderr: record.stderr)
    }
    public func exportSummary(_ id: UUID) throws -> Data {
        guard let directory = try directory(create: false) else { throw DiagnosticStoreError.notFound }
        // Encode only this allowlist type. Do not attach the local record or files.
        return try codec().encode(read(id, from: directory).summary)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let interval = policy.checkpointInterval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                await self.checkpointActive()
            }
        }
    }
    private func checkpointActive() {
        for entry in active.values { try? checkpoint(entry.operation) }
        // A failed checkpoint is recorded in the capture and reported by finish.
    }
}

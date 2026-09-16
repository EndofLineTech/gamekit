import CProcessSupport
import Darwin
import Foundation

public enum CommandError: Error, Equatable { case invalidRequest, spawn(Int32) }
public enum CommandTermination: Equatable, Sendable {
    case exited(Int32), signalled(Int32), timedOut, cancelled, observationFailed(Int32)
}
public enum OutputChannel: Sendable { case stdout, stderr }
public struct CommandOutput: Sendable {
    public let channel: OutputChannel
    public let bytes: Data
}
public struct CommandResult: Sendable {
    public let termination: CommandTermination
    public let stdout: Data
    public let stderr: Data
    public let stdoutBytes: Int
    public let stderrBytes: Int
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let outputIncomplete: Bool
    public let duration: TimeInterval
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}
public struct CommandRequest: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let timeout: TimeInterval?
    public let terminationGrace: TimeInterval
    public let outputLimit: Int

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:],
                workingDirectory: URL? = nil, timeout: TimeInterval? = 30,
                terminationGrace: TimeInterval = 0.5, outputLimit: Int = 262_144) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.timeout = timeout
        self.terminationGrace = terminationGrace; self.outputLimit = outputLimit
    }

    func validate() throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"), !executable.path.utf8.contains(0),
              arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }),
              timeout.map({ $0.isFinite && $0 > 0 && $0 <= 86_400 }) ?? true,
              terminationGrace.isFinite, terminationGrace >= 0, terminationGrace <= 10,
              outputLimit >= 0, outputLimit <= 16_777_216 else { throw CommandError.invalidRequest }
        if let directory = workingDirectory {
            guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0)
            else { throw CommandError.invalidRequest }
        }
    }
}

public struct ProcessExecutor: Sendable {
    public init() {}

    /// The callback receives every chunk in stream-read order on a private serial
    /// queue. It must return promptly; retained result buffers are separately bounded.
    public func start(_ request: CommandRequest,
                      onOutput: (@Sendable (CommandOutput) -> Void)? = nil) async throws -> RunningCommand {
        try request.validate()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var arguments = ([request.executable.path] + request.arguments).map { strdup($0) } + [nil]
                var environment = request.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
                defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
                guard arguments.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
                    continuation.resume(throwing: CommandError.spawn(ENOMEM)); return
                }
                var pid: pid_t = 0, output: Int32 = -1, errors: Int32 = -1
                let code = gk_spawn(request.executable.path, &arguments, &environment,
                                    request.workingDirectory?.path, &pid, &output, &errors)
                guard code == 0 else { continuation.resume(throwing: CommandError.spawn(code)); return }
                let command = RunningCommand(pid: pid, output: output, errors: errors, request: request, callback: onOutput)
                command.begin()
                continuation.resume(returning: command)
            }
        }
    }

    public func run(_ request: CommandRequest,
                    onOutput: (@Sendable (CommandOutput) -> Void)? = nil) async throws -> CommandResult {
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let command = try await start(request, onOutput: onOutput)
            cancellation.install(command)
            return await command.result()
        } onCancel: { cancellation.cancel() }
    }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var command: RunningCommand?
    private var cancelled = false
    func install(_ command: RunningCommand) {
        lock.lock(); self.command = command; let cancel = cancelled; lock.unlock()
        if cancel { command.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = command; lock.unlock()
        current?.cancel()
    }
}

/// Mutable state is confined to queue. The leader is left unreaped until final
/// cleanup, so its PID/process-group ID cannot be recycled before signalling ends.
public final class RunningCommand: @unchecked Sendable {
    /// Nonblocking leader status, independent of inherited pipe writers.
    public func observedLeaderExit() async -> CommandTermination? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.leaderTermination) }
        }
    }
    public let pid: Int32
    private let queue = DispatchQueue(label: "tech.endofline.gamekit.command")
    private let request: CommandRequest
    private let callback: (@Sendable (CommandOutput) -> Void)?
    private let outputFD: Int32
    private let errorFD: Int32
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var output = Data(), errors = Data()
    private var outputBytes = 0, errorBytes = 0
    private var outputClosed = false, errorClosed = false, leaderExited = false
    private var outputIncomplete = false
    private var waitError: Int32 = 0
    private var forced: CommandTermination?
    private var stopping = false
    private var finished: CommandResult?
    private var waiters: [CheckedContinuation<CommandResult, Never>] = []
    private var leaderTermination: CommandTermination?
    private var leaderWaiters: [CheckedContinuation<CommandTermination, Never>] = []
    private var keepAlive: RunningCommand?
    private let started = DispatchTime.now().uptimeNanoseconds

    fileprivate init(pid: Int32, output: Int32, errors: Int32, request: CommandRequest,
                     callback: (@Sendable (CommandOutput) -> Void)?) {
        self.pid = pid; outputFD = output; errorFD = errors
        self.request = request; self.callback = callback
    }

    fileprivate func begin() {
        queue.async { [self] in
            self.keepAlive = self
            self.outputSource = self.reader(self.outputFD, channel: .stdout)
            self.errorSource = self.reader(self.errorFD, channel: .stderr)
            if let timeout = self.request.timeout {
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.terminate(.timedOut) }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            var exitCode: Int32 = 0, signal: Int32 = 0
            let code = gk_wait_without_reaping(self.pid, &exitCode, &signal)
            let termination: CommandTermination = code != 0 ? .observationFailed(code)
                : (signal == 0 ? .exited(exitCode) : .signalled(signal))
            self.queue.async {
                self.waitError = code; self.leaderExited = true
                self.leaderTermination = termination
                self.leaderWaiters.forEach { $0.resume(returning: termination) }; self.leaderWaiters.removeAll()
                if code != 0 { self.outputIncomplete = true; self.close(.stdout); self.close(.stderr) }
                self.finishIfPossible()
            }
        }
    }

    public func result() async -> CommandResult {
        await withCheckedContinuation { continuation in
            queue.async {
                if let result = self.finished { continuation.resume(returning: result) }
                else { self.waiters.append(continuation) }
            }
        }
    }

    /// Reports the original process's OS exit independently of pipe draining and
    /// detached-child lifetime. A successful launcher exit is not session completion.
    public func leaderExit() async -> CommandTermination {
        await withCheckedContinuation { continuation in
            queue.async {
                if let value = self.leaderTermination { continuation.resume(returning: value) }
                else { self.leaderWaiters.append(continuation) }
            }
        }
    }

    public func completedResult() async -> CommandResult? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.finished) }
        }
    }

    public func cancel() { queue.async { self.terminate(.cancelled) } }

    private func reader(_ fd: Int32, channel: OutputChannel) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd, channel: channel) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    private func drain(_ fd: Int32, channel: OutputChannel) {
        guard channel == .stdout ? !outputClosed : !errorClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Yield to timeout/cancellation even if the child continuously writes.
        for _ in 0..<32 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                let error = errno
                outputIncomplete = true
                terminate(.observationFailed(error))
                close(channel); finishIfPossible(); return
            }
            if count == 0 { close(channel); finishIfPossible(); return }
            let bytes = Data(buffer.prefix(count))
            if channel == .stdout {
                outputBytes += count
                output.append(bytes.prefix(max(0, request.outputLimit - output.count)))
            } else {
                errorBytes += count
                errors.append(bytes.prefix(max(0, request.outputLimit - errors.count)))
            }
            callback?(CommandOutput(channel: channel, bytes: bytes))
        }
    }

    private func close(_ channel: OutputChannel) {
        if channel == .stdout {
            outputClosed = true; outputSource?.cancel(); outputSource = nil
        } else {
            errorClosed = true; errorSource?.cancel(); errorSource = nil
        }
    }

    private func terminate(_ reason: CommandTermination) {
        guard finished == nil, !stopping, waitError == 0 else { return }
        stopping = true
        forced = forced ?? reason
        kill(-pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + request.terminationGrace) { [weak self] in
            guard let self, self.finished == nil, self.waitError == 0 else { return }
            kill(-self.pid, SIGKILL)
            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.finished == nil else { return }
                // Detached processes are handled by RuntimeSession's prefix stop,
                // not by pretending they still belong to this POSIX process group.
                self.outputIncomplete = !self.outputClosed || !self.errorClosed
                self.close(.stdout); self.close(.stderr); self.finishIfPossible()
            }
        }
    }

    private func finishIfPossible() {
        guard finished == nil, leaderExited, outputClosed, errorClosed else { return }
        var code: Int32 = 0, signal: Int32 = 0
        let reaped = waitError == 0 ? gk_reap(pid, &code, &signal) : waitError
        let reason = forced ?? (reaped != 0 ? .observationFailed(reaped) : (signal == 0 ? .exited(code) : .signalled(signal)))
        let result = CommandResult(termination: reason, stdout: output, stderr: errors,
                                   stdoutBytes: outputBytes, stderrBytes: errorBytes,
                                   stdoutTruncated: outputBytes > output.count,
                                   stderrTruncated: errorBytes > errors.count,
                                   outputIncomplete: outputIncomplete,
                                   duration: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000)
        finished = result
        waiters.forEach { $0.resume(returning: result) }; waiters.removeAll()
        keepAlive = nil
    }
}

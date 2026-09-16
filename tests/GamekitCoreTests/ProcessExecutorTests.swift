import Foundation
import CProcessSupport
import Darwin
import Testing
@testable import GamekitCore

@Suite("Asynchronous command execution")
struct ProcessExecutorTests {
    @Test("Audit-token signalling refuses stale identities and terminates only the owned process")
    func auditTokenTermination() async throws {
        let child = try await ProcessExecutor().start(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 35))
        defer { child.cancel() }
        var identity = GKProcessIdentity()
        try #require(gk_identity(child.pid, &identity) == 0)
        #expect(gk_signal_identity(child.pid, identity.start_seconds + 1, identity.start_microseconds, SIGTERM) != 0)
        let probe = gk_signal_identity(child.pid, identity.start_seconds, identity.start_microseconds, 0)
        try #require(probe == 0, "audit-token signal access returned \(probe)")
        #expect(gk_signal_identity(child.pid, identity.start_seconds, identity.start_microseconds, SIGTERM) == 0)
        #expect(await child.result().termination == .signalled(SIGTERM))
    }
    @Test("An independently launched application owns its own macOS responsibility")
    func independentResponsibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("responsibility.c")
        let executable = root.appendingPathComponent("responsibility")
        try Data(#"""
        #include <dlfcn.h>
        #include <stdio.h>
        #include <unistd.h>
        int main(void) {
            typedef pid_t (*query_fn)(pid_t);
            query_fn query = (query_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
            if (!query) return 2;
            printf("%d %d\n", getpid(), query(getpid()));
            return 0;
        }
        """#.utf8).write(to: source)
        let built = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/clang"), arguments: [source.path, "-o", executable.path]))
        try #require(built.termination == .exited(0))
        let result = try await ProcessExecutor().run(.init(executable: executable, independentApplication: true))
        #expect(result.termination == .exited(0))
        let values = result.stdoutText.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try #require(values.count == 2)
        #expect(values[0] == values[1])
    }

    @Test("Leader exit is observable before a handed-off pipe writer finishes")
    func independentLeaderExit() async throws {
        let command = try await ProcessExecutor().start(CommandRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                                arguments: ["-c", "sleep 30 & exit 23"], timeout: 10, terminationGrace: 0.1))
        #expect(await command.leaderExit() == .exited(23))
        #expect(await command.completedResult() == nil)
        command.cancel()
        #expect(await command.result().termination == .cancelled)
    }
    @Test("Arguments and paths with spaces remain literal")
    func literalArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " with spaces")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("echo tool")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$1\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let text = "a b; $(touch should-not-exist) 'quoted'"
        let result = try await ProcessExecutor().run(CommandRequest(executable: executable, arguments: [text],
                                                                   environment: [:], workingDirectory: root))
        #expect(result.termination == .exited(0))
        #expect(result.stdoutText == text + "\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
    }

    @Test("Missing executable and invalid C-string inputs fail before launch")
    func launchErrors() async throws {
        await #expect(throws: (any Error).self) {
            try await ProcessExecutor().run(CommandRequest(executable: URL(fileURLWithPath: "/no-such-gamekit-executable")))
        }
        await #expect(throws: CommandError.invalidRequest) {
            try await ProcessExecutor().run(CommandRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["bad\0argument"]))
        }
    }

    @Test("Nonzero exits preserve separate stdout and stderr")
    func nonzeroExit() async throws {
        let result = try await ProcessExecutor().run(CommandRequest(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf out; printf err >&2; exit 23"]
        ))
        #expect(result.termination == .exited(23))
        #expect(result.stdoutText == "out")
        #expect(result.stderrText == "err")
    }

    @Test("Both pipes drain concurrently and capture is bounded")
    func largeOutput() async throws {
        let result = try await ProcessExecutor().run(CommandRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do printf abcdefgh; printf 12345678 >&2; i=$((i+1)); done"],
            timeout: 15, outputLimit: 1024
        ))
        #expect(result.termination == .exited(0))
        #expect(result.stdout.count == 1024 && result.stderr.count == 1024)
        #expect(result.stdoutTruncated && result.stderrTruncated)
        #expect(result.stdoutBytes == 160000 && result.stderrBytes == 160000)
    }

    @Test("Timeout escalates for an uncooperative owned process group")
    func timeout() async throws {
        let result = try await ProcessExecutor().run(CommandRequest(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 30 & wait"],
            timeout: 0.2, terminationGrace: 0.1
        ))
        #expect(result.termination == .timedOut)
        #expect(result.duration < 5)
    }

    @Test("Task cancellation stops the command but not an unrelated process")
    func cancellation() async throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            return try await ProcessExecutor().run(CommandRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "printf READY; exec /bin/sleep 30"], terminationGrace: 0.1),
                                         onOutput: { if $0.channel == .stdout { continuation.yield(()) } })
        }
        var readiness = ready.makeAsyncIterator()
        #expect(await readiness.next() != nil)
        task.cancel()
        let result = try await task.value
        #expect(result.termination == .cancelled)
        #expect(unrelated.isRunning)
    }

    @Test("Fast exits and inherited pipe writers cannot strand completion")
    func exitRaces() async throws {
        for _ in 0..<10 {
            let result = try await ProcessExecutor().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/true")))
            #expect(result.termination == .exited(0))
        }
        let result = try await ProcessExecutor().run(CommandRequest(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & exit 0"],
            timeout: 0.2, terminationGrace: 0.1
        ))
        #expect(result.termination == .timedOut)
    }
}

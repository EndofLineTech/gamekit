import CProcessSupport
import Darwin
import Foundation

/// Only used after prefix shutdown, with a caller-supplied fresh, complete owned
/// inventory. Kernel audit-token signalling prevents signalling a recycled PID.
enum ScopedProcessTermination {
    static func signal(_ processes: [ScopedRuntimeProcess], signal: Int32) throws {
        for process in processes {
            let identity = process.identity
            let result = gk_signal_identity(identity.pid, identity.startSeconds, identity.startMicroseconds, signal)
            if result == 0 || result == ESRCH || result == ENOENT { continue }
            var current = GKProcessIdentity()
            let observed = gk_identity(identity.pid, &current)
            if observed == ESRCH || observed == ENOENT { continue }
            if observed == 0 && (current.zombie != 0 || current.start_seconds != identity.startSeconds || current.start_microseconds != identity.startMicroseconds) { continue }
            throw RuntimeSessionError.cleanupFailed
        }
    }
    static func finish(snapshot: @Sendable () async throws -> [ScopedRuntimeProcess]) async throws {
        try signal(try await snapshot(), signal: SIGTERM)
        try await Task.sleep(for: .milliseconds(500))
        try signal(try await snapshot(), signal: SIGKILL)
        for _ in 0..<30 {
            if try await snapshot().isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeSessionError.cleanupFailed
    }
}

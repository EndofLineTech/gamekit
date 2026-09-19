import Darwin
import Foundation

public enum SteamGameLaunchProgress: String, Sendable {
    case waitingForSteam, preparing, synchronizingCloud, cloudAttention, otherSessionAttention, userAttention, processCreated, unavailable
    public var isTerminal: Bool { self == .processCreated || self == .unavailable }
    public var message: String {
        switch self {
        case .waitingForSteam: "Waiting for Steam to acknowledge the launch. Cold startup can take a while."
        case .preparing: "Steam acknowledged the request and is preparing the game."
        case .synchronizingCloud: "Steam is synchronizing game data with Steam Cloud."
        case .cloudAttention: "Steam Cloud needs your attention. Open Windows Steam to resolve its sync prompt."
        case .otherSessionAttention: "Steam is waiting for a decision about another session. Open Windows Steam; Gamekit will not disconnect it."
        case .userAttention: "Steam is waiting for your response. Open Windows Steam to review its prompt."
        case .processCreated: "Steam created a game process. Check the game window; this does not establish gameplay readiness."
        case .unavailable: "Launch tracking is unavailable or the Steam session changed. Check Windows Steam before trying again."
        }
    }
}

/// Parses only fixed event shapes. Never return the log's paths, URLs, account
/// details or free-form prompt payloads to the UI or diagnostic summaries.
struct SteamGameLaunchParser {
    let appID: UInt32
    private var pending = Data()
    private(set) var progress: SteamGameLaunchProgress = .waitingForSteam

    mutating func receive(_ data: Data) {
        guard !progress.isTerminal else { return }
        guard data.count <= 65536 else { progress = .unavailable; return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            guard pending.distance(from: pending.startIndex, to: newline) <= 8192 else { progress = .unavailable; pending.removeAll(); return }
            let line = String(decoding: pending[..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
            pending.removeSubrange(...newline)
            consume(line)
            if progress.isTerminal { pending.removeAll(); return }
        }
        if pending.count > 8192 { progress = .unavailable; pending.removeAll() }
    }

    private mutating func consume(_ line: String) {
        guard let timestamp = line.range(of: #"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] "#, options: .regularExpression) else { return }
        let body = line[timestamp.upperBound...]
        if body.hasPrefix("Game process added : AppID \(appID) ") {
            progress = .processCreated; return
        }
        let prefix = "GameAction [AppID \(appID), ActionID "
        guard body.hasPrefix(prefix), let delimiter = body.range(of: "] : LaunchApp ") else { return }
        let action = body.dropFirst(prefix.count).prefix(upTo: delimiter.lowerBound)
        guard !action.isEmpty, action.allSatisfy(\.isNumber), UInt32(action) != nil else { return }
        let detail = body[delimiter.upperBound...]
        if detail.hasPrefix("waiting for user response to SynchronizingCloud ") { progress = .cloudAttention }
        else if detail.hasPrefix("waiting for user response to KickingOtherSession ") { progress = .otherSessionAttention }
        else if detail.hasPrefix("waiting for user response to ") { progress = .userAttention }
        else if detail.hasPrefix("changed task to SynchronizingCloud ") { progress = .synchronizingCloud }
        else if detail.hasPrefix("changed task to ") || detail.hasPrefix("continues with user response ") { progress = .preparing }
    }
}

/// Incremental, descriptor-relative, no-follow read. Only bytes appended after
/// this request are eligible. Rotation/truncation ends observation instead of
/// interpreting an old log as a fresh acknowledgement.
struct SteamLaunchLogTail: Sendable {
    let directory: URL
    private var identity: (device: Int32, inode: UInt64)?
    private var offset: Int64 = 0
    private var readBytes = 0

    init(directory: URL) throws {
        self.directory = directory
        if let opened = try Self.open(directory) {
            defer { close(opened.fd) }
            identity = (opened.info.st_dev, opened.info.st_ino)
            offset = opened.info.st_size
        }
    }

    private static func open(_ path: URL) throws -> (fd: Int32, info: stat)? {
        guard let directory = try ManagedDirectory.openRoot(path, create: false) else { return nil }
        let fd = openat(directory.descriptor, "console_log.txt", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw EnvironmentStoreError.unsafePath
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_nlink == 1 else {
            close(fd); throw EnvironmentStoreError.unsafePath
        }
        return (fd, info)
    }

    mutating func read() throws -> Data {
        guard let opened = try Self.open(directory) else {
            if identity != nil { throw EnvironmentStoreError.identityMismatch }
            return Data()
        }
        defer { close(opened.fd) }
        if let identity {
            guard identity.device == opened.info.st_dev, identity.inode == opened.info.st_ino,
                  opened.info.st_size >= offset else { throw EnvironmentStoreError.identityMismatch }
        } else { identity = (opened.info.st_dev, opened.info.st_ino) }
        let count = Int(min(65536, opened.info.st_size - offset))
        guard readBytes + count <= 1048576 else { throw EnvironmentStoreError.documentTooLarge }
        if count == 0 { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let received = pread(opened.fd, &bytes, count, off_t(offset))
        guard received >= 0 else { throw EnvironmentStoreError.fileSystem(operation: "read launch observation", code: errno) }
        offset += Int64(received); readBytes += received
        return Data(bytes.prefix(received))
    }
}

public actor SteamGameLaunchObservation {
    private var tail: SteamLaunchLogTail?
    private var parser: SteamGameLaunchParser
    private let validate: @Sendable () async throws -> Void
    private var ended = false
    private var polling = false

    init(appID: UInt32, tail: SteamLaunchLogTail?, validate: @escaping @Sendable () async throws -> Void) {
        self.tail = tail; parser = .init(appID: appID); self.validate = validate
    }

    public func poll() async -> SteamGameLaunchProgress {
        guard !ended else { return .unavailable }
        guard !polling else { return parser.progress }
        guard var reader = tail else { ended = true; return .unavailable }
        polling = true; defer { polling = false }
        do {
            try await validate()
            let data = try reader.read()
            try await validate()
            tail = reader
            parser.receive(data)
            return parser.progress
        } catch SteamLifecycleError.observationUnavailable {
            return parser.progress
        } catch EnvironmentStoreError.busy {
            return parser.progress
        } catch { ended = true; return .unavailable }
    }
}

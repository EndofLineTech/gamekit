import Darwin
import Foundation

public enum EnvironmentStoreError: Error, Equatable {
    case unsafePath
    case alreadyExists
    case notFound
    case prefixAlreadyExists
    case identityMismatch
    case conflict
    case busy
    case documentTooLarge
    case fileSystem(operation: String, code: Int32)
}

private func ioError(_ operation: String) -> EnvironmentStoreError {
    let code = errno
    if code == ELOOP || code == ENOTDIR { return .unsafePath }
    return .fileSystem(operation: operation, code: code)
}

/// Scoped descriptors keep final writes relative to opened directories. Never follow
/// symlinks while traversing the configured root or any descendant component.
final class ManagedDirectory {
    let descriptor: Int32
    static let maximumDocumentBytes = 1_048_576

    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    func identity() throws -> (device: Int32, inode: UInt64) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ioError("stat directory") }
        return (info.st_dev, info.st_ino)
    }

    func acquireLock(_ name: String) throws -> ManagedFileLock {
        try checkName(name)
        let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ioError("open operation lock") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(fd); throw EnvironmentStoreError.unsafePath
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(fd)
            if code == EWOULDBLOCK { throw EnvironmentStoreError.busy }
            throw EnvironmentStoreError.fileSystem(operation: "lock operation", code: code)
        }
        return ManagedFileLock(fd)
    }

    static func openRoot(_ url: URL, create: Bool) throws -> ManagedDirectory? {
        guard url.isFileURL else { throw EnvironmentStoreError.unsafePath }
        let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ioError("open root") }
        var directory = ManagedDirectory(fd)
        let parts = Array(url.pathComponents.dropFirst())
        guard !parts.isEmpty else { throw EnvironmentStoreError.unsafePath }
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            guard let next = try directory.directory(part, create: create && last) else {
                if last { return nil }
                throw EnvironmentStoreError.fileSystem(operation: "open parent", code: ENOENT)
            }
            directory = next
        }
        return directory
    }

    private func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0)
        else { throw EnvironmentStoreError.unsafePath }
    }

    func directory(_ name: String, create: Bool = false) throws -> ManagedDirectory? {
        try checkName(name)
        var fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT && create {
            if mkdirat(descriptor, name, mode_t(0o700)) != 0 && errno != EEXIST {
                throw ioError("create directory")
            }
            fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ioError("open directory")
        }
        return ManagedDirectory(fd)
    }

    private func regularFile(_ name: String) throws -> Int32? {
        try checkName(name)
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ioError("open file")
        }
        var info = stat()
        if fstat(fd, &info) != 0 {
            let error = ioError("stat file")
            Darwin.close(fd)
            throw error
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(fd)
            throw EnvironmentStoreError.unsafePath
        }
        return fd
    }

    func containsRegularFile(_ name: String) throws -> Bool {
        guard let fd = try regularFile(name) else { return false }
        Darwin.close(fd)
        return true
    }

    func read(_ name: String) throws -> Data? {
        guard let fd = try regularFile(name) else { return nil }
        defer { Darwin.close(fd) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError("read metadata")
            }
            if count == 0 { return result }
            guard result.count + count <= Self.maximumDocumentBytes else {
                throw EnvironmentStoreError.documentTooLarge
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func names() throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw ioError("duplicate directory") }
        guard let stream = fdopendir(copy) else {
            let error = ioError("list metadata")
            Darwin.close(copy)
            throw error
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ioError("read directory entry") }
                return result.sorted()
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { result.append(name) }
        }
    }

    func withWriteLock<T>(_ operation: () throws -> T) throws -> T {
        let fd = openat(descriptor, ".write.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ioError("open writer lock") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ioError("stat writer lock") }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw EnvironmentStoreError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw EnvironmentStoreError.busy }
            throw ioError("lock metadata")
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    func write(_ data: Data, to name: String, createOnly: Bool, beforeCommit: () throws -> Void) throws {
        try checkName(name)
        guard data.count <= Self.maximumDocumentBytes else { throw EnvironmentStoreError.documentTooLarge }
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ioError("create temporary metadata") }
        defer {
            Darwin.close(fd)
            // Remove only the temporary file created by this operation.
            unlinkat(descriptor, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ioError("write metadata")
                }
                guard count > 0 else { throw EnvironmentStoreError.fileSystem(operation: "write metadata", code: EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ioError("sync metadata") }
        try beforeCommit()
        if createOnly {
            // Atomic no-clobber publication. A crash before temporary unlink leaves
            // a harmless orphan, not a partial or missing destination document.
            guard linkat(descriptor, temporary, descriptor, name, 0) == 0 else {
                if errno == EEXIST { throw EnvironmentStoreError.alreadyExists }
                throw ioError("publish metadata")
            }
        } else {
            guard renameat(descriptor, temporary, descriptor, name) == 0 else {
                throw ioError("replace metadata")
            }
        }
    }
}

final class ManagedFileLock: @unchecked Sendable {
    private let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

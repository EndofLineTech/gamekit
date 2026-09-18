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

    static func canonicalRoot(_ supplied: URL) throws -> URL {
        guard supplied.isFileURL, supplied.path.hasPrefix("/"), supplied.standardizedFileURL.path != "/" else {
            throw EnvironmentStoreError.unsafePath
        }
        let standardized = supplied.standardizedFileURL
        guard let resolved = realpath(standardized.deletingLastPathComponent().path, nil) else {
            throw EnvironmentStoreError.fileSystem(operation: "resolve trusted parent", code: errno)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }

    func removeRegularFile(_ name: String) throws {
        try checkName(name)
        guard try containsRegularFile(name) else { return }
        guard unlinkat(descriptor, name, 0) == 0 else { throw ioError("remove owned file") }
    }

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

    func createExclusiveDirectory(_ name: String) throws -> ManagedDirectory {
        try checkName(name)
        guard mkdirat(descriptor, name, mode_t(0o700)) == 0 else {
            if errno == EEXIST { throw EnvironmentStoreError.prefixAlreadyExists }
            throw ioError("create exclusive directory")
        }
        guard let created = try directory(name) else { throw EnvironmentStoreError.notFound }
        return created
    }

    func moveDirectory(_ name: String, to destination: ManagedDirectory, as target: String) throws {
        try checkName(name); try checkName(target)
        guard let source = try directory(name) else { throw EnvironmentStoreError.notFound }
        let identity = try source.identity()
        guard renameatx_np(descriptor, name, destination.descriptor, target, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw EnvironmentStoreError.alreadyExists }
            throw ioError("move owned directory")
        }
        guard let moved = try destination.directory(target), try moved.identity() == identity else {
            throw EnvironmentStoreError.identityMismatch
        }
    }

    /// Copy a validated runtime tree without resolving source symlinks or following
    /// a replaced destination pathname. APFS clones avoid duplicating binary data.
    func copyContents(from source: ManagedDirectory, shareRegularFiles: Bool = false) throws {
        for name in try source.names() {
            var info = stat()
            guard fstatat(source.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ioError("inspect copy source") }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                guard let child = try source.directory(name) else { throw EnvironmentStoreError.notFound }
                let copy = try createExclusiveDirectory(name)
                try copy.copyContents(from: child, shareRegularFiles: shareRegularFiles)
                guard fchmod(copy.descriptor, info.st_mode & 0o777) == 0 else { throw ioError("copy directory permissions") }
            case mode_t(S_IFREG):
                guard let input = try source.regularFile(name) else { throw EnvironmentStoreError.notFound }
                defer { Darwin.close(input) }
                if shareRegularFiles {
                    guard linkat(source.descriptor, name, descriptor, name, 0) == 0 else { throw ioError("share runtime image") }
                    guard let output = try regularFile(name) else { throw EnvironmentStoreError.notFound }
                    defer { Darwin.close(output) }
                    var original = stat(), linked = stat()
                    guard fstat(input, &original) == 0, fstat(output, &linked) == 0,
                          original.st_dev == linked.st_dev, original.st_ino == linked.st_ino else { throw EnvironmentStoreError.identityMismatch }
                } else if fclonefileat(input, descriptor, name, 0) != 0 {
                    guard errno == ENOTSUP || errno == EXDEV else { throw ioError("clone runtime file") }
                    let output = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                    guard output >= 0 else { throw ioError("create runtime copy") }
                    defer { Darwin.close(output) }
                    guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw ioError("copy runtime file") }
                }
            case mode_t(S_IFLNK):
                var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = readlinkat(source.descriptor, name, &target, target.count - 1)
                guard count >= 0, count < target.count - 1,
                      let link = String(bytes: target.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8)
                else { throw EnvironmentStoreError.unsafePath }
                try createSymbolicLink(name, target: link)
            default: throw EnvironmentStoreError.unsafePath
            }
        }
    }

    /// Wine shares PE image mappings by file identity. Game loaders must retain
    /// the Steam client's PE inodes so remote-thread entry points remain valid.
    func validateSharedFiles(from source: ManagedDirectory) throws {
        guard try names() == source.names() else { throw EnvironmentStoreError.identityMismatch }
        for name in try names() {
            var original = stat(), linked = stat()
            guard fstatat(source.descriptor, name, &original, AT_SYMLINK_NOFOLLOW) == 0,
                  fstatat(descriptor, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  original.st_mode & mode_t(S_IFMT) == linked.st_mode & mode_t(S_IFMT) else { throw EnvironmentStoreError.identityMismatch }
            if original.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                guard let a = try source.directory(name), let b = try directory(name) else { throw EnvironmentStoreError.notFound }
                try b.validateSharedFiles(from: a)
            } else if original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                guard original.st_dev == linked.st_dev, original.st_ino == linked.st_ino else { throw EnvironmentStoreError.identityMismatch }
            } else if original.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                var a = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                var b = a
                let left = readlinkat(source.descriptor, name, &a, a.count - 1)
                let right = readlinkat(descriptor, name, &b, b.count - 1)
                guard left >= 0, left < a.count - 1, left == right,
                      a.prefix(left).elementsEqual(b.prefix(right)) else { throw EnvironmentStoreError.identityMismatch }
            } else {
                throw EnvironmentStoreError.unsafePath
            }
        }
    }

    func createSymbolicLink(_ name: String, target: String) throws {
        try checkName(name)
        guard !target.utf8.contains(0), symlinkat(target, descriptor, name) == 0 else { throw ioError("create owned symlink") }
    }

    func renameRegularFile(_ name: String, to target: String) throws {
        try checkName(name); try checkName(target)
        guard try containsRegularFile(name) else { throw EnvironmentStoreError.notFound }
        guard renameatx_np(descriptor, name, descriptor, target, UInt32(RENAME_EXCL)) == 0 else { throw ioError("rename owned file") }
    }

    func removeEmptyDirectory(_ name: String, identity: (device: Int32, inode: UInt64)) throws {
        guard let directory = try directory(name), try directory.identity() == identity else { throw EnvironmentStoreError.identityMismatch }
        guard try directory.names().isEmpty else { throw EnvironmentStoreError.conflict }
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw ioError("remove empty owned directory") }
    }

    /// Used only for this operation's private staging tree, never Wine prefixes.
    func removeStagingDirectory(_ name: String, identity: (device: Int32, inode: UInt64)) throws {
        try removeOwnedTree(name, identity: identity, afterRemoval: {})
    }

    /// Only the journaled quarantine's `prefix` is eligible for confirmed deletion.
    func removeQuarantinedPrefix(identity: (device: Int32, inode: UInt64), afterRemoval: () throws -> Void) throws {
        try removeOwnedTree("prefix", identity: identity, afterRemoval: afterRemoval)
    }

    /// Descriptor-relative inventory; never follows Wine's links into host data.
    func logicalBytes() throws -> Int64 {
        var total: Int64 = 0
        let device = try identity().device
        for name in try names() {
            try Task.checkCancellation()
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ioError("inspect archive size") }
            guard info.st_dev == device else { throw EnvironmentStoreError.unsafePath }
            let size: Int64
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                guard let child = try directory(name), try child.identity() == (info.st_dev, info.st_ino) else { throw EnvironmentStoreError.identityMismatch }
                size = try child.logicalBytes()
            } else { size = max(0, info.st_size) }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { throw EnvironmentStoreError.unsafePath }
            total = sum.partialValue
        }
        return total
    }

    private func removeOwnedTree(_ name: String, identity: (device: Int32, inode: UInt64), afterRemoval: () throws -> Void) throws {
        guard let directory = try directory(name), try directory.identity() == identity else { throw EnvironmentStoreError.identityMismatch }
        for child in try directory.names() {
            var info = stat()
            guard fstatat(directory.descriptor, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ioError("inspect staging entry") }
            guard info.st_dev == identity.device else { throw EnvironmentStoreError.unsafePath }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                guard let nested = try directory.directory(child) else { throw EnvironmentStoreError.notFound }
                try directory.removeOwnedTree(child, identity: nested.identity(), afterRemoval: afterRemoval)
            } else {
                guard unlinkat(directory.descriptor, child, 0) == 0 else { throw ioError("remove staging entry") }
                try afterRemoval()
            }
        }
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw ioError("remove staging directory") }
        try afterRemoval()
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

    func read(_ name: String, maximumBytes: Int = ManagedDirectory.maximumDocumentBytes) throws -> Data? {
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
            guard result.count + count <= maximumBytes else {
                throw EnvironmentStoreError.documentTooLarge
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func names() throws -> [String] {
        // dup() shares the directory cursor: a second enumeration would begin at
        // EOF. Open the pinned directory again for an independent file description.
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw ioError("open directory iterator") }
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

    func write(_ data: Data, to name: String, createOnly: Bool, temporaryPrefix: String = ".",
               maximumBytes: Int = ManagedDirectory.maximumDocumentBytes, beforeCommit: () throws -> Void) throws {
        try checkName(name)
        guard data.count <= maximumBytes else { throw EnvironmentStoreError.documentTooLarge }
        let temporary = "\(temporaryPrefix)\(UUID().uuidString).tmp"
        try checkName(temporary)
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

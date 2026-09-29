import CryptoKit
import Foundation

/// Publishes only the exact bundled launcher revision after a complete,
/// bounded official download. Each launcher has a private receipt directory.
public actor ManagedLauncherInstallerAcquisition {
    public nonisolated let root: URL
    private let profile: LauncherProfile
    private let transfer: @Sendable () async throws -> InstallerPayload
    private var acquiring = false

    public init(profile: LauncherProfile, root: URL = EnvironmentStore.applicationSupportRoot) throws {
        try profile.validate()
        self.profile = profile; self.root = try ManagedDirectory.canonicalRoot(root)
        let policy = InstallerEndpointPolicy(source: profile.installer.url, maximumBytes: profile.installer.maximumBytes)
        transfer = { try await InstallerHTTPClient.fetch(policy: policy) }
    }

    init(profile: LauncherProfile, root: URL, transfer: @escaping @Sendable () async throws -> InstallerPayload) throws {
        try profile.validate()
        self.profile = profile; self.root = try ManagedDirectory.canonicalRoot(root); self.transfer = transfer
    }

    private var policy: InstallerEndpointPolicy {
        .init(source: profile.installer.url, maximumBytes: profile.installer.maximumBytes)
    }
    private func directory(create: Bool) throws -> ManagedDirectory {
        guard let root = try ManagedDirectory.openRoot(root, create: create),
              let downloads = try root.directory("InstallerDownloads", create: create),
              let directory = try downloads.directory(profile.id.rawValue, create: create)
        else { throw EnvironmentStoreError.notFound }
        return directory
    }
    private func stem(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func acquire() async throws -> InstallerArtifact {
        try Task.checkCancellation()
        guard !acquiring else { throw EnvironmentStoreError.busy }
        acquiring = true
        defer { acquiring = false }
        let directory = try directory(create: true)
        let lease = try directory.acquireLock(".acquisition.lock")
        defer { withExtendedLifetime(lease) {} }
        for name in try directory.names() where name.hasPrefix(".installer-") && name.hasSuffix(".tmp") {
            if UUID(uuidString: String(name.dropFirst(11).dropLast(4))) != nil { try directory.removeRegularFile(name) }
        }
        let payload = try await transfer()
        try Task.checkCancellation()
        try payload.validate(policy: policy)
        let hash = digest(payload.data)
        guard hash == profile.installer.sha256 else { throw InstallerAcquisitionError.artifactChanged }
        let artifact = InstallerArtifact(schemaVersion: 1, id: UUID(),
            provenance: .init(source: profile.installer.url, sha256: hash, downloadedAt: Date()),
            finalURL: payload.finalURL, byteCount: payload.data.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let receipt = try encoder.encode(artifact)
        let name = stem(artifact.id)
        func checkPublication() throws {
            try Task.checkCancellation()
            guard try directory.identity() == self.directory(create: false).identity() else {
                throw EnvironmentStoreError.identityMismatch
            }
        }
        try directory.write(payload.data, to: name + ".exe", createOnly: true, temporaryPrefix: ".installer-",
                            maximumBytes: profile.installer.maximumBytes, beforeCommit: checkPublication)
        do {
            try directory.write(receipt, to: name + ".json", createOnly: true, temporaryPrefix: ".installer-", beforeCommit: checkPublication)
        } catch {
            try? directory.removeRegularFile(name + ".exe")
            throw error
        }
        return artifact
    }

    public func load(_ id: UUID) throws -> InstallerArtifact {
        let directory = try directory(create: false)
        guard let receipt = try directory.read(stem(id) + ".json") else { throw EnvironmentStoreError.notFound }
        let artifact = try JSONDecoder().decode(InstallerArtifact.self, from: receipt)
        guard artifact.schemaVersion == 1, artifact.id == id,
              artifact.provenance.source == policy.source, policy.allows(artifact.finalURL),
              artifact.provenance.downloadedAt.timeIntervalSince1970.isFinite,
              (1...policy.maximumBytes).contains(artifact.byteCount),
              artifact.provenance.sha256 == profile.installer.sha256
        else { throw InstallerAcquisitionError.invalidReceipt }
        guard let data = try directory.read(stem(id) + ".exe", maximumBytes: policy.maximumBytes),
              data.count == artifact.byteCount, digest(data) == artifact.provenance.sha256
        else { throw InstallerAcquisitionError.artifactChanged }
        try InstallerExecutable.validate(data)
        return artifact
    }

    public func validatedURL(for artifact: InstallerArtifact) throws -> URL {
        guard try load(artifact.id) == artifact else { throw InstallerAcquisitionError.artifactChanged }
        return root.appendingPathComponent("InstallerDownloads/\(profile.id.rawValue)/\(stem(artifact.id)).exe")
    }
}

import CryptoKit
import Foundation

public struct InstallerArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let provenance: InstallerProvenance
    public let finalURL: URL
    public let byteCount: Int
}

/// Publishes a receipt only after a complete, validated download is atomically
/// saved. Call validatedURL immediately before handing an artifact to a coordinator.
public actor SteamInstallerAcquisition {
    public nonisolated let root: URL
    private let transfer: @Sendable () async throws -> InstallerPayload
    private var acquiring = false

    public init(root: URL = EnvironmentStore.applicationSupportRoot) throws {
        self.root = try ManagedDirectory.canonicalRoot(root)
        transfer = { try await InstallerHTTPClient.fetch() }
    }
    init(root: URL, transfer: @escaping @Sendable () async throws -> InstallerPayload) throws {
        self.root = try ManagedDirectory.canonicalRoot(root); self.transfer = transfer
    }
    private func directory(create: Bool) throws -> ManagedDirectory {
        guard let root = try ManagedDirectory.openRoot(root, create: create),
              let directory = try root.directory("InstallerDownloads", create: create)
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
        // Under the acquisition lease, only strictly named abandoned temporaries
        // belong to this subsystem. Completed or unrelated files are preserved.
        for name in try directory.names() where name.hasPrefix(".installer-") && name.hasSuffix(".tmp") {
            if UUID(uuidString: String(name.dropFirst(11).dropLast(4))) != nil { try directory.removeRegularFile(name) }
        }
        let payload = try await transfer()
        try Task.checkCancellation()
        try payload.validate()
        let artifact = InstallerArtifact(schemaVersion: 1, id: UUID(),
            provenance: .init(source: InstallerSourcePolicy.source, sha256: digest(payload.data), downloadedAt: Date()),
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
                            maximumBytes: InstallerSourcePolicy.maximumBytes, beforeCommit: checkPublication)
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
              artifact.provenance.source == InstallerSourcePolicy.source, InstallerSourcePolicy.allows(artifact.finalURL),
              artifact.provenance.downloadedAt.timeIntervalSince1970.isFinite,
              (1...InstallerSourcePolicy.maximumBytes).contains(artifact.byteCount),
              artifact.provenance.sha256.count == 64,
              artifact.provenance.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw InstallerAcquisitionError.invalidReceipt }
        guard let data = try directory.read(stem(id) + ".exe", maximumBytes: InstallerSourcePolicy.maximumBytes),
              data.count == artifact.byteCount, digest(data) == artifact.provenance.sha256
        else { throw InstallerAcquisitionError.artifactChanged }
        try InstallerExecutable.validate(data)
        return artifact
    }

    public func validatedURL(for artifact: InstallerArtifact) throws -> URL {
        guard try load(artifact.id) == artifact else { throw InstallerAcquisitionError.artifactChanged }
        return root.appendingPathComponent("InstallerDownloads/\(stem(artifact.id)).exe")
    }
}

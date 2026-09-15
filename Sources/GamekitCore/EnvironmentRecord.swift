import Foundation

public enum MetadataError: Error, Equatable {
    case invalidIdentifier
    case invalidRelativePath
    case unsupportedSchema(Int)
    case invalidRecord
    case invalidInstaller
}

/// A canonical single-component key, never a display name or caller-supplied path.
public struct EnvironmentID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ value: String) throws {
        guard value.range(of: "\\A[a-z0-9][a-z0-9_-]{0,63}\\z", options: .regularExpression) != nil
        else { throw MetadataError.invalidIdentifier }
        rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A disk-relative POSIX path. It is not a Windows path, URL or shell expression.
public struct RelativePath: Hashable, Codable, Sendable {
    public let rawValue: String
    var components: [String] { rawValue.components(separatedBy: "/") }

    public init(_ value: String) throws {
        let parts = value.components(separatedBy: "/")
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !value.contains(":"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw MetadataError.invalidRelativePath }
        rawValue = value
    }

    private init(validated value: String) { rawValue = value }
    public static let steamDefault = RelativePath(validated: "drive_c/Program Files (x86)/Steam/Steam.exe")

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeIdentity: Codable, Equatable, Sendable {
    public let provider: String
    public let distribution: String
    public let wine: String
    public let graphics: String

    public init(provider: String, distribution: String, wine: String, graphics: String) {
        self.provider = provider
        self.distribution = distribution
        self.wine = wine
        self.graphics = graphics
    }
}

/// Original public download URL and artifact identity, not an authenticity claim.
public struct InstallerProvenance: Codable, Equatable, Sendable {
    public let source: URL
    public let sha256: String
    public let downloadedAt: Date

    public init(source: URL, sha256: String, downloadedAt: Date) {
        self.source = source
        self.sha256 = sha256
        self.downloadedAt = downloadedAt
    }
}

public enum InstallationStage: String, Codable, Sendable {
    case downloadingInstaller, creatingPrefix, runningInstaller, bootstrappingSteam, validatingInstallation
}

public enum EnvironmentFailure: String, Codable, Sendable {
    case downloadFailed, installerFailed, bootstrapFailed, invalidRuntime
    case prefixMissing, executableMissing, unexpectedPrefix, inconsistentObservation
}

/// Durable progress. Running and prerequisite readiness are deliberately not persisted.
public enum InstallationProgress: Codable, Equatable, Sendable {
    case notStarted
    case installing(InstallationStage)
    case installed
    case failed(EnvironmentFailure)
    case interrupted(InstallationStage)
}

public struct EnvironmentRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: EnvironmentID
    public var name: String
    public var runtime: RuntimeIdentity?
    public var installer: InstallerProvenance?
    public var steamExecutable: RelativePath
    public var installation: InstallationProgress
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var revision: Int

    public init(id: EnvironmentID, name: String, runtime: RuntimeIdentity? = nil,
                installer: InstallerProvenance? = nil, steamExecutable: RelativePath = .steamDefault,
                installation: InstallationProgress = .notStarted, createdAt: Date = Date()) throws {
        schemaVersion = 1
        self.id = id
        self.name = name
        self.runtime = runtime
        self.installer = installer
        self.steamExecutable = steamExecutable
        self.installation = installation
        self.createdAt = createdAt
        updatedAt = createdAt
        revision = 0
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, runtime, installer, steamExecutable, installation, createdAt, updatedAt, revision
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw MetadataError.unsupportedSchema(schemaVersion) }
        id = try values.decode(EnvironmentID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        runtime = try values.decodeIfPresent(RuntimeIdentity.self, forKey: .runtime)
        installer = try values.decodeIfPresent(InstallerProvenance.self, forKey: .installer)
        steamExecutable = try values.decode(RelativePath.self, forKey: .steamExecutable)
        installation = try values.decode(InstallationProgress.self, forKey: .installation)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        revision = try values.decode(Int.self, forKey: .revision)
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw MetadataError.unsupportedSchema(schemaVersion) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              revision >= 0, revision < Int.max,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt,
              steamExecutable.components.first == "drive_c", steamExecutable.rawValue.lowercased().hasSuffix(".exe")
        else { throw MetadataError.invalidRecord }
        if let runtime {
            guard [runtime.provider, runtime.distribution, runtime.wine, runtime.graphics]
                .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw MetadataError.invalidRecord }
        }
        if let installer {
            guard installer.source.scheme?.lowercased() == "https", installer.source.host != nil,
                  installer.source.user == nil, installer.source.password == nil,
                  installer.sha256.count == 64,
                  installer.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  installer.downloadedAt.timeIntervalSince1970.isFinite
            else { throw MetadataError.invalidInstaller }
        }
    }
}

public enum EnvironmentDocument {
    public static func encode(_ record: EnvironmentRecord) throws -> Data {
        try record.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(record)
    }

    public static func decode(_ data: Data) throws -> EnvironmentRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(EnvironmentRecord.self, from: data)
    }
}

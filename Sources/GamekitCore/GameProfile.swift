import Foundation

public enum GameProfileError: Error { case invalid, rollback, response }

public struct GameExecutionParameters: Codable, Equatable, Sendable {
    public struct Driver: Codable, Equatable, Sendable {
        public let runtimeRevisions: [RuntimeRevision]
        public let backends: [GraphicsBackend]
        public let defaultEnabled: Bool
        public let matchVersion: [UInt16]
        public let replacementVersion: [UInt16]
        public let guidance: String
        public func available(revision: RuntimeRevision) -> Bool { runtimeRevisions.contains(revision) }
        var matchHex: String { matchVersion.map { String(format: "%04x", $0) }.joined() }
        var replacementHex: String { replacementVersion.map { String(format: "%04x", $0) }.joined() }
    }
    public struct Capture: Codable, Equatable, Sendable {
        public let inheritedDefault: Bool
        public let guidance: String
    }
    public struct FullscreenSpace: Codable, Equatable, Sendable {
        public let defaultEnabled: Bool
        public let guidance: String
    }
    public var executable: String? = nil
    public var driver: Driver? = nil
    public var capture: Capture? = nil
    public var fullscreenSpace: FullscreenSpace? = nil
    public var hasSettings: Bool { driver != nil || capture != nil || fullscreenSpace != nil }

    static func validate(_ object: [String: Any]) throws {
        guard Set(object.keys).isSubset(of: ["executable", "driver", "capture", "fullscreenSpace"]) else { throw GameProfileError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        guard !object.values.contains(where: { $0 is NSNull }) else { throw GameProfileError.invalid }
        if value.hasSettings {
            guard let executable = value.executable,
                  executable.range(of: #"\A[a-z0-9][a-z0-9 ._()'-]{0,200}\.exe\z"#, options: .regularExpression) != nil
            else { throw GameProfileError.invalid }
        } else if value.executable != nil { throw GameProfileError.invalid }
        func fields(_ name: String, _ required: Set<String>) throws {
            guard let fields = object[name] as? [String: Any], Set(fields.keys) == required,
                  let guidance = fields["guidance"] as? String, !guidance.isEmpty, guidance.utf8.count <= 2048,
                  guidance.rangeOfCharacter(from: .controlCharacters) == nil else { throw GameProfileError.invalid }
        }
        if let driver = value.driver {
            try fields("driver", ["runtimeRevisions", "backends", "defaultEnabled", "matchVersion", "replacementVersion", "guidance"])
            guard !driver.runtimeRevisions.isEmpty, driver.runtimeRevisions.count <= RuntimeRevision.allCases.count,
                  driver.runtimeRevisions.allSatisfy({ $0.profile.hashes[RuntimeProfile.driverOriginalRelative] != nil }),
                  !driver.backends.isEmpty, driver.backends.count <= 2, driver.backends.allSatisfy({ $0 == .automatic || $0 == .metal3 }),
                  driver.matchVersion.count == 4, driver.replacementVersion.count == 4 else { throw GameProfileError.invalid }
        }
        if let capture = value.capture {
            try fields("capture", ["inheritedDefault", "guidance"])
            // Wine's absent global key means disabled. Changing that platform
            // default needs an explicit registry override, not a guessed value.
            guard !capture.inheritedDefault else { throw GameProfileError.invalid }
        }
        if value.fullscreenSpace != nil { try fields("fullscreenSpace", ["defaultEnabled", "guidance"]) }
    }
}

/// Declarative launch data only. Runtime/payload installation and executable
/// selection remain the responsibility of the qualified launcher.
public struct GameProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let appId: UInt32
    public let name: String
    public let runtime: String
    public let launchArguments: [String: [String]]
    public let notes: String
    public var execution: GameExecutionParameters { storedExecution ?? .init() }
    private let storedExecution: GameExecutionParameters?
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, appId, name, runtime, launchArguments, notes
        case storedExecution = "execution"
    }
    static let maximumBytes = 32768

    public func arguments(for backend: GraphicsBackend) -> [String] { launchArguments[backend.rawValue] ?? [] }

    static func decode(_ data: Data, appID: UInt32) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "revision", "appId", "name", "runtime", "launchArguments", "notes"] +
                ((object["schemaVersion"] as? Int) == 2 ? ["execution"] : []))
        else { throw GameProfileError.invalid }
        if (object["schemaVersion"] as? Int) == 2 {
            guard let execution = object["execution"] as? [String: Any] else { throw GameProfileError.invalid }
            try GameExecutionParameters.validate(execution)
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        func text(_ string: String, limit: Int) -> Bool {
            !string.trimmingCharacters(in: .whitespaces).isEmpty && string.utf8.count <= limit &&
                !string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard [1, 2].contains(value.schemaVersion), value.revision > 0, value.revision <= 1_000_000,
              appID > 0, value.appId == appID, text(value.name, limit: 256), text(value.notes, limit: 4096),
              value.runtime == "sikarugir-10.0_6",
              Set(value.launchArguments.keys).isSubset(of: Set(GraphicsBackend.allCases.map(\.rawValue))),
              value.launchArguments.values.allSatisfy({ arguments in
                  arguments.count <= 16 && arguments.allSatisfy { argument in
                      // Each entry is one game argument, never a shell command,
                      // Steam command template, executable or environment value.
                      argument.range(of: #"\A-[A-Za-z0-9_:.\[\]=,+/\-]{1,511}\z"#, options: .regularExpression) != nil
                  }
              }) else { throw GameProfileError.invalid }
        return value
    }
}

public struct ResolvedGameProfile: Sendable {
    public let profile: GameProfile
    public let source: String
}

public actor GameProfileStore {
    public static let website = URL(string: "https://endoflinetech.github.io/gamekit/")!
    private let root: URL
    private let session: URLSession
    private var attempts: [UInt32: Date] = [:]

    public init(root: URL) {
        self.root = root
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: ProfileRedirectPolicy(), delegateQueue: nil)
    }

    init(root: URL, session: URLSession) { self.root = root; self.session = session }

    public static func url(appID: UInt32) -> URL { website.appendingPathComponent("profiles/\(appID).json") }

    public static func bundled(appID: UInt32) -> GameProfile? {
        guard let url = Bundle.module.url(forResource: String(appID), withExtension: "json", subdirectory: "GameProfiles"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? GameProfile.decode(data, appID: appID)
    }

    public static func resolved(appID: UInt32, root: URL) -> ResolvedGameProfile? {
        let bundled = bundled(appID: appID)
        if let directory = try? cache(root: root, create: false),
           let data = try? directory.read("\(appID).json", maximumBytes: GameProfile.maximumBytes),
           let cached = try? GameProfile.decode(data, appID: appID), cached.revision >= (bundled?.revision ?? 0) {
            return .init(profile: cached, source: "Downloaded from compatibility wiki")
        }
        return bundled.map { .init(profile: $0, source: "Bundled offline profile") }
    }

    private static func cache(root: URL, create: Bool) throws -> ManagedDirectory? {
        try ManagedDirectory.openRoot(ManagedDirectory.canonicalRoot(root), create: create)?.directory("Metadata", create: create)?
            .directory("GameProfiles", create: create)
    }

    /// The only persistence boundary; validate completely before atomic replacement.
    @discardableResult func accept(_ data: Data, appID: UInt32) throws -> Bool {
        let profile = try GameProfile.decode(data, appID: appID)
        guard let directory = try Self.cache(root: root, create: true) else { throw EnvironmentStoreError.notFound }
        let lock = try directory.acquireLock("profiles.lock")
        defer { withExtendedLifetime(lock) {} }
        let previous = Self.resolved(appID: appID, root: root)?.profile
        if let previous {
            guard profile.revision >= previous.revision,
                  profile.revision != previous.revision || profile == previous else { throw GameProfileError.rollback }
        }
        try directory.write(data, to: "\(appID).json", createOnly: false, beforeCommit: {})
        return previous != profile
    }

    /// Library polling is cheap: each AppID gets at most one attempt per day in
    /// this app session, including missing profiles and transient network errors.
    @discardableResult public func refresh(appID: UInt32, force: Bool = false) async throws -> Bool {
        guard appID > 0 else { throw GameProfileError.invalid }
        if !force, let last = attempts[appID], Date().timeIntervalSince(last) < 86400 { return false }
        attempts[appID] = Date()
        var request = URLRequest(url: Self.url(appID: appID))
        if force { request.cachePolicy = .reloadIgnoringLocalCacheData }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw GameProfileError.response }
        if response.statusCode == 404 { return false }
        guard response.statusCode == 200, response.mimeType == "application/json",
              response.expectedContentLength <= GameProfile.maximumBytes else { throw GameProfileError.response }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < GameProfile.maximumBytes else { throw GameProfileError.invalid }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try accept(data, appID: appID)
    }
}

private final class ProfileRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

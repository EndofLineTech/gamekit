import Foundation

public enum GameProfileError: Error { case invalid, rollback, response }

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
    static let maximumBytes = 32768

    public func arguments(for backend: GraphicsBackend) -> [String] { launchArguments[backend.rawValue] ?? [] }

    static func decode(_ data: Data, appID: UInt32) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "revision", "appId", "name", "runtime", "launchArguments", "notes"])
        else { throw GameProfileError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        func text(_ string: String, limit: Int) -> Bool {
            !string.trimmingCharacters(in: .whitespaces).isEmpty && string.utf8.count <= limit &&
                !string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard value.schemaVersion == 1, value.revision > 0, value.revision <= 1_000_000,
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
    func accept(_ data: Data, appID: UInt32) throws {
        let profile = try GameProfile.decode(data, appID: appID)
        guard let directory = try Self.cache(root: root, create: true) else { throw EnvironmentStoreError.notFound }
        let lock = try directory.acquireLock("profiles.lock")
        defer { withExtendedLifetime(lock) {} }
        if let previous = Self.resolved(appID: appID, root: root)?.profile {
            guard profile.revision >= previous.revision,
                  profile.revision != previous.revision || profile == previous else { throw GameProfileError.rollback }
        }
        try directory.write(data, to: "\(appID).json", createOnly: false, beforeCommit: {})
    }

    /// Library polling is cheap: each AppID gets at most one attempt per day in
    /// this app session, including missing profiles and transient network errors.
    public func refresh(appID: UInt32, force: Bool = false) async throws {
        guard appID > 0 else { throw GameProfileError.invalid }
        if !force, let last = attempts[appID], Date().timeIntervalSince(last) < 86400 { return }
        attempts[appID] = Date()
        var request = URLRequest(url: Self.url(appID: appID))
        if force { request.cachePolicy = .reloadIgnoringLocalCacheData }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw GameProfileError.response }
        if response.statusCode == 404 { return }
        guard response.statusCode == 200, response.mimeType == "application/json",
              response.expectedContentLength <= GameProfile.maximumBytes else { throw GameProfileError.response }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < GameProfile.maximumBytes else { throw GameProfileError.invalid }
            data.append(byte)
        }
        try Task.checkCancellation()
        try accept(data, appID: appID)
    }
}

private final class ProfileRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

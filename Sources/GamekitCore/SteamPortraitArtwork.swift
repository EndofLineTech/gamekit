import Foundation
import ImageIO

public struct SteamArtworkKey: Hashable, Sendable {
    public enum Kind: Sendable { case portrait, landscapeHeader }
    public let installation: SteamGameInstallationID
    public let kind: Kind
    public init(installation: SteamGameInstallationID, kind: Kind) {
        self.installation = installation
        self.kind = kind
    }
}

private final class SteamArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let target = request.url
        completionHandler(target?.scheme == "https" && target?.host?.lowercased() == "cdn.akamai.steamstatic.com" ? request : nil)
    }
}

/// Read-only, bounded portrait loader. A missing or offline cover never changes
/// library state or blocks a launch. Call from a view's cancellable `.task(id:)`.
public actor SteamPortraitArtworkCache {
    public static let maximumBytes = 1_048_576
    private let prefix: URL
    private let steamExecutable: RelativePath
    private let remote: @Sendable (URL) async throws -> Data?
    private var cached: [SteamArtworkKey: Data] = [:]
    private var order: [SteamArtworkKey] = []
    private var activeRequests = 0
    private let maximumEntries = 16

    public init(prefix: URL, steamExecutable: RelativePath = .steamDefault) {
        self.prefix = prefix
        self.steamExecutable = steamExecutable
        remote = Self.download
    }

    init(prefix: URL, steamExecutable: RelativePath = .steamDefault,
         remote: @escaping @Sendable (URL) async throws -> Data?) {
        self.prefix = prefix
        self.steamExecutable = steamExecutable
        self.remote = remote
    }

    public func portrait(for id: SteamGameInstallationID) async -> Data? {
        guard id.environmentID == SteamInstallationRecipe.environmentID, id.appID > 0, !Task.isCancelled else { return nil }
        let key = SteamArtworkKey(installation: id, kind: .portrait)
        if let saved = cached[key] { return saved }
        if let local = try? SteamGameLibrary.cachedPortrait(prefix: prefix, steamExecutable: steamExecutable,
                                                              appID: id.appID), Self.valid(local) {
            remember(local, for: key)
            return local
        }
        while activeRequests >= 4 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let url = URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id.appID)/library_600x900.jpg")!
        guard let bytes = try? await remote(url), !Task.isCancelled, Self.valid(bytes) else { return nil }
        remember(bytes, for: key)
        return bytes
    }

    private func remember(_ bytes: Data, for key: SteamArtworkKey) {
        cached[key] = bytes
        order.append(key)
        if order.count > maximumEntries { cached.removeValue(forKey: order.removeFirst()) }
    }

    private static func valid(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (32...1024).contains(width), (48...1536).contains(height),
              (1.35...1.65).contains(Double(height) / Double(width)),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }

    private static func download(_ url: URL) async throws -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: config, delegate: SteamArtworkRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host?.lowercased() == "cdn.akamai.steamstatic.com",
              response.mimeType?.lowercased() == "image/jpeg",
              response.expectedContentLength <= maximumBytes else { return nil }
        var image = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            image.append(byte)
            if image.count > maximumBytes { return nil }
        }
        return image
    }
}

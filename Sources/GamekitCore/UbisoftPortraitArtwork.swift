import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct UbisoftArtworkProfile: Decodable, Sendable {
    struct Cover: Decodable, Sendable {
        let gameID: UInt32
        let sourcePage: URL
        let role: String
        let imageURL: URL
        let sha256: String
    }

    let schemaVersion: Int
    let launcherID: EnvironmentID
    let covers: [Cover]

    static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "ubisoft", withExtension: "json", subdirectory: "ArtworkProfiles")
        else { throw UbisoftGameCatalogError.unavailable }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768 else { throw UbisoftGameCatalogError.invalidRecord }
        let profile = try JSONDecoder().decode(Self.self, from: data)
        guard profile.schemaVersion == 1, profile.launcherID.rawValue == "ubisoft",
              profile.covers.count <= 64,
              Set(profile.covers.map(\.gameID)).count == profile.covers.count
        else { throw UbisoftGameCatalogError.invalidRecord }
        for cover in profile.covers {
            let page = URLComponents(url: cover.sourcePage, resolvingAgainstBaseURL: false)
            let image = URLComponents(url: cover.imageURL, resolvingAgainstBaseURL: false)
            let productID = cover.sourcePage.deletingPathExtension().lastPathComponent
            guard cover.gameID > 0, cover.role == "edition_packshot",
                  productID.range(of: "\\A[0-9a-f]{24}\\z", options: .regularExpression) != nil,
                  page?.scheme == "https", page?.host?.lowercased() == "store.ubisoft.com",
                  page?.user == nil, page?.password == nil, page?.port == nil,
                  page?.query == nil, page?.fragment == nil, cover.sourcePage.path.hasSuffix("/\(productID).html"),
                  image?.scheme == "https", image?.host?.lowercased() == page?.host?.lowercased(),
                  image?.user == nil, image?.password == nil, image?.port == nil,
                  image?.query == nil, image?.fragment == nil,
                  cover.imageURL.path.hasPrefix("/on/demandware.static/-/Sites-masterCatalog/default/"),
                  cover.imageURL.path.hasSuffix("/images/large/\(productID).jpg"),
                  cover.sha256.count == 64,
                  cover.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
            else { throw UbisoftGameCatalogError.invalidRecord }
        }
        return profile
    }
}

private final class UbisoftArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Public Ubisoft Store edition packshots, explicitly mapped to verified Uplay
/// install IDs in bundled JSON. No game title search, account data or prefix reads.
public actor UbisoftPortraitArtworkCache {
    public static let maximumBytes = 1_048_576
    private let covers: [UInt32: UbisoftArtworkProfile.Cover]
    private let remote: @Sendable (URL) async throws -> Data?
    private var cached: [UInt32: Data] = [:]
    private var order: [UInt32] = []
    private var activeRequests = 0

    public init() throws {
        let profile = try UbisoftArtworkProfile.bundled()
        covers = Dictionary(uniqueKeysWithValues: profile.covers.map { ($0.gameID, $0) })
        remote = Self.download
    }

    init(profile: UbisoftArtworkProfile, remote: @escaping @Sendable (URL) async throws -> Data?) {
        covers = Dictionary(uniqueKeysWithValues: profile.covers.map { ($0.gameID, $0) })
        self.remote = remote
    }

    public func portrait(for id: UInt32) async -> Data? {
        guard let cover = covers[id], !Task.isCancelled else { return nil }
        if let saved = cached[id] { return saved }
        while activeRequests >= 4 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        activeRequests += 1
        defer { activeRequests -= 1 }
        guard let bytes = try? await remote(cover.imageURL), !Task.isCancelled,
              Self.valid(bytes, sha256: cover.sha256) else { return nil }
        cached[id] = bytes
        order.append(id)
        if order.count > 16 { cached.removeValue(forKey: order.removeFirst()) }
        return bytes
    }

    private static func valid(_ bytes: Data, sha256: String) -> Bool {
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (200...1200).contains(width), (300...1800).contains(height),
              (1.25...1.65).contains(Double(height) / Double(width)),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }

    private static func download(_ url: URL) async throws -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: config, delegate: UbisoftArtworkRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url, response.mimeType?.lowercased() == "image/jpeg",
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

import Foundation

public enum InstallerAcquisitionError: Error, Equatable {
    case invalidSource, invalidResponse, tooLarge, incompleteTransfer, invalidExecutable, invalidReceipt, artifactChanged
}

/// Exact public endpoint linked by Valve's About page. New CDN endpoints require
/// an explicit policy update, not a wildcard trust expansion during a redirect.
public enum InstallerSourcePolicy {
    public static let source = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!
    public static let maximumBytes = 32 * 1024 * 1024

    static func allows(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host == "cdn.fastly.steamstatic.com" &&
            (parts.port == nil || parts.port == 443) && parts.user == nil && parts.password == nil &&
            parts.percentEncodedPath == "/client/installer/SteamSetup.exe" && parts.query == nil && parts.fragment == nil
    }
}

final class InstallerRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func accept(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count <= 5 && InstallerSourcePolicy.allows(url)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, accept(url) else { completionHandler(nil); return }
        // Build a fresh request instead of forwarding cookies or arbitrary headers.
        completionHandler(InstallerHTTPClient.request(url))
    }
}

struct InstallerPayload: Sendable {
    let data: Data
    let finalURL: URL
    let status: Int
    let expectedBytes: Int64

    func validate() throws {
        try InstallerHTTPClient.validateResponse(url: finalURL, status: status, expectedBytes: expectedBytes)
        guard data.count <= InstallerSourcePolicy.maximumBytes else { throw InstallerAcquisitionError.tooLarge }
        guard expectedBytes < 0 || expectedBytes == data.count else { throw InstallerAcquisitionError.incompleteTransfer }
        try InstallerExecutable.validate(data)
    }
}

enum InstallerHTTPClient {
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    static func validateResponse(url: URL, status: Int, expectedBytes: Int64) throws {
        guard InstallerSourcePolicy.allows(url) else { throw InstallerAcquisitionError.invalidSource }
        guard status == 200 else { throw InstallerAcquisitionError.invalidResponse }
        guard expectedBytes <= InstallerSourcePolicy.maximumBytes else { throw InstallerAcquisitionError.tooLarge }
    }

    static func fetch(configuration: URLSessionConfiguration = .ephemeral,
                      byteLimit: Int = InstallerSourcePolicy.maximumBytes) async throws -> InstallerPayload {
        guard (1...InstallerSourcePolicy.maximumBytes).contains(byteLimit) else { throw InstallerAcquisitionError.tooLarge }
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        let (stream, response) = try await session.bytes(for: request(InstallerSourcePolicy.source), delegate: InstallerRedirectPolicy())
        guard let response = response as? HTTPURLResponse, let url = response.url,
              response.value(forHTTPHeaderField: "Content-Range") == nil,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true
        else { throw InstallerAcquisitionError.invalidResponse }
        try validateResponse(url: url, status: response.statusCode, expectedBytes: response.expectedContentLength)
        guard response.expectedContentLength <= byteLimit else { throw InstallerAcquisitionError.tooLarge }
        var data = Data()
        for try await byte in stream {
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            guard data.count < byteLimit else { throw InstallerAcquisitionError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return InstallerPayload(data: data, finalURL: url, status: response.statusCode, expectedBytes: response.expectedContentLength)
    }
}

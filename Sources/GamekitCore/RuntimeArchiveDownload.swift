import Foundation

/// The pinned GitHub release redirects to a short-lived download URL. Do not
/// forward cookies, credentials or arbitrary headers to that redirected host.
private final class RuntimeArchiveRedirects: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    private let source: URL
    private let maximumBytes: Int

    init(source: URL, maximumBytes: Int) { self.source = source; self.maximumBytes = maximumBytes }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        guard count <= 5, let url = request.url, Self.allowed(url, from: source) else {
            completionHandler(nil); return
        }
        completionHandler(Self.request(url))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes { downloadTask.cancel() }
    }

    static func allowed(_ url: URL, from source: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && (parts.port == nil || parts.port == 443) &&
            parts.user == nil && parts.password == nil && parts.fragment == nil &&
            ((url == source && parts.query == nil) ||
             (parts.host == "release-assets.githubusercontent.com" && !parts.percentEncodedPath.isEmpty))
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

enum RuntimeArchiveDownload {
    static func fetch(_ artifact: RuntimeSetupRecipe.Artifact) async throws -> URL {
        guard let source = artifact.url else { throw RuntimeSetupError.invalidRecipe }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(for: RuntimeArchiveRedirects.request(source),
                                                           delegate: RuntimeArchiveRedirects(source: source, maximumBytes: artifact.maximumBytes))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, let url = response.url,
              RuntimeArchiveRedirects.allowed(url, from: source), response.statusCode == 200,
              response.value(forHTTPHeaderField: "Content-Range") == nil,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              response.expectedContentLength <= artifact.maximumBytes
        else { throw RuntimeSetupError.invalidDownload }
        try Task.checkCancellation()
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= artifact.maximumBytes else { throw RuntimeSetupError.invalidDownload }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("gamekit-pinned-runtime-" + UUID().uuidString)
        try FileManager.default.moveItem(at: file, to: copy)
        return copy
    }
}

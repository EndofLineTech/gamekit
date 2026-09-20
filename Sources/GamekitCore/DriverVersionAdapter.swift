import Foundation

/// Qualified generic mechanism; target images and version values are JSON data.
enum DriverVersionAdapter {
    static let filename = "dxgi-version-v1.dll"
    static let sha256 = "2658ec1e2c05b8cdf34072147b65b9e970efff8704c6c5f356b17c3346a8e7a4"
    static var url: URL? { Bundle.module.url(forResource: "dxgi-version-v1", withExtension: "dll", subdirectory: "ExecutionAdapters") }
    static func data() throws -> Data {
        guard let url, RuntimeDetector.matches(url, root: url.deletingLastPathComponent(), hash: sha256) else { throw SteamApplicationError.invalidRuntime }
        return try Data(contentsOf: url)
    }
}

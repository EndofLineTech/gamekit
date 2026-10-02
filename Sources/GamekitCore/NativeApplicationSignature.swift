import Foundation

/// A derived local app can be sealed without altering its separately supplied
/// runtime. Its ad-hoc seal is integrity evidence, not Developer ID trust.
enum NativeApplicationSignature {
    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4) else { return false }
        return [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
                Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
                Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca])].contains(magic)
    }

    static func seal(_ app: URL) async throws {
        let result = try await ProcessExecutor().run(.init(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", app.path], timeout: 180, outputLimit: 4096))
        guard result.termination == .exited(0) else { throw SteamApplicationError.invalidBundle }
        try verify(app)
    }

    static func verify(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() }
        catch { throw SteamApplicationError.invalidBundle }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SteamApplicationError.invalidBundle
        }
    }
}

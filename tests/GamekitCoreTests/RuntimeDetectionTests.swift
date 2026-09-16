import CryptoKit
import Foundation
import Testing
@testable import GamekitCore

private struct DetectionFixture {
    let parent: URL
    let layout: RuntimeLayout
    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("Gamekit")
        let bytes = Data("fixture payload".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let profile = RuntimeProfile(identity: RuntimeProfile.sikarugir.identity, bundlePath: "Runtimes/runtime with spaces.app",
                                     wineVersionOutput: "wine-10.0 (Sikarugir)",
                                     hashes: RuntimeProfile.sikarugir.hashes.mapValues { _ in digest })
        layout = RuntimeLayout(dataRoot: root, profile: profile)
        for relative in profile.hashes.keys { try Self.put(bytes, at: layout.bundle.appendingPathComponent(relative)) }
        for dependency in ["libinotify.0.dylib", "libfreetype.6.dylib", "libgnutls.30.dylib", "libSDL2-2.0.0.dylib", "GStreamer.framework/Libraries/libgstreamer-1.0.0.dylib"] {
            try Self.put(bytes, at: layout.frameworks.appendingPathComponent(dependency))
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "4.0b2", "SourceVersion": "33024000000000"], format: .xml, options: 0)
        try Self.put(plist, at: layout.graphics.appendingPathComponent("Resources/version.plist"))
        for executable in [layout.wine, layout.wineserver] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
    }
    static func put(_ data: Data, at path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private func commandResult(_ text: String, code: Int32 = 0) -> CommandResult {
    CommandResult(termination: .exited(code), stdout: Data(text.utf8), stderr: Data(), stdoutBytes: text.utf8.count,
                  stderrBytes: 0, stdoutTruncated: false, stderrTruncated: false, outputIncomplete: false, duration: 0)
}

private let goodHost = RuntimeHostFacts(macOSMajorVersion: 27, architecture: .arm64, availableBytes: 20 * 1024 * 1024 * 1024)
private func detector(wineVersion: String = "wine-10.0 (Sikarugir)", rosetta: Bool = true) -> RuntimeDetector {
    RuntimeDetector { request in
        if request.executable.lastPathComponent == "arch" { return commandResult(rosetta ? "x86_64\n" : "", code: rosetta ? 0 : 1) }
        if request.arguments == ["--version"] { return commandResult(wineVersion + "\n") }
        return commandResult("")
    }
}

@Suite("Runtime prerequisite detection")
struct RuntimeDetectionTests {
    @Test("Pinned fixture succeeds only when executable probes and files agree")
    func validAndWrongVersion() async throws {
        let fixture = try DetectionFixture(); defer { fixture.remove() }
        let report = try await detector().detect(fixture.layout, selection: fixture.layout.profile.identity, host: goodHost)
        #expect(report.prerequisites == .ready)
        let wrong = try await detector(wineVersion: "wine-11.17").detect(fixture.layout, selection: fixture.layout.profile.identity, host: goodHost)
        #expect(wrong.checks.contains { $0.prerequisite == .runtime && $0.status == .failed })
    }

    @Test("Changed payload and missing dependency are detected")
    func changedFiles() async throws {
        let fixture = try DetectionFixture(); defer { fixture.remove() }
        try Data("modified".utf8).write(to: fixture.layout.graphics.appendingPathComponent("Versions/A/D3DMetal"))
        try FileManager.default.removeItem(at: fixture.layout.frameworks.appendingPathComponent("libinotify.0.dylib"))
        let report = try await detector().detect(fixture.layout, selection: fixture.layout.profile.identity, host: goodHost)
        #expect(report.checks.contains { $0.prerequisite == .graphicsPayload && $0.status == .failed })
        #expect(report.checks.contains { $0.prerequisite == .runtime && $0.status == .failed })
    }

    @Test("A symlinked runtime outside the managed root is not executed")
    func escapingRuntime() async throws {
        let fixture = try DetectionFixture(); defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("outside.app")
        try FileManager.default.moveItem(at: fixture.layout.bundle, to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.layout.bundle, withDestinationURL: outside)
        let report = try await detector().detect(fixture.layout, selection: fixture.layout.profile.identity, host: goodHost)
        #expect(report.checks.contains { $0.prerequisite == .runtime && $0.status == .failed })
    }

    @Test("Host, translation and disk readiness are independent")
    func hostFailures() async throws {
        let fixture = try DetectionFixture(); defer { fixture.remove() }
        let unsupported = try await detector().detect(fixture.layout, selection: fixture.layout.profile.identity,
                                                       host: .init(macOSMajorVersion: 28, architecture: .arm64, availableBytes: 1))
        #expect(unsupported.checks.contains { $0.prerequisite == .supportedHost && $0.status == .failed })
        #expect(unsupported.checks.contains { $0.prerequisite == .diskSpace && $0.status == .failed })
        #expect(unsupported.checks.contains { $0.prerequisite == .runtime && $0.status == .unknown })
        let noTranslation = try await detector(rosetta: false).detect(fixture.layout, selection: fixture.layout.profile.identity, host: goodHost)
        #expect(noTranslation.checks.contains { $0.prerequisite == .rosetta && $0.status == .failed })
        let unknownDisk = try await detector().detect(fixture.layout, selection: fixture.layout.profile.identity,
                                                     host: .init(macOSMajorVersion: 27, architecture: .arm64, availableBytes: nil))
        #expect(unknownDisk.prerequisites == .notChecked)
    }

    @Test("Absent selection cannot pass readiness")
    func missingSelection() async throws {
        let fixture = try DetectionFixture(); defer { fixture.remove() }
        #expect(try await detector().detect(fixture.layout, selection: nil, host: goodHost).prerequisites != .ready)
    }
}

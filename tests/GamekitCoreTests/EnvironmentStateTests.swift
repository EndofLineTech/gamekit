import Foundation
import Testing
@testable import GamekitCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

func sampleEnvironment(_ name: String = "steam-test") throws -> EnvironmentRecord {
    try EnvironmentRecord(
        id: EnvironmentID(name), name: "Windows Steam",
        runtime: RuntimeIdentity(provider: "Sikarugir", distribution: "10.0_6", wine: "10.0", graphics: "4.0b2"),
        installer: InstallerProvenance(
            source: URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!,
            sha256: String(repeating: "a", count: 64), downloadedAt: epoch
        ),
        createdAt: epoch
    )
}

@Suite("Environment metadata and reconciliation")
struct EnvironmentStateTests {
    @Test("Decoded metadata cannot bypass identifier validation", arguments: ["../Beads", "/tmp/out", "a/b", "..", "UPPER", "a\\b", "a%2fb", "a\r", "a\n", "a\u{2028}", ""])
    func rejectsEscapingIDs(value: String) throws {
        #expect(throws: (any Error).self) { try EnvironmentID(value) }
        let encoded = try JSONEncoder().encode(value)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EnvironmentID.self, from: encoded) }
    }

    @Test("Relative paths reject traversal and foreign path syntax", arguments: ["../other/Steam.exe", "/Steam.exe", "drive_c/../Steam.exe", "drive_c//Steam.exe", "C:\\Steam.exe", "file:///tmp/Steam.exe"])
    func rejectsInvalidRelativePaths(value: String) {
        #expect(throws: (any Error).self) { try RelativePath(value) }
    }

    @Test("Schema and provenance validation survives decoding")
    func validatesDocument() throws {
        let record = try sampleEnvironment()
        let data = try EnvironmentDocument.encode(record)
        #expect(try EnvironmentDocument.decode(data) == record)
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        document["schemaVersion"] = 99
        #expect(throws: MetadataError.unsupportedSchema(99)) {
            try EnvironmentDocument.decode(JSONSerialization.data(withJSONObject: document))
        }
        var invalid = record
        invalid.installer = InstallerProvenance(source: URL(string: "http://example.com/Steam.exe")!,
                                                sha256: "bad", downloadedAt: epoch)
        #expect(throws: (any Error).self) { try EnvironmentDocument.encode(invalid) }
    }

    @Test("Installer URLs must identify a credential-free HTTPS host", arguments: [
        "http://example.com/Steam.exe", "https:///Steam.exe", "https://user:secret@example.com/Steam.exe"
    ])
    func invalidInstallerURL(source: String) throws {
        var record = try sampleEnvironment()
        record.installer = InstallerProvenance(source: try #require(URL(string: source)),
                                                sha256: String(repeating: "a", count: 64), downloadedAt: epoch)
        #expect(throws: MetadataError.invalidInstaller) { try EnvironmentDocument.encode(record) }
    }

    @Test("Digests must be complete lowercase SHA-256 hex", arguments: ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "z", count: 64)])
    func invalidDigest(digest: String) throws {
        var record = try sampleEnvironment()
        record.installer = InstallerProvenance(source: URL(string: "https://example.com/Steam.exe")!,
                                                sha256: digest, downloadedAt: epoch)
        #expect(throws: MetadataError.invalidInstaller) { try EnvironmentDocument.encode(record) }
    }

    @Test("Unknown process observations never turn saved installation into live readiness")
    func unknownIsNotStopped() throws {
        var record = try sampleEnvironment()
        record.installation = .installed
        let result = EnvironmentReconciler.reconcile(record, files: .init(prefixExists: true, executableExists: true),
                                                    process: .notChecked, prerequisites: .ready, at: epoch)
        #expect(result.state == .unverified)
        #expect(result.record == record)
    }

    @Test("A fresh environment requires positively checked prerequisites")
    func freshState() throws {
        let record = try sampleEnvironment()
        let files = EnvironmentFiles(prefixExists: false, executableExists: false)
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .idle,
                                                prerequisites: .notChecked, at: epoch).state == .unverified)
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .idle,
                                                prerequisites: .missing([.rosetta]), at: epoch).state == .missingPrerequisites([.rosetta]))
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .idle,
                                                prerequisites: .ready, at: epoch).state == .readyToInstall)
    }

    @Test("Readiness requires a recorded runtime selection")
    func unselectedRuntime() throws {
        let record = try EnvironmentRecord(id: EnvironmentID("new-steam"), name: "Steam", createdAt: epoch)
        #expect(EnvironmentReconciler.reconcile(record, files: .init(prefixExists: false, executableExists: false),
                                                process: .idle, prerequisites: .ready, at: epoch).state
            == .missingPrerequisites([.runtime]))
    }

    @Test("A stopped partial operation becomes interrupted even if Steam.exe exists")
    func interruptedOperation() throws {
        var record = try sampleEnvironment()
        record.installation = .installing(.bootstrappingSteam)
        let result = EnvironmentReconciler.reconcile(record, files: .init(prefixExists: true, executableExists: true),
                                                    process: .idle, prerequisites: .ready, at: epoch.addingTimeInterval(10))
        #expect(result.state == .interrupted(.bootstrappingSteam))
        #expect(result.record.installation == .interrupted(.bootstrappingSteam))
        #expect(result.record.updatedAt == epoch.addingTimeInterval(10))
    }

    @Test("Live installer and Steam observations take precedence over stale progress")
    func liveProcesses() throws {
        let record = try sampleEnvironment()
        let files = EnvironmentFiles(prefixExists: true, executableExists: true)
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .installerRunning(.runningInstaller),
                                                prerequisites: .ready, at: epoch).state == .installing(.runningInstaller))
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .steamRunning,
                                                prerequisites: .ready, at: epoch).state == .running)
        #expect(EnvironmentReconciler.reconcile(record, files: .init(prefixExists: false, executableExists: false),
                                                process: .steamRunning, prerequisites: .ready, at: epoch).state
            == .failed(.inconsistentObservation))
    }

    @Test("Installed history survives dependency loss and missing files never become ready-to-install")
    func preservesInstalledHistory() throws {
        var record = try sampleEnvironment()
        record.installation = .installed
        let files = EnvironmentFiles(prefixExists: true, executableExists: true)
        let unavailable = EnvironmentReconciler.reconcile(record, files: files, process: .idle,
                                                        prerequisites: .missing([.runtime]), at: epoch)
        #expect(unavailable.state == .missingPrerequisites([.runtime]))
        #expect(unavailable.record.installation == .installed)
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .idle,
                                                prerequisites: .ready, at: epoch).state == .installed)
        #expect(EnvironmentReconciler.reconcile(record, files: .init(prefixExists: false, executableExists: false),
                                                process: .idle, prerequisites: .ready, at: epoch).state == .failed(.prefixMissing))
        #expect(EnvironmentReconciler.reconcile(record, files: .init(prefixExists: true, executableExists: false),
                                                process: .idle, prerequisites: .ready, at: epoch).state == .failed(.executableMissing))
    }

    @Test("Unexpected prefix contents and recorded failure require explicit recovery")
    func noAutomaticAdoptionOrRepair() throws {
        var record = try sampleEnvironment()
        let files = EnvironmentFiles(prefixExists: true, executableExists: true)
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .idle,
                                                prerequisites: .ready, at: epoch).state == .failed(.unexpectedPrefix))
        record.installation = .failed(.bootstrapFailed)
        #expect(EnvironmentReconciler.reconcile(record, files: files, process: .idle,
                                                prerequisites: .ready, at: epoch).state == .failed(.bootstrapFailed))
    }
}

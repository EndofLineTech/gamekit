import Foundation

public enum DiagnosticStage: String, Codable, CaseIterable, Sendable {
    case runtimeProbe, download, installation, bootstrap, rendering, launch, shutdown
    public var failureCategory: DiagnosticCategory {
        switch self {
        case .download: .download
        case .installation: .installation
        case .bootstrap: .bootstrap
        case .rendering: .rendering
        case .runtimeProbe, .launch, .shutdown: .runtime
        }
    }
}
public enum DiagnosticCategory: String, Codable, Sendable {
    case none, incomplete, download, installation, bootstrap, rendering, runtime, timedOut, cancelled
}
public enum DiagnosticComponent: String, Codable, Sendable { case application, rosetta, wine, graphics, installer, steam }
public enum DiagnosticOutcome: Codable, Equatable, Sendable {
    case exited(Int32), signalled(Int32), timedOut, cancelled, launchFailed(Int32), invalidRequest, observationFailed(Int32), executionFailed
    public init(_ termination: CommandTermination) {
        switch termination {
        case .exited(let code): self = .exited(code)
        case .signalled(let signal): self = .signalled(signal)
        case .timedOut: self = .timedOut
        case .cancelled: self = .cancelled
        case .observationFailed(let code): self = .observationFailed(code)
        }
    }
}

public struct DiagnosticVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: Int?
    public init(major: Int, minor: Int, patch: Int, build: Int? = nil) {
        self.major = major; self.minor = minor; self.patch = patch; self.build = build
    }
    static var host: DiagnosticVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return .init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }
    static var app: DiagnosticVersion? {
        guard let text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        let parts = text.split(separator: ".")
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
        return .init(major: major, minor: minor, patch: patch, build: build)
    }
    var valid: Bool { [major, minor, patch].allSatisfy { (0...999_999).contains($0) } && (build.map { (0...999_999_999).contains($0) } ?? true) }
}

public struct DiagnosticContext: Codable, Sendable {
    public let component: DiagnosticComponent
    public let environmentID: EnvironmentID?
    public let runtimeSelection: RuntimeIdentity?
    public let appVersion: DiagnosticVersion?
    public let operatingSystem: DiagnosticVersion
    public init(component: DiagnosticComponent = .application, environmentID: EnvironmentID? = nil,
                runtimeSelection: RuntimeIdentity? = nil, appVersion: DiagnosticVersion? = nil,
                operatingSystem: DiagnosticVersion? = nil) {
        self.component = component; self.environmentID = environmentID; self.runtimeSelection = runtimeSelection
        self.appVersion = appVersion ?? .app; self.operatingSystem = operatingSystem ?? .host
    }
    func validate() throws {
        guard operatingSystem.valid, appVersion?.valid ?? true else { throw DiagnosticStoreError.invalidRecord }
        if let identity = runtimeSelection {
            guard [identity.provider, identity.distribution, identity.wine, identity.graphics].allSatisfy({ $0.count <= 128 })
            else { throw DiagnosticStoreError.invalidRecord }
        }
    }
}

public struct DiagnosticsPolicy: Sendable {
    public let maximumOperations: Int
    public let maximumAge: TimeInterval
    public let bytesPerStream: Int
    public let maximumStageEvents: Int
    public let checkpointInterval: TimeInterval
    public init(maximumOperations: Int = 20, maximumAge: TimeInterval = 7 * 86400,
                bytesPerStream: Int = 262_144, maximumStageEvents: Int = 64, checkpointInterval: TimeInterval = 1) {
        self.maximumOperations = maximumOperations; self.maximumAge = maximumAge
        self.bytesPerStream = bytesPerStream; self.maximumStageEvents = maximumStageEvents
        self.checkpointInterval = checkpointInterval
    }
    func validate() throws {
        guard (1...100).contains(maximumOperations), maximumAge.isFinite, maximumAge > 0,
              (0...262_144).contains(bytesPerStream), (2...64).contains(maximumStageEvents),
              checkpointInterval.isFinite, (0.05...60).contains(checkpointInterval)
        else { throw DiagnosticStoreError.invalidPolicy }
    }
}

public enum DiagnosticSignature: String, Codable, Sendable {
    case missingUnixDispatcher, unhandledException, dllInitialization, permissionDenied, networkFailure, explicitFailure
    var priority: Int {
        switch self {
        case .missingUnixDispatcher: 0
        case .unhandledException: 1
        case .dllInitialization: 2
        case .permissionDenied: 3
        case .networkFailure: 4
        case .explicitFailure: 5
        }
    }
}
public struct DiagnosticSignatureObservation: Codable, Sendable {
    public let signature: DiagnosticSignature
    public let stage: DiagnosticStage
}
public struct DiagnosticStageEvent: Codable, Sendable {
    public let stage: DiagnosticStage
    public let elapsedSeconds: TimeInterval
}
public struct DiagnosticLocalOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
}

/// This is deliberately a different Encodable type from the private stored record.
/// Never add raw output, environment IDs, paths, arguments or free-form errors here.
public struct DiagnosticSummary: Encodable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let startedAt: Date
    public let updatedAt: Date
    public let elapsedSeconds: TimeInterval
    public let stage: DiagnosticStage
    public let component: DiagnosticComponent
    public let appVersion: DiagnosticVersion?
    public let operatingSystem: DiagnosticVersion
    public let recognizedRuntimeSelection: RuntimeIdentity?
    public let outcome: DiagnosticOutcome?
    public let commandTermination: DiagnosticOutcome?
    public let commandDurationSeconds: TimeInterval?
    public let category: DiagnosticCategory
    public let signature: DiagnosticSignatureObservation?
    public let events: [DiagnosticStageEvent]
    public let eventsDropped: Int
    public let stdoutBytes: Int
    public let stderrBytes: Int
    public let outputTruncated: Bool
    public let outputIncomplete: Bool
    public let checkpointFailed: Bool
    public let recommendation: String
}

struct DiagnosticRecord: Codable, Sendable {
    var schemaVersion = 1
    let id: UUID
    let context: DiagnosticContext
    let startedAt: Date
    var updatedAt: Date
    var elapsedSeconds: TimeInterval
    var stage: DiagnosticStage
    var events: [DiagnosticStageEvent]
    var eventsDropped: Int
    var stdout: Data
    var stderr: Data
    var stdoutBytes: Int
    var stderrBytes: Int
    var signature: DiagnosticSignatureObservation?
    var outcome: DiagnosticOutcome?
    var commandTermination: DiagnosticOutcome?
    var commandDurationSeconds: TimeInterval?
    var outputIncomplete: Bool
    var checkpointFailed: Bool

    func validate() throws {
        try context.validate()
        guard schemaVersion == 1, startedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              elapsedSeconds.isFinite, elapsedSeconds >= 0, stdout.count <= 262_144, stderr.count <= 262_144,
              commandDurationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              stdoutBytes >= stdout.count, stderrBytes >= stderr.count, eventsDropped >= 0, events.count <= 64,
              events.allSatisfy({ $0.elapsedSeconds.isFinite && $0.elapsedSeconds >= 0 })
        else { throw DiagnosticStoreError.invalidRecord }
    }

    var summary: DiagnosticSummary {
        let category: DiagnosticCategory
        switch outcome {
        case nil: category = .incomplete
        case .cancelled: category = .cancelled
        case .timedOut: category = .timedOut
        case .exited(0) where signature == nil: category = .none
        case .exited(0): category = signature?.stage.failureCategory ?? stage.failureCategory
        default: category = stage.failureCategory
        }
        let advice: String
        if category == .incomplete { advice = "Observe live process state before deciding whether this unfinished operation was interrupted." }
        else if category == .timedOut { advice = "Check progress and owned processes before retrying the timed-out stage." }
        else if category == .cancelled { advice = "Check recorded installation progress before resuming the cancelled operation." }
        else if let signature {
            switch signature.signature {
            case .missingUnixDispatcher: advice = "Verify the pinned Wine/GPTK runtime pairing; a newer generic Wine build is not sufficient."
            case .dllInitialization: advice = "Check runtime integrity and inspect the local loader output."
            case .unhandledException: advice = "Inspect the local exception trace and compare the validated runtime recipe."
            case .permissionDenied: advice = "Check access to managed files and preserve existing data before recovery."
            case .networkFailure: advice = "Check the download or network result before retrying this stage."
            case .explicitFailure: advice = "Inspect the local output for the failed stage."
            }
        } else if category == .none { advice = "Command completed; stage-specific acceptance may still be required." }
        else { advice = "Inspect the local output and the exit result for this stage before retrying." }
        // Do not export arbitrary version strings supplied in a local context.
        let knownRuntime = context.runtimeSelection == RuntimeProfile.sikarugir.identity ? RuntimeProfile.sikarugir.identity : nil
        return DiagnosticSummary(schemaVersion: 1, id: id, startedAt: startedAt, updatedAt: updatedAt,
                                 elapsedSeconds: elapsedSeconds, stage: stage, component: context.component,
                                 appVersion: context.appVersion, operatingSystem: context.operatingSystem,
                                 recognizedRuntimeSelection: knownRuntime, outcome: outcome,
                                 commandTermination: commandTermination, commandDurationSeconds: commandDurationSeconds, category: category,
                                 signature: signature, events: events, eventsDropped: eventsDropped,
                                 stdoutBytes: stdoutBytes, stderrBytes: stderrBytes,
                                 outputTruncated: stdoutBytes > stdout.count || stderrBytes > stderr.count,
                                 outputIncomplete: outputIncomplete, checkpointFailed: checkpointFailed, recommendation: advice)
    }
}

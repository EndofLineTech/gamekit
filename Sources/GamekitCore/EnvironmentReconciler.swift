import Foundation

public enum Prerequisite: String, Equatable, Sendable {
    case supportedHost, rosetta, runtime, graphicsPayload, diskSpace
}

public enum PrerequisiteObservation: Equatable, Sendable {
    case notChecked, ready
    case missing([Prerequisite])
}

/// The caller must scope these facts to this environment. A PID alone is insufficient.
public enum ProcessObservation: Equatable, Sendable {
    case notChecked, idle, steamRunning
    case installerRunning(InstallationStage)
}

public struct EnvironmentFiles: Equatable, Sendable {
    public let prefixExists: Bool
    public let executableExists: Bool

    public init(prefixExists: Bool, executableExists: Bool) {
        self.prefixExists = prefixExists
        self.executableExists = executableExists
    }
}

public enum EnvironmentState: Equatable, Sendable {
    case unverified
    case missingPrerequisites([Prerequisite])
    case readyToInstall
    case installing(InstallationStage)
    case installed
    case running
    case failed(EnvironmentFailure)
    case interrupted(InstallationStage)
}

public struct ReconciledEnvironment: Equatable, Sendable {
    public let record: EnvironmentRecord
    public let files: EnvironmentFiles
    public let state: EnvironmentState
}

public enum EnvironmentReconciler {
    public static func reconcile(_ original: EnvironmentRecord, files: EnvironmentFiles,
                                 process: ProcessObservation, prerequisites: PrerequisiteObservation,
                                 at now: Date) -> ReconciledEnvironment {
        var record = original
        func result(_ state: EnvironmentState) -> ReconciledEnvironment {
            ReconciledEnvironment(record: record, files: files, state: state)
        }
        func gated(_ eligible: EnvironmentState) -> EnvironmentState {
            switch prerequisites {
            case .notChecked: .unverified
            case .ready: record.runtime == nil ? .missingPrerequisites([.runtime]) : eligible
            case .missing(let reasons): reasons.isEmpty ? .unverified : .missingPrerequisites(reasons)
            }
        }
        if files.executableExists && !files.prefixExists { return result(.failed(.inconsistentObservation)) }
        switch process {
        case .notChecked:
            return result(.unverified)
        case .installerRunning(let stage):
            if record.installation != .installing(stage) {
                record.installation = .installing(stage)
                record.updatedAt = max(record.updatedAt, now)
            }
            return result(.installing(stage))
        case .steamRunning:
            return result(files.prefixExists && files.executableExists ? .running : .failed(.inconsistentObservation))
        case .idle:
            break
        }
        switch record.installation {
        case .installing(let stage):
            record.installation = .interrupted(stage)
            record.updatedAt = max(record.updatedAt, now)
            return result(.interrupted(stage))
        case .interrupted(let stage):
            return result(.interrupted(stage))
        case .failed(let failure):
            return result(.failed(failure))
        case .installed:
            guard files.prefixExists else { return result(.failed(.prefixMissing)) }
            guard files.executableExists else { return result(.failed(.executableMissing)) }
            return result(gated(.installed))
        case .notStarted:
            guard !files.prefixExists else { return result(.failed(.unexpectedPrefix)) }
            return result(gated(.readyToInstall))
        }
    }
}

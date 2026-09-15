/// Architecture supplied by the host probe; this type performs no system calls.
public enum HostArchitecture: String, Sendable {
    case arm64
    case x86_64
    case unknown
}

public enum HostRequirementFailure: Equatable, Sendable {
    case operatingSystem(actualMajor: Int)
    case architecture(HostArchitecture)
}

/// Eligibility for the personal prototype, not proof of runtime readiness.
/// Rosetta, Wine, payload and prefix validation belong to the runtime detector.
public enum PrototypeHostPolicy {
    public static let macOSMajorVersion = 27

    public static func failures(
        macOSMajorVersion actualMajor: Int,
        architecture: HostArchitecture
    ) -> [HostRequirementFailure] {
        var failures: [HostRequirementFailure] = []
        if actualMajor != macOSMajorVersion {
            failures.append(.operatingSystem(actualMajor: actualMajor))
        }
        if architecture != .arm64 {
            failures.append(.architecture(architecture))
        }
        return failures
    }
}

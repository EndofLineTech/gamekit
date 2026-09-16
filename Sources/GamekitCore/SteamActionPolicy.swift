import Foundation

/// UI availability from observed facts. Backend validation and leases are still
/// required when executing an action; an enabled button is not authorization.
public struct SteamActionPolicy: Sendable {
    public let install: Bool
    public let retry: Bool
    public let verify: Bool
    public let reset: Bool
    public let stopInterrupted: Bool
    public let launch: Bool
    public let show: Bool
    public let stop: Bool
    public init(ready: Bool, installation: InstallationProgress?, files: EnvironmentFiles,
                snapshot: RuntimeProcessSnapshot?, lifecycle: SteamLifecycleState = .notInstalled,
                hasReceipt: Bool = false, busy: Bool = false, metadataValid: Bool = true) {
        let available = !busy && metadataValid
        let idle = snapshot?.complete == true && snapshot?.processes.isEmpty == true
        let installed = installation == .installed && files.prefixExists && files.executableExists
        install = available && ready && idle && !files.prefixExists && (installation == nil || installation == .notStarted)
        retry = available && ready && idle && installation != nil && !installed
        verify = available && ready && idle && files.executableExists && installation.map {
            [.failed(.bootstrapFailed), .interrupted(.bootstrappingSteam), .interrupted(.validatingInstallation)].contains($0)
        } == true
        reset = available && idle && installation != nil
        let tags = snapshot?.processes.compactMap(\.sessionID) ?? []
        let tagged = !tags.isEmpty && tags.count == snapshot?.processes.count && Set(tags).count == 1 && tags.allSatisfy { UUID(uuidString: $0) != nil }
        stopInterrupted = available && ready && installation != nil && installation != .installed && snapshot?.complete == true && tagged
        launch = available && ready && installed && idle && lifecycle == .stopped
        show = available && ready && installed && snapshot?.complete == true && lifecycle == .running
        stop = available && installed && ([.running, .starting].contains(lifecycle) || (hasReceipt && idle))
    }
}

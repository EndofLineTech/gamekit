import AppKit
import GamekitCore
import SwiftUI

/// One operation owner for the window. Backend leases remain authoritative across
/// processes; this gate prevents conflicting clicks before an async call starts.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var layout = RuntimeLayout(dataRoot: AppStorageLocations.metadata)
    @Published private(set) var report: RuntimeReport?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var activity: String?
    @Published private(set) var selectionLocked = false
    @Published var problem: String?
    @Published var selectionRevision = UUID()
    @Published private(set) var record: EnvironmentRecord?
    @Published private(set) var files = EnvironmentFiles(prefixExists: false, executableExists: false)
    @Published private(set) var snapshot: RuntimeProcessSnapshot?
    @Published private(set) var lifecycleState: SteamLifecycleState = .notInstalled
    @Published private(set) var metadataValid = false
    private var owner: UUID?
    private var fixtureReads = 0
    private var refreshCount = 0
    var isReady: Bool { report?.prerequisites == .ready }
    var isBusy: Bool { owner != nil }
    var canExecute: Bool { isReady && !isBusy }
    var actions: SteamActionPolicy {
        .init(ready: isReady, installation: record?.installation, files: files, snapshot: snapshot,
              lifecycle: lifecycleState, hasReceipt: selectionLocked, busy: isBusy, metadataValid: metadataValid)
    }

    func begin(_ description: String) -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID(); owner = token; activity = description
        return token
    }
    func end(_ token: UUID) {
        if owner == token { owner = nil; activity = nil }
    }
    func update(_ token: UUID, message: String) { if owner == token { activity = message } }

    func refresh(diagnostics: AppDiagnosticsModel) {
        guard let token = begin("Checking prerequisites") else { return }
        refreshCount += 1
        report = nil; problem = nil
        Task { [self] in
            defer { end(token) }
            do {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--metadata-root"), ProcessInfo.processInfo.arguments.contains("ready-with-delay"), refreshCount > 1 {
                    try await Task.sleep(for: .seconds(2))
                }
                #endif
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                let settings = RuntimeSettingsStore(store: store)
                let selected = try await settings.layout()
                if layout.bundle != selected.bundle || layout.profile.revision != selected.profile.revision
                    || layout.graphicsBackend != selected.graphicsBackend {
                    layout = selected; selectionRevision = UUID()
                }
                selectionLocked = try await settings.isSelectionLocked()
                let detector = RuntimeDetector { [diagnostics] request in try await diagnostics.execute(request, layout: selected) }
                let actual = try await detector.detect(selected, selection: selected.profile.identity)
                let validated = fixtureReport() ?? actual
                await refreshFacts(during: token)
                report = validated
                checkedAt = Date()
                diagnostics.environmentRefreshID = UUID()
            } catch { problem = AppFailure.message(error); report = nil }
        }
    }

    func refreshFacts(lifecycle: SteamLifecycleState? = nil, during token: UUID? = nil) async {
        guard owner == token else { return }
        do {
            let store = try EnvironmentStore(root: AppStorageLocations.metadata)
            let records = try await store.loadAll()
            let saved = records.first { $0.id == SteamInstallationRecipe.environmentID }
            let observedFiles: EnvironmentFiles
            let observed: RuntimeProcessSnapshot
            if let saved {
                observedFiles = try await store.installationFiles(saved.id)
                observed = await RuntimeProcessObserver().inspect(record: saved, prefix: store.prefixURL(for: saved.id), layout: layout)
            } else {
                observedFiles = .init(prefixExists: FileManager.default.fileExists(atPath: store.prefixURL(for: SteamInstallationRecipe.environmentID).path), executableExists: false)
                observed = .init(processes: [], complete: true)
            }
            let locked = try await RuntimeSettingsStore(store: store).isSelectionLocked()
            guard owner == token else { return }
            record = saved; files = observedFiles; snapshot = observed; metadataValid = true; selectionLocked = locked
            if let lifecycle { lifecycleState = lifecycle }
        } catch {
            guard owner == token else { return }
            metadataValid = false; snapshot = nil; problem = AppFailure.message(error)
        }
    }

    func chooseRuntime(diagnostics: AppDiagnosticsModel, useDefault: Bool = false, revision: RuntimeRevision? = nil) {
        guard !isBusy, !selectionLocked else { return }
        let revision = revision ?? layout.profile.revision
        let selected: URL?
        if useDefault { selected = nil }
        else {
            let panel = NSOpenPanel()
            panel.title = "Choose the validated Sikarugir runtime app"
            panel.message = "Select the prepared app for \(revision.title), with D3DMetal 4.0b2."
            panel.allowedContentTypes = [.applicationBundle]
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            selected = url
        }
        guard let token = begin("Saving runtime selection") else { return }
        report = nil; problem = nil
        Task { [self] in
            do {
                let settings = RuntimeSettingsStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                try await settings.select(selected, revision: revision)
                layout = try await settings.layout(); selectionRevision = UUID()
                end(token); refresh(diagnostics: diagnostics)
            } catch { problem = AppFailure.message(error); end(token) }
        }
    }

    func chooseGraphicsBackend(_ backend: D3DMetalBackend, diagnostics: AppDiagnosticsModel) {
        guard !isBusy, !selectionLocked, backend != layout.graphicsBackend,
              let token = begin("Saving graphics backend") else { return }
        report = nil; problem = nil
        Task { [self] in
            do {
                let settings = RuntimeSettingsStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                try await settings.selectGraphicsBackend(backend)
                layout = try await settings.layout(); selectionRevision = UUID()
                end(token); refresh(diagnostics: diagnostics)
            } catch { problem = AppFailure.message(error); end(token) }
        }
    }

    private func fixtureReport() -> RuntimeReport? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--metadata-root"), let index = arguments.firstIndex(of: "--ui-test-scenario"), arguments.indices.contains(index + 1) else { return nil }
        let scenario = arguments[index + 1]
        fixtureReads += 1
        let missing: Prerequisite?
        switch scenario {
        case "missing-rosetta": missing = .rosetta
        case "low-disk": missing = .diskSpace
        case "invalid-runtime": missing = .runtime
        case "ready", "ready-with-delay": missing = nil
        case "ready-after-refresh": missing = fixtureReads == 1 ? .rosetta : nil
        default: return nil
        }
        return .init(checks: [Prerequisite.supportedHost, .rosetta, .runtime, .graphicsPayload, .diskSpace].map {
            .init(prerequisite: $0, status: $0 == missing ? .failed : .passed, detail: $0 == missing ? "UI test: prerequisite unavailable" : "UI test: prerequisite passed")
        })
        #else
        return nil
        #endif
    }
}

enum AppFailure {
    static func message(_ error: any Error) -> String {
        switch error {
        case EnvironmentStoreError.busy: "Another operation or Steam session owns this environment. Finish or stop it, then retry."
        case EnvironmentStoreError.unsafePath, EnvironmentStoreError.identityMismatch, SteamLifecycleError.scopeChanged:
            "A managed path changed or redirects elsewhere. Restore the expected location and refresh; Gamekit will not overwrite it."
        case SteamInstallationError.recoveryRequired: "This installation needs recovery. Choose Retry, or review the reset options."
        case SteamRecoveryError.activeProcesses, SteamLifecycleError.foreignActivity:
            "Processes are still using this environment, or ownership does not match. Stop the owning session before recovery."
        case SteamRecoveryError.observationUnavailable, SteamLifecycleError.observationUnavailable:
            "Process ownership could not be checked. Refresh status before trying again."
        case SteamRecoveryError.nonEmptyInstallerDestination:
            "The installer needs an empty destination. Choose a reset option to handle partial client files, then Retry."
        case SteamRecoveryError.pendingReset: "A previous reset has unfinished journal steps. Choose Retry to resume that confirmed operation."
        case SteamInstallationError.prerequisitesNotReady, RuntimeSessionError.prerequisitesNotReady:
            "Prerequisites are not ready. Refresh the checks and follow the reported fix before continuing."
        case SteamApplicationError.invalidBundle: "The generated Windows Steam launcher is invalid. Review local diagnostics before rebuilding its cache."
        case is URLError: "The download could not finish. Check connectivity, then Retry; incomplete downloads are not executed."
        case SteamInstallationError.steamNotObserved: "Steam disappeared during readiness checks. Retry verification after reviewing diagnostics."
        case SteamLifecycleError.notInstalled: "Steam is not fully installed. Complete setup or choose Retry."
        case SteamRecoveryError.unsupportedRecord: "This saved state is not supported by that recovery action. Review its status and use the appropriate setup or Stop control."
        case GameCompatibilityError.unsupportedGame: "No validated game-specific settings are available for this title."
        case GameCompatibilityError.unsupportedPresentation: "Saved fullscreen Space settings are not supported. Review the saved configuration before retrying."
        case GameCompatibilityError.unsupportedRegistry: "Wine's saved registry has an unsupported or ambiguous setting. Gamekit cannot safely edit it. Review the local configuration before retrying."
        case SteamInstallationError.timedOut: "The stage timed out. Inspect progress and use Retry after the managed session has stopped."
        default: "The operation did not complete. Open local diagnostics for details; use Retry to inspect the saved stage."
        }
    }
}

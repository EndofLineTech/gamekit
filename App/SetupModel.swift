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
    @Published private(set) var runtimeSetupStatus: String?
    @Published private(set) var winePrepared = false
    @Published private(set) var rosettaInstruction: String?
    @Published private(set) var rosettaRequestPending = false
    @Published private(set) var selectionLocked = false
    @Published var problem: String?
    @Published var selectionRevision = UUID()
    @Published private(set) var record: EnvironmentRecord?
    @Published private(set) var files = EnvironmentFiles(prefixExists: false, executableExists: false)
    @Published private(set) var snapshot: RuntimeProcessSnapshot?
    @Published private(set) var lifecycleState: SteamLifecycleState = .notInstalled
    @Published private(set) var metadataValid = false
    @Published private(set) var availableGraphicsBackends: Set<GraphicsBackend> = [.automatic, .metal3]
    @Published private(set) var sharedFullscreenSpace = false
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
                    try await Task.sleep(for: .seconds(4))
                }
                #endif
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                let settings = RuntimeSettingsStore(store: store)
                let selected = try await settings.layout()
                sharedFullscreenSpace = try await settings.sharedFullscreenSpace()
                availableGraphicsBackends = await Task.detached {
                    Set(GraphicsBackend.allCases.filter { selected.isGraphicsBackendAvailable($0) })
                }.value
                if layout.bundle != selected.bundle || layout.profile.revision != selected.profile.revision
                    || layout.graphicsBackend != selected.graphicsBackend {
                    layout = selected; selectionRevision = UUID()
                }
                selectionLocked = try await settings.isSelectionLocked()
                let detector = RuntimeDetector { [diagnostics] request in try await diagnostics.execute(request, layout: selected) }
                let actual = try await detector.detect(selected, selection: selected.profile.identity)
                let validated = fixtureReport() ?? actual
                await refreshFacts(during: token)
                winePrepared = (try? await RuntimeSetup(root: AppStorageLocations.metadata).hasPreparedWine()) ?? false
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

    func requestRosetta(diagnostics: AppDiagnosticsModel) {
        guard !isBusy, !rosettaRequestPending else { return }
        guard let probe = Bundle.main.resourceURL?.appendingPathComponent("RosettaProbe.app"),
              FileManager.default.fileExists(atPath: probe.appendingPathComponent("Contents/MacOS/RosettaProbe").path)
        else {
            problem = "Gamekit's Rosetta request helper is unavailable. Reinstall Gamekit and retry."
            return
        }
        problem = nil
        rosettaInstruction = "macOS is requesting Rosetta. Approve Apple's installation prompt if it appears; Gamekit will check when installation finishes."
        guard NSWorkspace.shared.open(probe) else {
            rosettaInstruction = nil
            problem = "macOS did not open the Rosetta request. Retry the request or follow Apple's Rosetta instructions."
            return
        }
        rosettaRequestPending = true
        Task { [self] in
            defer { rosettaRequestPending = false }
            for _ in 0..<200 {
                let result = try? await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/arch"),
                    arguments: ["-x86_64", "/usr/bin/uname", "-m"], timeout: 10, outputLimit: 4096))
                if result?.termination == .exited(0),
                   result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64" {
                    rosettaInstruction = nil
                    refresh(diagnostics: diagnostics)
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
            rosettaInstruction = nil
            problem = "Rosetta is still unavailable. If macOS did not complete its prompt, choose Install Rosetta again."
        }
    }

    func prepareWine(diagnostics: AppDiagnosticsModel) {
        guard !isBusy, !selectionLocked, let token = begin("Installing verified Wine") else { return }
        problem = nil
        runtimeSetupStatus = "Downloading the verified publisher runtime…"
        Task { [self] in
            do {
                _ = try await RuntimeSetup(root: AppStorageLocations.metadata).prepareWine { [weak self] stage in
                    await MainActor.run { self?.runtimeSetupStatus = stage }
                }
                winePrepared = true
                end(token); refresh(diagnostics: diagnostics)
            } catch {
                runtimeSetupStatus = nil
                problem = "Wine setup could not finish. " + AppFailure.message(error)
                end(token)
            }
        }
    }

    func prepareRuntime(diagnostics: AppDiagnosticsModel) {
        guard !isBusy, !selectionLocked, winePrepared else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Apple Game Porting Toolkit evaluation DMG"
        panel.message = "Sign in at Apple Developer and download the pinned 4.0 beta 2 image first. Gamekit verifies its exact bytes; it does not download or redistribute Apple's payload."
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let appleDMG = panel.url,
              let token = begin("Installing Apple graphics into verified Wine") else { return }
        runtimeSetupStatus = "Checking your Apple download…"
        problem = nil
        Task { [self] in
            do {
                let prepared = try await RuntimeSetup(root: AppStorageLocations.metadata).install(appleDMG: appleDMG) { [weak self] stage in
                    await MainActor.run { self?.runtimeSetupStatus = stage }
                }
                let settings = RuntimeSettingsStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                let current = try await settings.layout()
                let fallback = current.dataRoot.appendingPathComponent(current.profile.bundlePath)
                if current.bundle == fallback && current.profile.revision == .original {
                    try await settings.select(nil, revision: .original)
                } else {
                    runtimeSetupStatus = "\(prepared.lastPathComponent) is ready. Your existing runtime selection was kept; choose the new app explicitly if you want to switch."
                }
                layout = try await settings.layout(); selectionRevision = UUID()
                if runtimeSetupStatus?.contains("existing runtime selection") != true { runtimeSetupStatus = "\(prepared.lastPathComponent) is ready. Refreshing checks…" }
                end(token); refresh(diagnostics: diagnostics)
            } catch {
                runtimeSetupStatus = nil
                problem = error as? RuntimeSetupError == .alreadyInstalled
                    ? "A runtime already exists at the pinned destination. Gamekit left it untouched. Choose it or use a separate runtime copy."
                    : "Runtime setup could not finish. Original downloads and existing environments were left untouched. " + AppFailure.message(error)
                end(token)
            }
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

    func chooseSharedFullscreenSpace(_ enabled: Bool, diagnostics: AppDiagnosticsModel) {
        guard !isBusy, !selectionLocked, enabled != sharedFullscreenSpace,
              let token = begin("Saving shared fullscreen Space") else { return }
        problem = nil
        Task { [self] in
            do {
                let settings = RuntimeSettingsStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                try await settings.selectSharedFullscreenSpace(enabled)
                sharedFullscreenSpace = try await settings.sharedFullscreenSpace()
                selectionRevision = UUID()
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
        let missing: Set<Prerequisite>
        switch scenario {
        case "missing-rosetta": missing = [.rosetta]
        case "fresh-missing-rosetta": missing = [.rosetta, .runtime, .graphicsPayload]
        case "low-disk": missing = [.diskSpace]
        case "invalid-runtime": missing = [.runtime, .graphicsPayload]
        case "ready", "ready-with-delay", "queued-game-launch": missing = []
        case "ready-after-refresh": missing = fixtureReads == 1 ? [.rosetta] : []
        default: return nil
        }
        return .init(checks: [Prerequisite.supportedHost, .rosetta, .runtime, .graphicsPayload, .diskSpace].map {
            .init(prerequisite: $0, status: missing.contains($0) ? .failed : .passed,
                  detail: missing.contains($0) ? "UI test: prerequisite unavailable" : "UI test: prerequisite passed")
        })
        #else
        return nil
        #endif
    }
}

enum AppFailure {
    static func message(_ error: any Error) -> String {
        switch error {
        case RuntimeSetupError.invalidRecipe:
            "Gamekit's runtime setup recipe is unavailable or invalid. Update Gamekit; no external runtime was changed."
        case RuntimeSetupError.invalidAppleArtifact:
            "The selected Apple image is missing or differs from the pinned 4.0 beta 2 download. Choose the original outer Apple DMG or its nested evaluation DMG, then retry."
        case RuntimeSetupError.invalidDownload, RuntimeSetupError.invalidArchive:
            "The publisher runtime download was incomplete or did not match its pinned release. Check connectivity and Retry; no runtime was installed."
        case RuntimeSetupError.invalidOverlay:
            "The assembled runtime failed verification. No runtime was installed; use the pinned Apple DMG and Retry."
        case RuntimeSetupError.invalidPreparedWine:
            "The prepared Wine files changed or are incomplete. Gamekit left the existing runtime and environments untouched; inspect the prepared copy before retrying."
        case GraphicsPayloadError.unavailable: "The selected graphics payload is missing, changed, or incompatible with this runtime. Install the pinned backend payload and refresh Setup, or select an Apple backend."
        case EnvironmentStoreError.busy: "Another operation or managed launcher session owns this environment. Finish or stop it, then retry."
        case EnvironmentStoreError.unsafePath, EnvironmentStoreError.identityMismatch, SteamLifecycleError.scopeChanged,
             ManagedLauncherLifecycleError.scopeChanged:
            "A managed path changed or redirects elsewhere. Restore the expected location and refresh; Gamekit will not overwrite it."
        case SteamInstallationError.recoveryRequired: "This installation needs recovery. Choose Retry, or review the reset options."
        case ManagedLauncherInstallationError.recoveryRequired:
            "Ubisoft Connect has an existing or incomplete installation. Use its stage-specific Retry or Verify action; no files were reset."
        case SteamRecoveryError.activeProcesses, SteamLifecycleError.foreignActivity:
            "Processes are still using this environment, or ownership does not match. Stop the owning session before recovery."
        case ManagedLauncherLifecycleError.foreignActivity:
            "Ubisoft Connect's environment has unowned or mixed-session processes. Gamekit will not launch or stop them."
        case SteamRecoveryError.observationUnavailable, SteamLifecycleError.observationUnavailable:
            "Process ownership could not be checked. Refresh status before trying again."
        case ManagedLauncherLifecycleError.observationUnavailable:
            "Ubisoft Connect process ownership could not be verified. Refresh its status before retrying."
        case SteamRecoveryError.nonEmptyInstallerDestination:
            "The installer needs an empty destination. Choose a reset option to handle partial client files, then Retry."
        case SteamRecoveryError.pendingReset: "A previous reset has unfinished journal steps. Choose Retry to resume that confirmed operation."
        case SteamInstallationError.prerequisitesNotReady, RuntimeSessionError.prerequisitesNotReady:
            "Prerequisites are not ready. Refresh the checks and follow the reported fix before continuing."
        case ManagedLauncherInstallationError.prerequisitesNotReady:
            "The selected runtime is not ready for Ubisoft Connect. Refresh prerequisite checks before installing."
        case SteamApplicationError.invalidBundle: "The generated Windows Steam launcher is invalid. Review local diagnostics before rebuilding its cache."
        case is URLError: "The download could not finish. Check connectivity, then Retry; incomplete downloads are not executed."
        case SteamInstallationError.steamNotObserved: "Steam disappeared during readiness checks. Retry verification after reviewing diagnostics."
        case ManagedLauncherInstallationError.clientNotObserved:
            "Ubisoft Connect did not reach its client and web-helper readiness check. Retry Verify when its environment is idle."
        case SteamLifecycleError.notInstalled: "Steam is not fully installed. Complete setup or choose Retry."
        case ManagedLauncherLifecycleError.notInstalled:
            "Ubisoft Connect is not fully installed. Complete its isolated setup first."
        case ManagedLauncherLifecycleError.cleanupFailed:
            "Ubisoft Connect did not stop cleanly. Its ownership receipt was preserved; inspect its processes before retrying."
        case InstallerAcquisitionError.artifactChanged, InstallerAcquisitionError.invalidReceipt:
            "The installer differs from Gamekit's pinned official revision. No changed installer was run; update Gamekit before retrying."
        case SteamRecoveryError.unsupportedRecord: "This saved state is not supported by that recovery action. Review its status and use the appropriate setup or Stop control."
        case GameCompatibilityError.unsupportedGame: "No validated game-specific settings are available for this title."
        case GameCompatibilityError.unsupportedPresentation: "Saved game compatibility settings are not supported. Review the saved configuration before retrying."
        case GameCompatibilityError.driverRuntimeRequired: "This option requires the updated runtime. Stop Steam and select Use updated runtime under Setup and prerequisites."
        case GameCompatibilityError.unsupportedRegistry: "Wine's saved registry has an unsupported or ambiguous setting. Gamekit cannot safely edit it. Review the local configuration before retrying."
        case SteamInstallationError.timedOut: "The stage timed out. Inspect progress and use Retry after the managed session has stopped."
        case ManagedLauncherInstallationError.timedOut:
            "Ubisoft Connect setup timed out. Inspect its saved stage and use Retry or Verify once the environment is idle."
        default: "The operation did not complete. Open local diagnostics for details; use Retry to inspect the saved stage."
        }
    }
}

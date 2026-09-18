import GamekitCore
import SwiftUI

@MainActor
private final class SteamInstallationModel: ObservableObject {
    @Published var status: String?
    @Published var running = false
    private var task: Task<Void, Never>?
    private var coordinator: SteamInstallationCoordinator?
    private var selectedBundle: URL?

    func start(diagnostics: AppDiagnosticsModel, setup: SetupModel, verificationOnly: Bool = false, recoveryRetry: Bool = false) {
        let allowed = recoveryRetry ? setup.actions.retry : verificationOnly ? setup.actions.verify : setup.actions.install
        guard task == nil, allowed, let token = setup.begin(recoveryRetry ? "Recovering installation" : "Installing Windows Steam") else { return }
        running = true
        status = "Checking prerequisites…"
        task = Task { [self] in
            defer {
                running = false; task = nil
                setup.end(token); setup.refresh(diagnostics: diagnostics)
                diagnostics.refreshID = UUID(); diagnostics.environmentRefreshID = UUID()
            }
            do {
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                if coordinator == nil || selectedBundle != setup.layout.bundle {
                    coordinator = SteamInstallationCoordinator(store: store, layout: setup.layout,
                        acquisition: try SteamInstallerAcquisition(root: store.root), diagnostics: diagnostics.store)
                    selectedBundle = setup.layout.bundle
                }
                guard let coordinator else { return }
                let onStage: @Sendable (InstallationStage) async -> Void = { [self] stage in
                    await self.show(stage, setup: setup, token: token)
                }
                if recoveryRetry {
                    let recovery = SteamRecovery(store: store, layout: setup.layout)
                    switch try await recovery.prepareRetry() {
                    case .install: _ = try await coordinator.install(onStage: onStage)
                    case .resumeInstaller: _ = try await coordinator.resumeInstaller(onStage: onStage)
                    case .verifySteam: _ = try await coordinator.verifyExistingInstallation(onStage: onStage)
                    case .alreadyInstalled: break
                    }
                } else if verificationOnly {
                    _ = try await coordinator.verifyExistingInstallation(onStage: onStage)
                } else {
                    _ = try await coordinator.install(onStage: onStage)
                }
                setup.update(token, message: "Setup checks passed. Opening Steam for normal use…")
                do {
                    _ = try await SteamLifecycle(store: store, layout: setup.layout).launch()
                    status = "Steam installed and ready. Sign in or complete Steam Guard in Steam when requested."
                } catch { status = "Setup completed, but Steam could not be reopened. " + AppFailure.message(error) }
            } catch is CancellationError {
                status = "Installation interrupted; existing files were preserved."
            } catch {
                if error as? SteamInstallationError == .steamNotObserved {
                    status = "Steam disappeared during readiness checks. Retry verification after reviewing diagnostics."
                } else if error as? SteamRecoveryError == .nonEmptyInstallerDestination {
                    status = "Steam's installer requires an empty destination. Use a reset option to clear the partial installation, then Retry. Existing files were preserved."
                } else {
                    status = AppFailure.message(error)
                }
            }
            if await coordinator?.diagnosticsUnavailable == true { diagnostics.recordingProblem = true }
        }
    }

    private func show(_ stage: InstallationStage, setup: SetupModel, token: UUID) {
        switch stage {
        case .downloadingInstaller: status = "Downloading and validating Valve's installer…"
        case .creatingPrefix: status = "Creating the managed Wine prefix…"
        case .runningInstaller: status = "Installing Steam silently…"
        case .bootstrappingSteam: status = "Steam is starting and updating. Waiting for its managed processes…"
        case .validatingInstallation:
            status = "Checking Steam's client, browser process and window. Setup will restart Steam for normal use when ready…"
        }
        setup.update(token, message: status ?? "Working…")
    }
    func cancel() { task?.cancel(); status = "Stopping this installation's Wine processes…" }

    func recover(reset: Bool, deleteDownloads: Bool = false, diagnostics: AppDiagnosticsModel, setup: SetupModel) {
        guard task == nil, reset ? setup.actions.reset : setup.actions.stopInterrupted,
              let token = setup.begin(reset ? "Resetting the selected environment" : "Stopping interrupted setup") else { return }
        running = true
        status = reset ? (deleteDownloads ? "Checking ownership and deleting the selected environment…" : "Checking ownership and archiving the environment while preserving downloads…") : "Stopping the interrupted setup's owned Wine processes…"
        task = Task { [self] in
            defer {
                running = false; task = nil
                setup.end(token); setup.refresh(diagnostics: diagnostics)
                diagnostics.refreshID = UUID(); diagnostics.environmentRefreshID = UUID()
            }
            let operation = try? await diagnostics.store?.begin(stage: reset ? .installation : .shutdown, context: .init(component: .application))
            do {
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                let recovery = SteamRecovery(store: store, layout: setup.layout)
                if reset {
                    if deleteDownloads {
                        _ = try await recovery.resetRemovingDownloads(confirmed: true)
                        status = "Current environment and its downloads deleted. Older archives were retained. Retry interrupted install starts clean setup."
                    } else {
                        _ = try await recovery.resetPreservingDownloads(confirmed: true)
                        status = "Reset prepared. Downloads stay in the archive until the installer succeeds. Click Retry interrupted install to begin fresh setup."
                    }
                } else {
                    try await recovery.stopInterruptedSetup(confirmed: true)
                    status = "Interrupted setup stopped. Retry can now inspect and resume the saved stage."
                }
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .exited(0)) }
            } catch {
                status = AppFailure.message(error)
                if deleteDownloads { status = (status ?? "") + " If deletion began, Retry continues the previously confirmed reset." }
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .executionFailed) }
            }
        }
    }
}

struct SteamInstallationView: View {
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @EnvironmentObject private var setup: SetupModel
    @StateObject private var model = SteamInstallationModel()
    @State private var confirmReset = false
    @State private var confirmStop = false
    @State private var confirmDelete = false
    @State private var showRecovery = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Setup and recovery", systemImage: "square.and.arrow.down").font(.headline)
                Text(model.status ?? savedStatus).accessibilityIdentifier("installation-status")
                if model.running { ProgressView().controlSize(.small).accessibilityLabel("Installation operation in progress") }
                if !setup.isReady && !model.running { Text("Installation and retry become available after prerequisite checks pass.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Install Steam") { model.start(diagnostics: diagnostics, setup: setup) }
                        .disabled(model.running || !setup.actions.install).accessibilityIdentifier("install-steam")
                    Button("Retry Steam verification") { model.start(diagnostics: diagnostics, setup: setup, verificationOnly: true) }
                        .disabled(model.running || !setup.actions.verify).accessibilityIdentifier("verify-steam")
                    if model.running { Button("Cancel installation") { model.cancel() } }
                }
                HStack {
                    Button("Retry interrupted install") { model.start(diagnostics: diagnostics, setup: setup, recoveryRetry: true) }
                        .disabled(model.running || !setup.actions.retry).accessibilityIdentifier("retry-installation")
                    Button("Force-stop interrupted setup…") { confirmStop = true }
                        .disabled(model.running || !setup.actions.stopInterrupted)
                }
                Button(showRecovery ? "Hide reset options" : "Show reset options…") { showRecovery.toggle() }
                    .disabled(setup.isBusy).accessibilityIdentifier("show-reset-options")
                if showRecovery {
                    Text("Reset is separate from Retry. Review what each option retains or permanently deletes.").font(.caption)
                    HStack {
                        Button("Reset, preserve downloads…") { confirmReset = true }
                            .disabled(model.running || !setup.actions.reset).accessibilityIdentifier("reset-preserve-downloads")
                        Button("Reset and delete downloads…") { confirmDelete = true }
                            .disabled(model.running || !setup.actions.reset).accessibilityIdentifier("reset-delete-downloads")
                    }
                    Divider()
                    RecoveryArchivesView()
                }
                Text("Recipe 1 · Sikarugir 10.0 revision 6 · D3DMetal 4.0b2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .confirmationDialog("Reset Gamekit's steam environment?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Archive environment and preserve downloads", role: .destructive) { model.recover(reset: true, diagnostics: diagnostics, setup: setup) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old environment, settings and sign-in data stay in a private archive. After the installer succeeds, setup restores steamapps and depotcache before starting Steam. External libraries are left in place. Steam must be stopped first.")
        }
        .confirmationDialog("Delete the current steam environment and downloads?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete environment and downloads", role: .destructive) { model.recover(reset: true, deleteDownloads: true, diagnostics: diagnostics, setup: setup) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes the current managed Windows Steam prefix, including downloaded games, settings, sign-in data and saves inside it. Older recovery archives, external libraries, the runtime and diagnostic logs are retained. Steam must be stopped first.")
        }
        .confirmationDialog("Force-stop interrupted setup?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Force-stop this setup", role: .destructive) { model.recover(reset: false, diagnostics: diagnostics, setup: setup) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closes the selected managed environment's interrupted Wine session. Its installation files and downloaded games are preserved. For an installed Steam session, use Stop Windows Steam instead.")
        }
        .task {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--install-steam") || arguments.contains("--verify-steam") {
                while (setup.report == nil || setup.isBusy) && setup.problem == nil && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                if !Task.isCancelled { model.start(diagnostics: diagnostics, setup: setup, verificationOnly: arguments.contains("--verify-steam")) }
            }
            #endif
        }
    }

    private var savedStatus: String {
        guard setup.metadataValid else { return "Saved state is not verified yet. Refresh checks or inspect local diagnostics." }
        guard let record = setup.record else {
            return setup.files.prefixExists ? "An unregistered prefix exists. Gamekit will not adopt or overwrite it." : "Choose a validated runtime, then install Windows Steam."
        }
        switch record.installation {
        case .installed: return "Steam is installed. Use Launch Windows Steam above."
        case .notStarted: return "Fresh setup is available once prerequisites pass."
        case .installing: return "Saved setup is unfinished. Stop any interrupted setup session before retrying."
        case .interrupted: return "Setup was interrupted. Retry inspects its saved stage and preserves recoverable files."
        case .failed: return "Setup needs attention. Try recovery first; reset options are separate."
        }
    }
}

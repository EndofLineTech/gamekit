import AppKit
import GamekitCore
import SwiftUI

@MainActor
final class UbisoftConnectModel: ObservableObject {
    enum Action { case install, resume, verify, launch, show, stop }
    @Published private(set) var state: ManagedLauncherState = .notInstalled
    @Published private(set) var installation: InstallationProgress = .notStarted
    @Published private(set) var prefixExists = false
    @Published private(set) var executableExists = false
    @Published private(set) var busy = false
    @Published private(set) var stage: InstallationStage?
    @Published private(set) var message: String?

    private func profile() throws -> LauncherProfile { try LauncherProfileStore.bundled("ubisoft") }
    private func store() throws -> EnvironmentStore { try EnvironmentStore(root: AppStorageLocations.metadata) }
    private func lifecycle(setup: SetupModel) throws -> ManagedLauncherLifecycle {
        try ManagedLauncherLifecycle(store: store(), layout: setup.layout, profile: profile())
    }

    func refresh(setup: SetupModel) async {
        guard !busy, !setup.isBusy else { return }
        do {
            let profile = try profile()
            let store = try store()
            if let record = try await store.load(profile.id) {
                installation = record.installation
                let files = try await store.installationFiles(profile.id)
                prefixExists = files.prefixExists; executableExists = files.executableExists
            } else {
                installation = .notStarted; prefixExists = false; executableExists = false
            }
            state = try await lifecycle(setup: setup).status()
        } catch {
            state = .unverified
            installation = .failed(.invalidRuntime)
            prefixExists = true; executableExists = false
            message = AppFailure.message(error)
        }
    }

    func control(_ action: Action, setup: SetupModel, diagnostics: AppDiagnosticsModel) {
        guard !busy, let token = setup.begin(action == .install ? "Installing Ubisoft Connect"
            : action == .resume ? "Retrying Ubisoft Connect installation"
            : action == .verify ? "Verifying Ubisoft Connect"
            : action == .launch ? "Launching Ubisoft Connect"
            : action == .stop ? "Stopping Ubisoft Connect" : "Showing Ubisoft Connect") else { return }
        busy = true; message = nil; stage = nil
        Task { [self] in
            do {
                switch action {
                case .install, .resume, .verify:
                    let coordinator = try ManagedLauncherInstallationCoordinator(
                        store: store(), layout: setup.layout, profile: profile(), diagnostics: diagnostics.store)
                    let onStage: @Sendable (InstallationStage) async -> Void = { stage in
                        await MainActor.run { self.stage = stage }
                    }
                    switch action {
                    case .install: _ = try await coordinator.install(onStage: onStage)
                    case .resume: _ = try await coordinator.resumeInstaller(onStage: onStage)
                    case .verify: _ = try await coordinator.verifyExistingInstallation(onStage: onStage)
                    default: break
                    }
                    message = "Ubisoft Connect is installed in its own managed environment. Launch it and sign in there."
                case .launch:
                    let current = try await lifecycle(setup: setup).launch()
                    message = current == .running ? "Ubisoft Connect is running. Use Show to bring its window forward."
                        : "Ubisoft Connect is starting. Sign in in its own window when it appears."
                case .show:
                    let pid = try await lifecycle(setup: setup).show()
                    guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
                        throw ManagedLauncherLifecycleError.observationUnavailable
                    }
                    _ = application.unhide()
                    NSApplication.shared.yieldActivation(to: application)
                    _ = application.activate(from: .current, options: .activateAllWindows)
                    message = "Ubisoft Connect window requested. Authentication stays in Ubisoft Connect."
                case .stop:
                    let result = try await lifecycle(setup: setup).stop()
                    message = result == .stopped ? "Ubisoft Connect stopped in its own environment." : "Ubisoft Connect was already stopped."
                }
            } catch { message = AppFailure.message(error) }
            busy = false; stage = nil
            setup.end(token)
            await refresh(setup: setup)
        }
    }
}

struct UbisoftConnectView: View {
    @EnvironmentObject private var model: UbisoftConnectModel
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel

    private func stageLabel(_ stage: InstallationStage) -> String {
        switch stage {
        case .downloadingInstaller: "Downloading and validating Ubisoft's installer…"
        case .creatingPrefix: "Creating a separate Ubisoft Wine environment…"
        case .runningInstaller: "Installing Ubisoft Connect…"
        case .bootstrappingLauncher: "Starting Ubisoft Connect for verification…"
        case .validatingInstallation: "Checking owned client and web-helper processes…"
        case .bootstrappingSteam: "Starting the managed client…"
        }
    }

    var body: some View {
        GroupBox("Ubisoft Connect") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Managed separately from Windows Steam. Sign in only in Ubisoft Connect after setup.")
                    .foregroundStyle(.secondary)
                Text("Ubisoft Connect: \(model.state.rawValue)")
                    .accessibilityIdentifier("ubisoft-lifecycle-state")
                if let stage = model.stage { ProgressView(stageLabel(stage)).accessibilityIdentifier("ubisoft-installation-stage") }
                HStack(spacing: 10) {
                    if model.installation == .notStarted ||
                        (!model.prefixExists && (model.installation == .failed(.downloadFailed)
                            || model.installation == .interrupted(.downloadingInstaller))) {
                        Button("Install Ubisoft Connect") { model.control(.install, setup: setup, diagnostics: diagnostics) }
                            .disabled(model.busy || setup.isBusy || !setup.isReady)
                            .accessibilityIdentifier("install-ubisoft")
                    }
                    if model.prefixExists && !model.executableExists &&
                        (model.installation == .failed(.installerFailed) || model.installation == .failed(.downloadFailed)
                         || model.installation == .interrupted(.creatingPrefix) || model.installation == .interrupted(.downloadingInstaller)
                         || model.installation == .interrupted(.runningInstaller)) {
                        Button("Retry Ubisoft installer") { model.control(.resume, setup: setup, diagnostics: diagnostics) }
                            .disabled(model.busy || setup.isBusy || !setup.isReady)
                            .accessibilityIdentifier("retry-ubisoft-installer")
                    }
                    if model.executableExists &&
                        (model.installation == .failed(.bootstrapFailed) || model.installation == .failed(.installerFailed)
                         || model.installation == .interrupted(.runningInstaller)
                         || model.installation == .interrupted(.bootstrappingLauncher)
                         || model.installation == .interrupted(.validatingInstallation)) {
                        Button("Verify Ubisoft Connect") { model.control(.verify, setup: setup, diagnostics: diagnostics) }
                            .disabled(model.busy || setup.isBusy || !setup.isReady)
                            .accessibilityIdentifier("verify-ubisoft")
                    }
                    if model.installation == .installed {
                        Button("Launch Ubisoft Connect") { model.control(.launch, setup: setup, diagnostics: diagnostics) }
                            .disabled(model.busy || setup.isBusy || model.state != .stopped)
                            .accessibilityIdentifier("launch-ubisoft")
                        Button("Show Ubisoft Connect") { model.control(.show, setup: setup, diagnostics: diagnostics) }
                            .disabled(model.busy || setup.isBusy || model.state != .running)
                            .accessibilityIdentifier("show-ubisoft")
                        Button("Stop Ubisoft Connect") { model.control(.stop, setup: setup, diagnostics: diagnostics) }
                            .disabled(model.busy || setup.isBusy || model.state != .running && model.state != .starting)
                            .accessibilityIdentifier("stop-ubisoft")
                    }
                }
                Text("Quit Gamekit to leave Ubisoft Connect running. Stop affects only this managed launcher and games in its own environment.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.message { Text(message).font(.callout).accessibilityIdentifier("ubisoft-status") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

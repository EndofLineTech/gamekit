import GamekitCore
import SwiftUI

/// A first-run sequence over the same operation gate as Settings → Launchers.
/// Each Next button reflects observed state, not whether a button was clicked.
struct SetupWizardView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @EnvironmentObject private var steam: SteamInstallationModel
    @EnvironmentObject private var ubisoft: UbisoftConnectModel

    let openLaunchers: () -> Void
    let dismiss: () -> Void
    let completedPrerequisites: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, rosetta, wine, graphics, launchers

        var title: String {
            switch self {
            case .welcome: "Welcome to Gamekit"
            case .rosetta: "1. Install Rosetta"
            case .wine: "2. Prepare Wine"
            case .graphics: "3. Add Apple graphics"
            case .launchers: "4. Choose your launchers"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var requestedRosetta = false
    @State private var requestedWine = false
    @State private var recordingCompletion = false
    @State private var completionProblem: String?

    private func check(_ prerequisite: Prerequisite) -> RuntimeCheck? {
        setup.report?.checks.first { $0.prerequisite == prerequisite }
    }

    private var rosettaReady: Bool { check(.rosetta)?.status == .passed }
    private var wineReady: Bool { setup.winePrepared || setup.isReady }
    private var nextEnabled: Bool {
        switch step {
        case .welcome: true
        case .rosetta: rosettaReady && !setup.isBusy
        case .wine: wineReady && rosettaReady && !setup.isBusy
        case .graphics: setup.isReady && !setup.isBusy && !recordingCompletion
        case .launchers: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(step.title)
                .font(.largeTitle.bold())
                .accessibilityIdentifier(step == .welcome ? "welcome-heading" : "wizard-step-heading")
            Group {
                switch step {
                case .welcome: welcome
                case .rosetta: rosetta
                case .wine: wine
                case .graphics: graphics
                case .launchers: launchers
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let problem = completionProblem ?? setup.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).accessibilityIdentifier("wizard-problem")
            }
            Divider()
            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                        .accessibilityIdentifier("wizard-back")
                }
                Spacer()
                if step == .launchers {
                    Button("Finish") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wizard-finish")
                } else {
                    Button("Next") { advance() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!nextEnabled)
                        .accessibilityIdentifier("wizard-next")
                }
            }
        }
        .padding(28)
        .onChange(of: step) { _, _ in startStepIfNeeded() }
        .onChange(of: setup.isBusy) { _, busy in if !busy { startStepIfNeeded() } }
        .onChange(of: setup.checkedAt) { _, _ in startStepIfNeeded() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gamekit brings Windows games to your Mac through managed launchers. It checks what your Mac needs, prepares a verified Wine runtime, and lets you install Steam or Ubisoft Connect without bundling their clients or your games.")
            Text("We'll check Rosetta first, download Wine from its publisher, then ask you to choose Apple's Game Porting Toolkit 4.0 beta 2 DMG. That download requires a free Apple Developer account. Each step checks its result before you continue; installing launchers is optional.")
                .foregroundStyle(.secondary)
            Text("macOS may ask you to approve Rosetta and enter your Mac password. Gamekit does not accept Apple's prompts or sign in to Apple Developer for you.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Browse library") { dismiss() }
                    .accessibilityIdentifier("welcome-browse")
                Button("Launcher setup and recovery") { openLaunchers() }
                    .accessibilityIdentifier("welcome-open-launchers")
            }
        }
    }

    private var rosetta: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rosetta lets this Apple-silicon Mac run the Intel-based Wine engine. Gamekit asks macOS to install it; approve the system dialog and enter your Mac credentials if prompted.")
            readiness(.rosetta)
            if rosettaReady {
                Label("Rosetta is ready. Continue to Wine.", systemImage: "checkmark.circle.fill")
            } else {
                if setup.rosettaRequestPending { ProgressView("Waiting for macOS to finish Rosetta…") }
                else if requestedRosetta {
                    Button("Retry Rosetta installation") { requestedRosetta = false; startStepIfNeeded() }
                        .disabled(setup.isBusy).accessibilityIdentifier("wizard-retry-rosetta")
                }
                if let instruction = setup.rosettaInstruction { Text(instruction).font(.callout) }
                Link("About Rosetta", destination: PrerequisiteGuidance.rosetta)
            }
            Button("Refresh checks") { setup.refresh(diagnostics: diagnostics) }
                .disabled(setup.isBusy).accessibilityIdentifier("wizard-refresh")
        }
    }

    private var wine: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gamekit downloads and verifies the pinned Wine engine and template from their publisher. This preparation does not change other runtimes or any Wine prefix.")
            if wineReady {
                Label("Wine files are prepared and verified. Apple graphics come next.", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("wizard-wine-ready")
            } else if setup.isBusy {
                ProgressView(setup.runtimeSetupStatus ?? "Preparing Wine…")
                    .accessibilityIdentifier("wizard-wine-progress")
            } else if requestedWine {
                Text("Wine is not prepared. Review the error and retry the verified download.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Retry Wine download") { requestedWine = false; startStepIfNeeded() }
                    .accessibilityIdentifier("wizard-retry-wine")
            } else if let reason = setup.steamInstallBlocker {
                Text(reason).font(.callout).foregroundStyle(.secondary)
                Button("Refresh checks") { setup.refresh(diagnostics: diagnostics) }
                    .accessibilityIdentifier("wizard-refresh")
            } else {
                ProgressView("Checking Wine prerequisites…")
            }
        }
    }

    private var graphics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with a free Apple Developer account and download Game Porting Toolkit 4.0 beta 2. Choose its original outer DMG (or the nested evaluation DMG). Gamekit verifies the image and installs its graphics into a separate Wine runtime.")
            Link("Get GPTK 4.0 beta 2 from Apple", destination: PrerequisiteGuidance.graphics)
                .accessibilityIdentifier("wizard-download-gptk")
            if setup.isReady {
                Label("Rosetta, Wine and Apple graphics passed verification.", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("wizard-graphics-ready")
            } else {
                Button("Choose downloaded GPTK DMG…") { setup.prepareRuntime(diagnostics: diagnostics) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!setup.winePrepared || !rosettaReady || !hostReady || setup.isBusy || setup.selectionLocked)
                    .accessibilityIdentifier("wizard-choose-gptk")
                if !setup.winePrepared {
                    Text("Return to the Wine step if its preparation is not ready.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let status = setup.runtimeSetupStatus { Text(status).font(.callout) }
                readiness(.runtime)
                readiness(.graphicsPayload)
            }
            Button("Refresh checks") { setup.refresh(diagnostics: diagnostics) }
                .disabled(setup.isBusy).accessibilityIdentifier("wizard-refresh")
        }
    }

    private var launchers: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Mac is ready. Choose either launcher, both, or neither. You can install a launcher later from Settings → Launchers. Sign in inside each launcher after it opens.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Windows Steam").font(.headline)
                if setup.record?.installation == .installed {
                    Label("Steam is already installed.", systemImage: "checkmark.circle.fill")
                } else {
                    Button(setup.actions.retry ? "Retry Steam setup" : "Install Steam") {
                        steam.start(diagnostics: diagnostics, setup: setup, recoveryRetry: setup.actions.retry)
                    }
                    .disabled(steam.running || !(setup.actions.install || setup.actions.retry))
                    .accessibilityIdentifier("wizard-install-steam")
                    if !(setup.actions.install || setup.actions.retry), let reason = setup.steamInstallBlocker {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let status = steam.status { Text(status).font(.callout) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Ubisoft Connect").font(.headline)
                if ubisoft.installation == .installed {
                    Label("Ubisoft Connect is already installed.", systemImage: "checkmark.circle.fill")
                } else {
                    Button(ubisoftInstallTitle) {
                        ubisoft.control(ubisoftInstallAction, setup: setup, diagnostics: diagnostics)
                    }
                    .disabled(ubisoft.busy || setup.isBusy || !setup.isReady || ubisoft.state == .unverified)
                    .accessibilityIdentifier("wizard-install-ubisoft")
                }
                if ubisoft.busy { ProgressView("Installing Ubisoft Connect…") }
                if let message = ubisoft.message { Text(message).font(.callout) }
            }
            Button("Launcher setup and recovery") { openLaunchers() }
                .accessibilityIdentifier("wizard-open-launchers")
        }
    }

    private var ubisoftInstallAction: UbisoftConnectModel.Action {
        if ubisoft.executableExists { return .verify }
        return ubisoft.prefixExists ? .resume : .install
    }

    private var hostReady: Bool {
        check(.supportedHost)?.status == .passed && check(.diskSpace)?.status == .passed
    }

    private var ubisoftInstallTitle: String {
        switch ubisoftInstallAction {
        case .verify: "Verify Ubisoft Connect"
        case .resume: "Retry Ubisoft Connect setup"
        default: "Install Ubisoft Connect"
        }
    }

    @ViewBuilder private func readiness(_ prerequisite: Prerequisite) -> some View {
        if let check = check(prerequisite) {
            Label("\(PrerequisiteGuidance.title(prerequisite)): \(check.detail)",
                  systemImage: check.status == .passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .accessibilityIdentifier("wizard-prerequisite-\(prerequisite.rawValue)")
        } else {
            ProgressView("Checking \(PrerequisiteGuidance.title(prerequisite))…")
        }
    }

    private func startStepIfNeeded() {
        guard !setup.isBusy else { return }
        switch step {
        case .rosetta where !rosettaReady && check(.rosetta)?.status == .failed && !requestedRosetta:
            requestedRosetta = true
            setup.requestRosetta(diagnostics: diagnostics)
        case .wine where !wineReady && setup.canPrepareWine && !requestedWine:
            requestedWine = true
            setup.prepareWine(diagnostics: diagnostics)
        case .launchers:
            Task { await ubisoft.refresh(setup: setup) }
        default: break
        }
    }

    private func advance() {
        guard nextEnabled else { return }
        if step == .graphics {
            recordingCompletion = true; completionProblem = nil
            Task {
                defer { recordingCompletion = false }
                do {
                    try await SetupWizardCompletionStore(root: AppStorageLocations.metadata).markComplete()
                    completedPrerequisites()
                    step = .launchers
                } catch {
                    completionProblem = "Could not save setup completion. Existing setup metadata was left untouched; open Launcher setup and recovery if retrying Next does not help."
                }
            }
        } else { step = Step(rawValue: step.rawValue + 1) ?? .launchers }
    }
}

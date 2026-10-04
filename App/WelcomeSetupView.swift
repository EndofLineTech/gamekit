import GamekitCore
import SwiftUI

/// First-run guidance over the same prerequisite report and operation gate as
/// Settings → Launchers. Third-party payloads remain user-supplied.
struct WelcomeSetupView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @EnvironmentObject private var installation: SteamInstallationModel
    let openLaunchers: () -> Void
    let browseLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Get your Mac ready for Windows games")
                .font(.headline)
            Text("Click Install Wine to let Gamekit download and prepare it. For graphics, a free Apple Developer account is needed to obtain the Game Porting Toolkit DMG; choose that DMG here after Rosetta is ready.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Launcher setup and recovery") { openLaunchers() }
                    .accessibilityIdentifier("welcome-open-launchers")
                Button("Browse library") { browseLibrary() }
                    .accessibilityIdentifier("welcome-browse")
            }
            HStack(spacing: 10) {
                Button("Refresh checks") { setup.refresh(diagnostics: diagnostics) }
                    .disabled(setup.isBusy)
                    .accessibilityIdentifier("welcome-refresh")
            }
            if let problem = setup.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("welcome-check-problem")
            }
            if let report = setup.report {
                ForEach(report.checks, id: \.prerequisite) { check in
                    prerequisite(check)
                }
                if report.checks.contains(where: { ($0.prerequisite == .runtime || $0.prerequisite == .graphicsPayload) && $0.status != .passed }) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !setup.winePrepared {
                            Button("Install Wine") { setup.prepareWine(diagnostics: diagnostics) }
                                .buttonStyle(.borderedProminent)
                                .disabled(setup.isBusy || setup.selectionLocked || report.checks.contains(where: {
                                    [.supportedHost, .diskSpace].contains($0.prerequisite) && $0.status != .passed
                                }))
                                .accessibilityIdentifier("welcome-install-wine")
                            Text("Gamekit downloads and verifies everything needed for Wine. You can do this before obtaining Apple's DMG or installing Rosetta.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Wine is prepared and verified. Finish Apple's graphics step to make it available to Steam.")
                                .font(.callout).accessibilityIdentifier("welcome-wine-prepared")
                        }
                        Link("Get GPTK from Apple (free Developer account required)", destination: PrerequisiteGuidance.graphics)
                            .accessibilityIdentifier("welcome-download-graphics")
                        Button("Choose Apple DMG and install graphics…") { setup.prepareRuntime(diagnostics: diagnostics) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!setup.winePrepared || setup.isBusy || setup.selectionLocked || report.checks.contains(where: {
                                [.supportedHost, .rosetta, .diskSpace].contains($0.prerequisite) && $0.status != .passed
                            }))
                            .accessibilityIdentifier("welcome-install-runtime")
                        if report.checks.contains(where: { $0.prerequisite == .rosetta && $0.status != .passed }) {
                            Text("Wait for macOS to finish installing Rosetta; Gamekit checks again automatically before enabling graphics setup.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if setup.problem == nil {
                ProgressView("Checking your Mac…")
                    .accessibilityIdentifier("welcome-checking")
            }
            if let status = setup.runtimeSetupStatus {
                Text(status).font(.callout).accessibilityIdentifier("welcome-runtime-installation-status")
            }
            if setup.selectionLocked {
                Text("Stop the managed Steam session before changing runtimes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button(setup.actions.retry ? "Retry Steam setup" : "Install Steam") {
                installation.start(diagnostics: diagnostics, setup: setup, recoveryRetry: setup.actions.retry)
            }
            .buttonStyle(.borderedProminent)
            .disabled(installation.running || setup.isBusy || !(setup.actions.install || setup.actions.retry))
            .accessibilityIdentifier("welcome-install-steam")
            if let status = installation.status {
                Text(status).font(.callout).accessibilityIdentifier("welcome-installation-status")
            }
        }
    }

    private func prerequisite(_ check: RuntimeCheck) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(PrerequisiteGuidance.title(check.prerequisite)): \(state(check.status))",
                  systemImage: check.status == .passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(check.status == .passed ? Color.green : Color.primary)
                .accessibilityIdentifier("welcome-prerequisite-\(check.prerequisite.rawValue)")
            Text(check.detail).font(.callout).foregroundStyle(.secondary)
            if check.status != .passed {
                Text(PrerequisiteGuidance.advice(check.prerequisite)).font(.callout)
                resources(for: check.prerequisite)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func resources(for prerequisite: Prerequisite) -> some View {
        switch prerequisite {
        case .rosetta:
            Button("Install Rosetta with macOS…") { setup.requestRosetta(diagnostics: diagnostics) }
                .disabled(setup.isBusy || setup.rosettaRequestPending)
                .accessibilityIdentifier("welcome-install-rosetta")
            if let instruction = setup.rosettaInstruction {
                Text(instruction).font(.callout).accessibilityIdentifier("welcome-rosetta-instruction")
            }
            Link("About Rosetta", destination: PrerequisiteGuidance.rosetta)
        case .runtime:
            EmptyView()
        case .graphicsPayload:
            Text("Gamekit verifies and installs this from the Apple DMG you choose above.")
                .font(.callout).foregroundStyle(.secondary)
        case .diskSpace:
            Button("Review storage and setup") { openLaunchers() }
                .accessibilityIdentifier("welcome-storage-help")
        case .supportedHost:
            EmptyView()
        }
    }

    private func state(_ status: RuntimeCheckStatus) -> String {
        switch status {
        case .passed: "Ready"
        case .failed: "Needs attention"
        case .unknown: "Not checked"
        }
    }
}

enum PrerequisiteGuidance {
    static let rosetta = URL(string: "https://support.apple.com/en-us/102527")!
    static let graphics = URL(string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit")!
    static let guide = URL(string: "https://github.com/EndofLineTech/gamekit/blob/dev/docs/runtime-revision.md")!

    static func title(_ value: Prerequisite) -> String {
        switch value {
        case .supportedHost: "Mac support"
        case .rosetta: "Rosetta"
        case .runtime: "Wine runtime"
        case .graphicsPayload: "Game Porting Toolkit graphics"
        case .diskSpace: "Storage"
        }
    }

    static func advice(_ value: Prerequisite) -> String {
        switch value {
        case .supportedHost: "This prototype is validated for Apple silicon and macOS 27."
        case .rosetta: "Let macOS download and install Rosetta when requested. Approve Apple's installation prompt if it appears."
        case .runtime: "Use Install Wine below; Gamekit downloads and verifies the required files for you."
        case .graphicsPayload: "A free Apple Developer account is required to download GPTK 4.0 beta 2. Select its DMG below and Gamekit installs the verified graphics."
        case .diskSpace: "Keep at least 15 GiB free on the app-data volume. Review old archives and free space, then refresh."
        }
    }
}

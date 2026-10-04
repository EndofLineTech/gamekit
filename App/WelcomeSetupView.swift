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
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Install Wine").font(.headline)
                Button("Install Wine") { setup.prepareWine(diagnostics: diagnostics) }
                    .buttonStyle(.borderedProminent)
                    .disabled(setup.winePrepared || setup.isBusy || setup.selectionLocked || !hostAndStorageReady || allRuntimeChecksReady)
                    .accessibilityIdentifier("welcome-install-wine")
                if setup.winePrepared {
                    Label("Wine is prepared and verified. Next, install Apple's graphics.", systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier("welcome-wine-prepared")
                } else if allRuntimeChecksReady {
                    Text("The selected Wine runtime and graphics are already ready.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Gamekit downloads and verifies Wine for you. This works before Rosetta or Apple's DMG is available.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let status = setup.runtimeSetupStatus {
                    Text(status).font(.callout).accessibilityIdentifier("welcome-runtime-installation-status")
                }
            }
            if rosettaMissing {
                Button("Install Rosetta with macOS…") { setup.requestRosetta(diagnostics: diagnostics) }
                    .disabled(setup.isBusy || setup.rosettaRequestPending)
                    .accessibilityIdentifier("welcome-install-rosetta")
                if let instruction = setup.rosettaInstruction {
                    Text(instruction).font(.callout).accessibilityIdentifier("welcome-rosetta-instruction")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("2. Add Apple graphics").font(.headline)
                Link("Get GPTK from Apple (free Developer account required)", destination: PrerequisiteGuidance.graphics)
                    .accessibilityIdentifier("welcome-download-graphics")
                Button("Choose Apple DMG and install graphics…") { setup.prepareRuntime(diagnostics: diagnostics) }
                    .disabled(!setup.winePrepared || setup.isBusy || setup.selectionLocked || !graphicsSetupReady || allRuntimeChecksReady)
                    .accessibilityIdentifier("welcome-install-runtime")
                if rosettaMissing {
                    Text("Wait for macOS to finish installing Rosetta; Gamekit checks again automatically before enabling graphics setup.")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
            if let problem = setup.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("welcome-check-problem")
            }
            if let report = setup.report {
                Text("Prerequisite details").font(.headline)
                ForEach(report.checks, id: \.prerequisite) { check in
                    prerequisite(check)
                }
            } else if setup.problem == nil {
                ProgressView("Checking your Mac…")
                    .accessibilityIdentifier("welcome-checking")
            }
            if setup.selectionLocked {
                Text("Stop the managed Steam session before changing runtimes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var rosettaMissing: Bool {
        setup.report?.checks.contains { $0.prerequisite == .rosetta && $0.status != .passed } ?? false
    }

    private var hostAndStorageReady: Bool {
        guard let checks = setup.report?.checks else { return false }
        return [.supportedHost, .diskSpace].allSatisfy { requirement in
            checks.contains { $0.prerequisite == requirement && $0.status == .passed }
        }
    }

    private var graphicsSetupReady: Bool {
        guard let checks = setup.report?.checks else { return false }
        return hostAndStorageReady && checks.contains { $0.prerequisite == .rosetta && $0.status == .passed }
    }

    private var allRuntimeChecksReady: Bool {
        guard let checks = setup.report?.checks else { return false }
        return [.runtime, .graphicsPayload].allSatisfy { requirement in
            checks.contains { $0.prerequisite == requirement && $0.status == .passed }
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
        case .runtime: "Use Install Wine above; Gamekit downloads and verifies the required files for you."
        case .graphicsPayload: "A free Apple Developer account is required to download GPTK 4.0 beta 2. Select its DMG above and Gamekit installs the verified graphics."
        case .diskSpace: "Keep at least 15 GiB free on the app-data volume. Review old archives and free space, then refresh."
        }
    }
}

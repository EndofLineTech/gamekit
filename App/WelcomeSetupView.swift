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
            Text("Gamekit checks your Mac, installs the verified Wine runtime from its publisher, and installs Steam from Valve. Sign in to Apple Developer to get the Game Porting Toolkit DMG, then select it here; Gamekit verifies and assembles it for you.")
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
                Button("Choose prepared runtime…") { setup.chooseRuntime(diagnostics: diagnostics) }
                    .disabled(setup.isBusy || setup.selectionLocked)
                    .accessibilityIdentifier("welcome-choose-runtime")
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
                        Link("Get Apple Game Porting Toolkit (Apple Developer sign-in)", destination: PrerequisiteGuidance.graphics)
                            .accessibilityIdentifier("welcome-download-graphics")
                        Button("Choose Apple DMG and install Wine + graphics…") { setup.prepareRuntime(diagnostics: diagnostics) }
                            .buttonStyle(.borderedProminent)
                            .disabled(setup.isBusy || setup.selectionLocked || report.checks.contains(where: {
                                [.supportedHost, .rosetta, .diskSpace].contains($0.prerequisite) && $0.status != .passed
                            }))
                            .accessibilityIdentifier("welcome-install-runtime")
                        Text("Gamekit downloads and verifies the exact Sikarugir engine and template, then stages your Apple graphics without changing another runtime or Steam prefix.")
                            .font(.callout).foregroundStyle(.secondary)
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
                .disabled(setup.isBusy)
                .accessibilityIdentifier("welcome-install-rosetta")
            Link("About Rosetta", destination: PrerequisiteGuidance.rosetta)
        case .runtime:
            HStack(spacing: 12) {
                Link("Wine publisher", destination: PrerequisiteGuidance.wine)
                    .accessibilityIdentifier("welcome-download-wine")
                Link("Template publisher", destination: PrerequisiteGuidance.template)
                    .accessibilityIdentifier("welcome-download-template")
                Link("Verified recipe", destination: PrerequisiteGuidance.guide)
            }
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
    static let wine = (try? RuntimeSetupRecipe.bundled().engine.url) ?? guide
    static let template = (try? RuntimeSetupRecipe.bundled().template.url) ?? guide
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
        case .rosetta: "Install Rosetta using Apple's instructions, then refresh checks. Gamekit does not accept its license for you."
        case .runtime: "Choose the validated runtime app with its packaged dependencies. A generic Wine app is not interchangeable."
        case .graphicsPayload: "Restore the unchanged D3DMetal 4.0b2 payload from the validated setup guide, then refresh."
        case .diskSpace: "Keep at least 15 GiB free on the app-data volume. Review old archives and free space, then refresh."
        }
    }
}

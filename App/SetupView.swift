import GamekitCore
import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Setup and prerequisites", systemImage: "checklist").font(.headline)
                    Spacer()
                    Button("Refresh checks") { setup.refresh(diagnostics: diagnostics) }
                        .disabled(setup.isBusy).keyboardShortcut("r", modifiers: [.command, .shift])
                        .accessibilityIdentifier("refresh-prerequisites")
                        .help("Recheck host, runtime and storage prerequisites (⇧⌘R)")
                }
                Text(setup.isReady ? "Ready to install and launch" : setup.report == nil ? "Prerequisites not yet verified" : "Resolve the checks below before installation")
                    .accessibilityIdentifier("prerequisite-status")
                if let problem = setup.problem { Text(problem).foregroundStyle(.secondary) }
                if let report = setup.report {
                    ForEach(report.checks, id: \.prerequisite) { check in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(title(check.prerequisite) + ": " + check.detail, systemImage: check.status == .passed ? "checkmark.circle" : "exclamationmark.circle")
                            if check.status != .passed { Text(advice(check.prerequisite)).font(.callout).foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("prerequisite-\(check.prerequisite.rawValue)")
                    }
                }
                HStack {
                    Button("Choose runtime…") { setup.chooseRuntime(diagnostics: diagnostics) }
                        .help("Choose a validated runtime app from disk")
                    Button("Use updated runtime") { setup.chooseRuntime(diagnostics: diagnostics, useDefault: true, revision: .driverVersion1) }
                        .accessibilityIdentifier("use-driver-compatibility-runtime")
                        .help("Select the prepared runtime with per-game compatibility support")
                }.disabled(setup.isBusy || setup.selectionLocked)
                HStack {
                    Button("Use text-input runtime (rollback)") { setup.chooseRuntime(diagnostics: diagnostics, useDefault: true, revision: .textInput1) }
                        .accessibilityIdentifier("use-text-input-runtime")
                        .help("Roll back to the prepared text-input runtime revision")
                    Button("Use original runtime") { setup.chooseRuntime(diagnostics: diagnostics, useDefault: true, revision: .original) }
                        .accessibilityIdentifier("use-original-runtime")
                        .help("Select the original validated runtime revision")
                }.disabled(setup.isBusy || setup.selectionLocked)
                if setup.selectionLocked { Text("Stop the recorded Steam session before changing runtimes.").font(.caption) }
                Text("Selected runtime: \(setup.layout.bundle.path)").font(.caption).textSelection(.enabled)
                Text("Revision: \(setup.layout.profile.revision.title)").font(.caption)
                if setup.layout.profile.revision == .driverVersion1 {
                    Text("Game-specific compatibility options are controlled from the gear beside each game's Play button.")
                        .font(.caption).accessibilityIdentifier("driver-compatibility-scope")
                }
                Text("App data: \(setup.layout.dataRoot.path)").font(.caption).textSelection(.enabled)
                Text("Logs: \(AppStorageLocations.diagnostics.path)").font(.caption).textSelection(.enabled)
                HStack {
                    Link("Rosetta help", destination: URL(string: "https://support.apple.com/en-us/102527")!)
                        .help("Open Apple's Rosetta installation instructions")
                    Link("Apple GPTK downloads", destination: URL(string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit")!)
                        .help("Open Apple's Game Porting Toolkit downloads")
                    Link("Runtime setup guide", destination: URL(string: "https://github.com/EndofLineTech/gamekit/blob/dev/docs/runtime-revision.md")!)
                        .help("Open the validated Gamekit runtime setup guide")
                }.font(.caption)
                if let checked = setup.checkedAt { Text("Last checked \(checked.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
    private func title(_ value: Prerequisite) -> String {
        switch value {
        case .supportedHost: "Mac support"
        case .rosetta: "Rosetta"
        case .runtime: "Wine runtime"
        case .graphicsPayload: "Graphics"
        case .diskSpace: "Storage"
        }
    }
    private func advice(_ value: Prerequisite) -> String {
        switch value {
        case .supportedHost: "This prototype is validated for Apple silicon and macOS 27."
        case .rosetta: "Install Rosetta using Apple's instructions, then refresh checks. Gamekit does not accept its license for you."
        case .runtime: "Choose the validated runtime app with its packaged dependencies. A generic Wine app is not interchangeable."
        case .graphicsPayload: "Restore the unchanged D3DMetal 4.0b2 payload from the validated setup guide, then refresh."
        case .diskSpace: "Keep at least 15 GiB free on the app-data volume. Review old archives and free space, then refresh."
        }
    }
}

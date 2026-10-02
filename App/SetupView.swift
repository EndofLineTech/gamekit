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
                            Label(PrerequisiteGuidance.title(check.prerequisite) + ": " + check.detail, systemImage: check.status == .passed ? "checkmark.circle" : "exclamationmark.circle")
                            if check.status != .passed { Text(PrerequisiteGuidance.advice(check.prerequisite)).font(.callout).foregroundStyle(.secondary) }
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
                    Link("Rosetta help", destination: PrerequisiteGuidance.rosetta)
                        .help("Open Apple's Rosetta installation instructions")
                    Link("Apple GPTK downloads", destination: PrerequisiteGuidance.graphics)
                        .help("Open Apple's Game Porting Toolkit downloads")
                    Link("Runtime setup guide", destination: PrerequisiteGuidance.guide)
                        .help("Open the validated Gamekit runtime setup guide")
                }.font(.caption)
                if let checked = setup.checkedAt { Text("Last checked \(checked.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

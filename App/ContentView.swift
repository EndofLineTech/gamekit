import AppKit
import GamekitCore
import SwiftUI

struct ContentView: View {
    @StateObject private var diagnostics = AppDiagnosticsModel()
    @StateObject private var setup = SetupModel()
    @StateObject private var games = InstalledGamesModel()
    @StateObject private var steam = SteamLifecycleModel()
    @StateObject private var installation = SteamInstallationModel()
    @Environment(\.scenePhase) private var scenePhase
    private let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion

    private var architecture: HostArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unknown
        #endif
    }

    private var hostMatchesScope: Bool {
        PrototypeHostPolicy.failures(
            macOSMajorVersion: operatingSystem.majorVersion,
            architecture: architecture
        ).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if let activity = setup.activity {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(activity).accessibilityIdentifier("operation-status")
                    Spacer()
                }.padding(16).background(.quaternary)
            }
            ScrollView { content }
        }
        .frame(minWidth: 640, minHeight: 620)
        .environmentObject(diagnostics)
        .environmentObject(setup)
        .environmentObject(games)
        .environmentObject(steam)
        .environmentObject(installation)
        .task {
            setup.refresh(diagnostics: diagnostics)
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--install-steam") || arguments.contains("--verify-steam") || arguments.contains("--launch-steam") {
                while (setup.report == nil || setup.isBusy) && setup.problem == nil && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                if arguments.contains("--install-steam") || arguments.contains("--verify-steam") {
                    installation.start(diagnostics: diagnostics, setup: setup, verificationOnly: arguments.contains("--verify-steam"))
                } else {
                    await steam.refresh(setup: setup)
                    steam.control(stop: false, diagnostics: diagnostics, setup: setup)
                }
            }
            #endif
        }
        .task(id: setup.selectionRevision) {
            while !Task.isCancelled {
                await games.refresh(setup: setup)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .task(id: setup.selectionRevision) {
            while !Task.isCancelled {
                await steam.refresh(setup: setup)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await games.refresh(setup: setup) } }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gamekit")
                        .font(.largeTitle.bold())
                    Text("Windows Steam on macOS")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Personal prototype")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }

            Text("Sikarugir Wine 10.0 revision 6 + Apple D3DMetal 4.0b2")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("runtime-recipe")

            VStack(alignment: .leading, spacing: 8) {
                Text("Prototype target: Apple silicon · macOS \(PrototypeHostPolicy.macOSMajorVersion)")
                    .font(.headline)
                Label(
                    hostMatchesScope ? "Host is in prototype scope" : "Host is outside the evaluated scope",
                    systemImage: hostMatchesScope ? "checkmark.circle" : "info.circle"
                )
                .accessibilityIdentifier("host-scope")
                Text("The checks below inspect Rosetta and the installed runtime. Setup uses a dedicated managed Steam environment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SteamLifecycleView()
            InstalledGamesView()
            SetupView()
            EnvironmentSummaryView()
            SteamInstallationView()
            DiagnosticsView()
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}

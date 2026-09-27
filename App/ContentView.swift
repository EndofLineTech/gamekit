import AppKit
import GamekitCore
import SwiftUI

struct ContentView: View {
    @StateObject private var diagnostics = AppDiagnosticsModel()
    @StateObject private var setup = SetupModel()
    @StateObject private var games = InstalledGamesModel()
    @StateObject private var steam = SteamLifecycleModel()
    @StateObject private var installation = SteamInstallationModel()
    @StateObject private var portraits = SteamPortraitModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 0) {
            if let activity = setup.activity {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(activity).accessibilityIdentifier("operation-status")
                    Spacer()
                }.padding(16).background(.quaternary)
            }
            LibraryShellView()
            if let message = games.message {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                    Text(message).font(.callout).accessibilityIdentifier("persistent-game-status")
                    Spacer()
                    Button("Show Windows Steam") {
                        steam.control(stop: false, diagnostics: diagnostics, setup: setup)
                    }
                    .disabled(!(setup.actions.launch || setup.actions.show))
                }
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(LibraryVisualStyle.panel)
            }
        }
        .frame(minWidth: 850, minHeight: 620)
        .environmentObject(diagnostics)
        .environmentObject(setup)
        .environmentObject(games)
        .environmentObject(steam)
        .environmentObject(installation)
        .environmentObject(portraits)
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

}

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
            // Keep navigation at a stable screen position while an operation
            // starts or finishes; removing this row during a click loses it.
            HStack(spacing: 12) {
                if let activity = setup.activity {
                    ProgressView().controlSize(.small)
                    Text(activity).lineLimit(1).accessibilityIdentifier("operation-status")
                }
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 36)
            .background {
                if setup.activity != nil { Rectangle().fill(.bar) }
            }
            LibraryShellView()
            if let problem = setup.problem {
                statusBanner(problem, symbol: "exclamationmark.triangle", identifier: "persistent-setup-error")
            }
            if let warning = games.warning {
                statusBanner(warning, symbol: "exclamationmark.triangle", identifier: "persistent-library-warning")
            }
            if let message = games.message {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                    Text(message).font(.callout).accessibilityIdentifier("persistent-game-status")
                    Spacer()
                    Button("Diagnostics") { diagnostics.open(operationID: games.lastDiagnosticID) }
                        .accessibilityIdentifier("game-diagnostics-link")
                        .help("Open diagnostics for this game action")
                }
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(LibraryVisualStyle.panel)
            }
            if let message = steam.message {
                statusBanner(message, symbol: "info.circle", identifier: "persistent-steam-status",
                             operationID: steam.lastDiagnosticID)
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
        .onChange(of: setup.activity) { _, activity in
            if let activity { AccessibilityNotification.Announcement(activity).post() }
        }
        .onChange(of: games.message) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onChange(of: games.warning) { _, warning in
            if let warning { AccessibilityNotification.Announcement(warning).post() }
        }
        .onChange(of: steam.message) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func statusBanner(_ message: String, symbol: String, identifier: String, operationID: UUID? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
            Button("Diagnostics") { diagnostics.open(operationID: operationID) }
                .accessibilityIdentifier("\(identifier)-diagnostics")
                .help("Open diagnostics for this status")
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(LibraryVisualStyle.panel)
    }

}

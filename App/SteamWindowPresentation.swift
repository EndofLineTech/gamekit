import AppKit
import GamekitCore

/// A Steam protocol request can create a dialog without activating its macOS
/// application. Hand focus to the owned window process, not a name-matched or
/// native Steam installation. Retrying focus never resends the protocol request.
@MainActor
enum SteamWindowPresentation {
    static func bringForward(using lifecycle: SteamLifecycle) async throws -> Bool {
        var activePID: pid_t?
        for attempt in 0..<12 {
            try Task.checkCancellation()
            if NSApplication.shared.windows.contains(where: { $0.attachedSheet != nil }) {
                activePID = nil
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            let snapshot = try await lifecycle.diagnosticProcesses()
            let processes = snapshot.processes.filter { $0.role == .steamUI } + snapshot.processes.filter { $0.role == .steam }
            let applications = processes.compactMap { NSRunningApplication(processIdentifier: $0.identity.pid) }
                .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            let owners = SteamReadiness.windowOwners()
            if let application = applications.first(where: { owners.contains($0.processIdentifier) }) ?? applications.first {
                if application.isActive && activePID == application.processIdentifier { return true }
                activePID = application.isActive ? application.processIdentifier : nil
                // The confirmation sheet may still be finishing its dismissal.
                // Cooperatively transfer activation, then verify on a later turn.
                if attempt == 0 || !application.isActive {
                    _ = application.unhide()
                    NSApplication.shared.yieldActivation(to: application)
                    _ = application.activate(from: .current, options: .activateAllWindows)
                }
            } else {
                activePID = nil
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}

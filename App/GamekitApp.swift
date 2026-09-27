import AppKit
import SwiftUI

@main
struct GamekitApp: App {
    // A 1200-point window can place its entire sidebar off-screen on a
    // compact display (including the CI desktop). Leave room for window
    // chrome while retaining the intended size on larger monitors.
    private var startingSize: CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 1200, height: 800) }
        return CGSize(width: max(850, min(1200, screen.visibleFrame.width - 24)),
                      height: max(620, min(800, screen.visibleFrame.height - 24)))
    }

    var body: some Scene {
        Window("Gamekit", id: "main") {
            ContentView()
        }
        .defaultSize(width: startingSize.width, height: startingSize.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .gamekitOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let gamekitOpenSettings = Notification.Name("GamekitOpenSettings")
}

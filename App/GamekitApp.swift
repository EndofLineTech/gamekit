import SwiftUI

@main
struct GamekitApp: App {
    var body: some Scene {
        Window("Gamekit", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
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

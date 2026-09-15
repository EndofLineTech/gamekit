import SwiftUI

@main
struct GamekitApp: App {
    var body: some Scene {
        Window("Gamekit", id: "main") {
            ContentView()
        }
        .defaultSize(width: 760, height: 500)
        .windowResizability(.contentMinSize)
    }
}

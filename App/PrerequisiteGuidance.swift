import GamekitCore
import Foundation

enum PrerequisiteGuidance {
    static let rosetta = URL(string: "https://support.apple.com/en-us/102527")!
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
        case .rosetta: "Let macOS download and install Rosetta when requested. Approve Apple's installation prompt if it appears."
        case .runtime: "Gamekit downloads and verifies the required Wine files for you."
        case .graphicsPayload: "A free Apple Developer account is required to download GPTK 4.0 beta 2. Choose its DMG and Gamekit installs the verified graphics."
        case .diskSpace: "Keep at least 15 GiB free on the app-data volume. Review old archives and free space, then refresh."
        }
    }
}

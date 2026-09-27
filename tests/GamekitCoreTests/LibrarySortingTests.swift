import Foundation
import Testing
@testable import GamekitCore

@Suite("Steam library presentation sorting")
struct LibrarySortingTests {
    @Test("All available columns have deterministic order and missing size differs from zero")
    func columns() {
        func game(_ id: UInt32, _ name: String, _ state: SteamGameInstallState, _ bytes: Int64?) -> InstalledSteamGame {
            .init(id: id, name: name, installDirectory: name, buildID: nil,
                  state: state, sizeOnDiskBytes: bytes, artwork: nil)
        }
        let games = [game(10, "Beta", .ready, 10), game(11, "Alpha", .missingFiles, nil),
                     game(12, "Alpha", .updating, nil), game(13, "Zero", .ready, 0),
                     game(14, "Gamma", .ready, nil), game(15, "Alpha", .ready, 10)]
        #expect(LibrarySortOrder.name.sorted(games).map(\.id) == [11, 12, 15, 10, 14, 13])
        #expect(LibrarySortOrder.source.sorted(games).map(\.id) == [11, 12, 15, 10, 14, 13])
        #expect(LibrarySortOrder.state.sorted(games).map(\.id) == [15, 10, 14, 13, 12, 11])
        #expect(LibrarySortOrder.reportedSize.sorted(games).map(\.id) == [15, 10, 13, 11, 12, 14])
    }
}

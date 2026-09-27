import AppKit
import GamekitCore
import SwiftUI

/// One cache per window, not per tile. The lazy grid's `.task(id:)` cancels work
/// for discarded cells while the actor bounds simultaneous downloads and memory.
@MainActor
final class SteamPortraitModel: ObservableObject {
    private let cache: SteamPortraitArtworkCache?

    init() {
        if let store = try? EnvironmentStore(root: AppStorageLocations.metadata) {
            cache = SteamPortraitArtworkCache(prefix: store.prefixURL(for: SteamInstallationRecipe.environmentID))
        } else { cache = nil }
    }

    func image(for id: SteamGameInstallationID) async -> NSImage? {
        guard let bytes = await cache?.portrait(for: id), !Task.isCancelled else { return nil }
        return NSImage(data: bytes)
    }
}

/// The image has no launch gesture; the containing tile owns selection/Play.
/// The cover never stretches a landscape header into the portrait slot.
struct SteamPortraitCover: View {
    @EnvironmentObject private var portraits: SteamPortraitModel
    let game: SteamLibraryGame
    var markSize: CGFloat = 28
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack {
                    Spacer()
                    Image(systemName: "gamecontroller.fill")
                        .font(markSize < 20 ? .caption2 : .title).accessibilityHidden(true)
                    if markSize >= 20 {
                        Text(game.title).font(.headline).lineLimit(3).minimumScaleFactor(0.75)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(markSize < 20 ? 3 : 12)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) {
            Image("SteamLauncherMark").resizable().interpolation(.high)
                .frame(width: markSize, height: markSize)
                .opacity(LibraryVisualStyle.launcherMarkOpacity)
                .shadow(color: .black.opacity(0.75), radius: 3)
                .padding(markSize < 20 ? 4 : 9) // No backing plate: artwork stays visible.
        }
        .task(id: game.id) {
            image = nil
            image = await portraits.image(for: game.id)
        }
        .accessibilityHidden(true)
    }
}

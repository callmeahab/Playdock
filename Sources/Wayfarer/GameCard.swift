import AppKit
import SwiftUI
import WayfarerCore

private enum ArtworkCache {
    static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>(); cache.countLimit = 80; return cache
    }()
    static func image(at url: URL) -> NSImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct GameArtwork: View {
    let game: LibraryGame
    var wide = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [WayfarerTheme.raised, Color(red: 0.07, green: 0.19, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let artwork = wide ? game.heroArtwork : game.artwork, let image = ArtworkCache.image(at: artwork) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height)
                } else if case .added(let added) = game.preferredInstallation, added.effectivePlatform == .macOS {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: added.executable.path)).resizable().scaledToFit().frame(width: geometry.size.width * 0.55, height: geometry.size.height * 0.5)
                } else {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 48, weight: .light)).foregroundStyle(.white.opacity(0.2))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

struct PlatformBadge: View {
    let platform: GamePlatform
    var body: some View {
        Label(platform.name, systemImage: platform == .macOS ? "apple.logo" : "square.grid.2x2.fill")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
    }
}

struct GameCard: View {
    let game: LibraryGame
    let favorite: Bool
    let opening: Bool
    var sessionPhase:GameSessionPhase? = nil
    var preferredPlatform: GamePlatform? = nil
    var installationDisabled: (GamePlatform) -> Bool = { _ in false }
    var availabilityMessage: String = "Ready to install"
    private var disabled: Bool { (preferredPlatform ?? game.preferredPlatform).map(installationDisabled) ?? false }
    private var isInstalled: Bool { (preferredPlatform ?? game.preferredPlatform).map { game.installation(for: $0) != nil } ?? false }
    let launch: () -> Void
    let openDetails: () -> Void
    let choosePlatform: (GamePlatform) -> Void
    let toggleFavorite: () -> Void
    let settings: () -> Void
    let remove: (AddedGame) -> Void
    let uninstall:(GamePlatform)->Void
    @WayfarerState private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .bottomLeading) {
                        GameArtwork(game: game).scaleEffect(hovered && !reduceMotion ? 1.035 : 1)
                            .saturation(disabled ? 0.25 : 1).opacity(disabled ? 0.55 : 1)
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        HStack(spacing: 4) { ForEach(game.platforms, id: \.self) { PlatformBadge(platform: $0) } }.padding(10)
                    }
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovered ? WayfarerTheme.accent.opacity(0.6) : .white.opacity(0.1), lineWidth: 1))
                    Text(game.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.94))
                        .lineLimit(2).frame(height: 33, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if opening { Image(systemName: "play.circle.fill"); Text(sessionPhase?.title ?? "Session active") }
                        else { Image(systemName: disabled ? "network.slash" : isInstalled ? "checkmark.circle.fill" : "arrow.down.circle"); Text(!isInstalled ? availabilityMessage : "Ready to play") }
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(opening ? WayfarerTheme.accent : Color.secondary).lineLimit(1).padding(.trailing, 28)
                }
            }.buttonStyle(.plain).help("View \(game.name)")
                .accessibilityLabel("View \(game.name), \(game.platforms.map(\.name).joined(separator: " and "))")
            Button(action: toggleFavorite) {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(favorite ? WayfarerTheme.accent : Color.white.opacity(0.8))
                    .frame(width: 30, height: 30).background(.black.opacity(0.42), in: Circle())
            }.buttonStyle(.plain).padding(10)
                .opacity(favorite || hovered ? 1 : 0.55)
                .help(favorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(favorite ? "Remove \(game.name) from favorites" : "Favorite \(game.name)")
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: launch) { Image(systemName: isInstalled ? "play.fill" : "arrow.down.to.line").font(.system(size: 10)).frame(width: 26, height: 23) }
                .buttonStyle(.plain).foregroundStyle(WayfarerTheme.accent)
                .disabled(disabled).opacity(disabled ? 0.35 : 1)
                .help("\(isInstalled ? "Play" : "Install") \(game.name)").accessibilityLabel("\(isInstalled ? "Play" : "Install") \(game.name)")
        }
        .contextMenu {
            Button("View game", action: openDetails)
            Button("Game settings…",action:settings)
            ForEach(game.platforms, id: \.self) { platform in Button("\(game.installation(for: platform) == nil ? "Install" : "Play") \(platform.name) version") { choosePlatform(platform) }.disabled(installationDisabled(platform)) }
            Divider()
            Button(favorite ? "Remove from favorites" : "Add to favorites", action: toggleFavorite)
            if let location = game.preferredInstallation?.location { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) } }
            if game.isSteam,game.isInstalled {
                Divider()
                ForEach(game.installations.filter { $0.steamGame != nil }.map(\.platform),id:\.self) { platform in
                    Button("Uninstall \(platform.name) version…",role:.destructive) { uninstall(platform) }
                }
            }
            if case .added(let added) = game.preferredInstallation { Divider(); Button("Remove shortcut") { remove(added) } }
        }
        .offset(y: hovered && !reduceMotion ? -3 : 0)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}

struct GameShelf: View {
    @ObservedObject var model: LauncherModel
    let games: [LibraryGame]
    var preferredPlatform: GamePlatform?
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)], alignment: .leading, spacing: 24) {
            ForEach(games) { game in
                GameCard(game: game, favorite: model.favorites.contains(game.id), opening: model.activeSession(game.id) != nil, sessionPhase:model.activeSession(game.id)?.phase, preferredPlatform: preferredPlatform ?? model.preferredGamePlatform(game),
                         installationDisabled: { model.installationDisabled(game,platform:$0) }, availabilityMessage: model.installationAvailabilityMessage(preferredPlatform ?? model.preferredGamePlatform(game) ?? .macOS),
                         launch: { model.launch(game, platform: preferredPlatform) }, openDetails: { model.showGame(game, platform: preferredPlatform) }, choosePlatform: { model.launch(game, platform: $0) },
                         toggleFavorite: { model.toggleFavorite(game) }, settings:{model.featureGame=game}, remove: { model.removeGame($0) },uninstall:{model.requestUninstall(game,platform:$0)})
            }
        }
    }
}

struct LibrarySectionTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.2)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

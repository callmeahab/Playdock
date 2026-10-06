import SwiftUI
import WayfarerCore

struct HomeView: View {
    @ObservedObject var model: LauncherModel
    let addGame: () -> Void
    let browse: () -> Void
    let engines: () -> Void
    @WayfarerState private var featuredID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var ready: [LibraryGame] { model.quickGames.filter(\.isInstalled) }
    private var highlights: [LibraryGame] {
        Array((ready + model.quickGames.filter { !$0.isInstalled }).prefix(3))
    }
    private var featured: LibraryGame? { highlights.first { $0.id == featuredID } ?? highlights.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(spacing: 10) {
                hero
                if highlights.count > 1 {
                    HStack(spacing: 10) {
                        ForEach(highlights) { game in
                            Button { featuredID = game.id } label: {
                                HStack(spacing: 11) {
                                    GameArtwork(game: game).frame(width: 37, height: 47).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(game.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                        Text(game.isInstalled ? "Ready to play" : "In your collection").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if featured?.id == game.id { Image(systemName: "waveform.path").font(.system(size: 12)).foregroundStyle(WayfarerTheme.accent) }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.white.opacity(featured?.id == game.id ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(featured?.id == game.id ? WayfarerTheme.accent.opacity(0.35) : Color.white.opacity(0.055), lineWidth: 1))
                            }.buttonStyle(.plain).help("Feature \(game.name)")
                                .accessibilityAddTraits(featured?.id == game.id ? .isSelected : [])
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                destinationCard(title: "Ready to play", value: "\(ready.count)", subtitle: "Installed on your Mac", symbol: "play.fill", color: WayfarerTheme.accent) { model.navigate("Library") }
                destinationCard(title: "Your collection", value: "\(model.visibleLibrary.count)", subtitle: "Mac & Windows, together", symbol: "square.grid.2x2.fill", color: WayfarerTheme.violet, action: browse)
                destinationCard(title: "Lean back. Play.", value: nil, subtitle: "Controller fullscreen", symbol: "gamecontroller.fill", color: WayfarerTheme.amber) { model.showingCouch = true }
            }
            if !ready.isEmpty {
                HStack {
                    LibrarySectionTitle(title: "Jump back in", subtitle: "Installed and ready for your next session.")
                    Spacer()
                    Button(action: browse) { Label("View all games", systemImage: "arrow.right") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(WayfarerTheme.accent)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 400), spacing: 16)], spacing: 16) {
                    ForEach(ready.prefix(6)) { game in readyCard(game) }
                }
            } else if !model.visibleLibrary.isEmpty {
                LibrarySectionTitle(title: "Find your next adventure", subtitle: "Install a game from your collection to get started.")
                GameShelf(model: model, games: Array(model.quickGames.prefix(5)))
            }
            if model.selectedProfile == nil || model.steamExecutable == nil {
                HStack(spacing: 17) {
                    Image(systemName: "cpu").font(.system(size: 22)).foregroundStyle(WayfarerTheme.violet)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Bring your Windows games along").font(.system(size: 13, weight: .semibold))
                        Text(model.selectedProfile == nil ? "Connect CrossOver, Wine, or GPTK to get started." : "Set up Wayfarer's Windows Steam and sign in.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.selectedProfile == nil ? "Choose engine" : "Set up Steam") {
                        if model.selectedProfile == nil { engines() } else { model.installSteam() }
                    }.buttonStyle(QuietButtonStyle()).disabled(model.installing)
                }.padding(20).glassPanel(radius: 17)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            if let game = featured { GameArtwork(game: game, wide: true) }
            else {
                LinearGradient(colors: [WayfarerTheme.violet.opacity(0.3), WayfarerTheme.accent.opacity(0.18), WayfarerTheme.surface], startPoint: .topTrailing, endPoint: .bottomLeading)
                Image(systemName: "sailboat.fill").font(.system(size: 180, weight: .ultraLight)).foregroundStyle(WayfarerTheme.accent.opacity(0.12))
                    .rotationEffect(.degrees(-10)).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 45)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.83), location: 0), .init(color: .black.opacity(0.50), location: 0.45), .init(color: .black.opacity(0.04), location: 1)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 7) {
                        Circle().fill(WayfarerTheme.accent).frame(width: 5, height: 5)
                        Eyebrow(title: featured?.isInstalled == true ? "Pick up & play" : "Your next adventure", color: .white.opacity(0.9))
                    }.padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.3), in: Capsule())
                    Spacer()
                    if let game = featured {
                        Button { model.toggleFavorite(game) } label: { Image(systemName: model.favorites.contains(game.id) ? "heart.fill" : "heart") }
                            .buttonStyle(QuietButtonStyle()).help("Favorite \(game.name)")
                    }
                }
                Spacer(minLength: 20)
                Text(featured?.name ?? "Every world.\nOne place to play.")
                    .font(.system(size: 40, weight: .bold)).tracking(-1.2).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: 590, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                if let game = featured {
                    HStack(spacing: 7) {
                        ForEach(game.platforms, id: \.self) { PlatformBadge(platform: $0) }
                        Text(game.isSteam ? "Steam library" : "Added to Wayfarer").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    }.padding(.top, 13)
                    HStack(spacing: 10) {
                        Button { model.launch(game, platform: model.quickPlatform(game) ?? model.preferredGamePlatform(game)) } label: {
                            Label(model.activeSession(game.id) != nil ? "Return to game" : game.isInstalled ? "Play now" : "Install game", systemImage: game.isInstalled ? "play.fill" : "arrow.down.to.line")
                        }.buttonStyle(PlayButtonStyle())
                            .disabled(model.installing || model.installationDisabled(game, platform: model.quickPlatform(game) ?? model.preferredGamePlatform(game) ?? .macOS))
                        Button { model.showGame(game) } label: { Label("Game details", systemImage: "arrow.up.right") }.buttonStyle(QuietButtonStyle())
                    }.padding(.top, 22)
                } else {
                    Text("Your Mac favorites and Windows adventures, together.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).padding(.top, 13)
                    Button(action: addGame) { Label("Add your first game", systemImage: "plus") }.buttonStyle(PlayButtonStyle()).padding(.top, 22)
                }
            }.padding(30)
        }.frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: featured?.id)
    }

    private func destinationCard(title: String, value: String?, subtitle: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
                    .frame(width: 40, height: 40).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        if let value { Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(color) }
                    }
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 16)
        }.buttonStyle(.plain)
    }

    private func readyCard(_ game: LibraryGame) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.showGame(game) } label: {
                ZStack(alignment: .bottomLeading) {
                    GameArtwork(game: game, wide: true)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    if let platform = model.quickPlatform(game) { PlatformBadge(platform: platform).padding(12) }
                }.frame(height: 145).clipped()
            }.buttonStyle(.plain).help("View \(game.name)")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(model.activeSession(game.id)?.phase.title ?? "Ready to play").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { model.launch(game, platform: model.quickPlatform(game)) } label: { Image(systemName: "play.fill").frame(width: 12, height: 12) }
                    .buttonStyle(QuietButtonStyle()).help("Play \(game.name)").accessibilityLabel("Play \(game.name)")
            }.padding(14)
        }.glassPanel(radius: 17).clipShape(RoundedRectangle(cornerRadius: 17))
    }
}

import SwiftUI
import WayfarerCore

struct HomeView: View {
    @ObservedObject var model: LauncherModel
    let addGame: () -> Void
    let browse: () -> Void
    let engines: () -> Void
    @WayfarerState private var featuredID: String?
    @WayfarerState private var discoveryID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var ready: [LibraryGame] { model.quickGames.filter(\.isInstalled) }
    private var highlights: [LibraryGame] {
        Array((ready + model.quickGames.filter { !$0.isInstalled }).prefix(3))
    }
    private var featured: LibraryGame? { highlights.first { $0.id == featuredID } ?? highlights.first }

    private var accent: Color { featured.map(GameIdentity.accent) ?? WayfarerTheme.accent }
    private var discoveryCandidates: [LibraryGame] {
        let otherGames = model.visibleLibrary.filter { game in !highlights.contains { $0.id == game.id } }
        return otherGames.isEmpty ? model.visibleLibrary : otherGames
    }
    private var discovery: LibraryGame? { discoveryCandidates.first { $0.id == discoveryID } ?? discoveryCandidates.first }
    private var spotlightIndex: Int { highlights.firstIndex { $0.id == featured?.id } ?? 0 }

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
                                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(featured?.id == game.id ? GameIdentity.accent(game).opacity(0.4) : Color.white.opacity(0.055), lineWidth: 1))
                            }.buttonStyle(.plain).help("Feature \(game.name)")
                                .accessibilityAddTraits(featured?.id == game.id ? .isSelected : [])
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                discoveryPanel
                couchPanel
            }.frame(height: 132)
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
        }.onAppear { if discoveryID == nil { chooseDiscovery() } }
        .onChange(of: model.visibleLibrary.map(\.id)) { _ in
            if !discoveryCandidates.contains(where: { $0.id == discoveryID }) { chooseDiscovery() }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WayfarerHomePreview"))) { note in
            guard ProcessInfo.processInfo.arguments.contains("--feature-preview"), let command = note.object as? String else { return }
            switch command {
            case "spotlight-next": stepSpotlight(1)
            case "spotlight-prev": stepSpotlight(-1)
            case "discovery-shuffle": chooseDiscovery()
            case "discovery-open": if let game = discovery { model.showGame(game) }
            default: break
            }
        }
        #endif
    }

    private var hero: some View {
        GeometryReader { geometry in
            let coverWidth: CGFloat = geometry.size.width > 900 ? 158 : 112
            ZStack(alignment: .leading) {
                if let game = featured {
                    GameArtwork(game: game, wide: true).id(game.id).transition(.opacity)
                } else {
                    LinearGradient(colors: [WayfarerTheme.violet.opacity(0.3), WayfarerTheme.accent.opacity(0.18), WayfarerTheme.surface], startPoint: .topTrailing, endPoint: .bottomLeading)
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.86), location: 0), .init(color: .black.opacity(0.56), location: 0.5), .init(color: .black.opacity(0.12), location: 1)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                RadialGradient(colors: [accent.opacity(0.24), .clear], center: .trailing, startRadius: 10, endRadius: 420)
                if let game = featured {
                    GameArtwork(game: game)
                        .frame(width: coverWidth, height: coverWidth * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.24), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 18, y: 14)
                        .shadow(color: accent.opacity(0.25), radius: 30)
                        .rotationEffect(.degrees(5))
                        .padding(.trailing, 32).padding(.top, 35)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Eyebrow(title: "Your spotlight", color: .white.opacity(0.85))
                        Spacer()
                        if highlights.count > 1 {
                            Text(String(format: "%02d / %02d", spotlightIndex + 1, highlights.count))
                                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.65)).padding(.trailing, 5)
                            Button { stepSpotlight(-1) } label: { Image(systemName: "chevron.left").frame(width: 8, height: 12) }.buttonStyle(QuietButtonStyle()).help("Previous featured game").accessibilityLabel("Previous featured game")
                            Button { stepSpotlight(1) } label: { Image(systemName: "chevron.right").frame(width: 8, height: 12) }.buttonStyle(QuietButtonStyle()).help("Next featured game").accessibilityLabel("Next featured game")
                        }
                    }
                    Spacer(minLength: 20)
                    Text(featured?.name ?? "Every world.\nOne place to play.")
                        .font(.system(size: 40, weight: .bold)).tracking(-1.2).lineLimit(2).minimumScaleFactor(0.8)
                        .frame(maxWidth: min(570, geometry.size.width - coverWidth - 100), alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    if let game = featured {
                        HStack(spacing: 7) {
                            ForEach(game.platforms, id: \.self) { PlatformBadge(platform: $0) }
                            Text(game.isInstalled ? "Ready to play" : "In your collection").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                        }.padding(.top, 13)
                        HStack(spacing: 10) {
                            Button { model.launch(game, platform: model.quickPlatform(game) ?? model.preferredGamePlatform(game)) } label: {
                                Label(model.activeSession(game.id) != nil ? "Return to game" : game.isInstalled ? "Play now" : "Install game", systemImage: game.isInstalled ? "play.fill" : "arrow.down.to.line")
                            }.buttonStyle(PlayButtonStyle())
                                .disabled(model.installing || model.installationDisabled(game, platform: model.quickPlatform(game) ?? model.preferredGamePlatform(game) ?? .macOS))
                            Button { model.showGame(game) } label: { Label("Game details", systemImage: "arrow.up.right") }.buttonStyle(QuietButtonStyle())
                            Button { model.toggleFavorite(game) } label: { Image(systemName: model.favorites.contains(game.id) ? "heart.fill" : "heart") }
                                .buttonStyle(QuietButtonStyle()).help("Favorite \(game.name)").accessibilityLabel(model.favorites.contains(game.id) ? "Remove \(game.name) from favorites" : "Favorite \(game.name)")
                        }.padding(.top, 22)
                    } else {
                        Text("Your Mac favorites and Windows adventures, together.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).padding(.top, 13)
                        Button(action: addGame) { Label("Add your first game", systemImage: "plus") }.buttonStyle(PlayButtonStyle()).padding(.top, 22)
                    }
                }.padding(30)
            }
        }.frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(LinearGradient(colors: [accent.opacity(0.45), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: accent.opacity(0.11), radius: 24, y: 10)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: featured?.id)
    }

    private func stepSpotlight(_ offset: Int) {
        guard !highlights.isEmpty else { return }
        featuredID = highlights[(spotlightIndex + offset + highlights.count) % highlights.count].id
    }

    private func chooseDiscovery() {
        let candidates = discoveryCandidates.filter { $0.id != discovery?.id }
        discoveryID = (candidates.randomElement() ?? discoveryCandidates.first)?.id
    }

    private var discoveryPanel: some View {
        ZStack(alignment: .leading) {
            if let game = discovery { GameArtwork(game: game, wide: true).id(game.id).transition(.opacity) }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 9) {
                Eyebrow(title: "Something different", color: WayfarerTheme.amber)
                HStack {
                    Text("Surprise me").font(.system(size: 22, weight: .bold)).tracking(-0.5)
                    Spacer()
                    Button { chooseDiscovery() } label: { Image(systemName: "shuffle").font(.system(size: 14)).frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Choose another game").accessibilityLabel("Choose another game").disabled(discoveryCandidates.count < 2)
                }
                if let game = discovery {
                    Button { model.showGame(game) } label: {
                        HStack(spacing: 8) { Text(game.name).lineLimit(1); Spacer(minLength: 0); Image(systemName: "arrow.up.right") }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    }.buttonStyle(.plain).help("Explore \(game.name)")
                } else {
                    Button("Explore your library", action: browse).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: discovery?.id)
    }

    private var couchPanel: some View {
        Button { model.showingCouch = true } label: {
            ZStack(alignment: .leading) {
                LinearGradient(colors: [WayfarerTheme.violet.opacity(0.19), WayfarerTheme.surface.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "gamecontroller.fill").font(.system(size: 82)).rotationEffect(.degrees(-15))
                    .foregroundStyle(WayfarerTheme.violet.opacity(0.12)).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 24)
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(title: "Make yourself comfortable", color: WayfarerTheme.violet)
                    Text("Take the big screen.").font(.system(size: 22, weight: .bold)).tracking(-0.5)
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("Controller fullscreen")
                        Text("⌘⇧F").foregroundStyle(.white.opacity(0.4))
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }.padding(20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(WayfarerTheme.violet.opacity(0.2), lineWidth: 1))
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

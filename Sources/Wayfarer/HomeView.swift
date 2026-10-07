import SwiftUI
import AppKit
import WayfarerCore

struct HomeView: View {
    @ObservedObject var model: LauncherModel
    let addGame: () -> Void
    let browse: () -> Void
    let engines: () -> Void
    var body: some View {
        let visible = model.visibleLibrary
        let quick = model.quickGames
        let ready = quick.filter(\.isInstalled)
        let highlights = Array((ready + quick.filter { !$0.isInstalled }).prefix(3))
        let highlightedIDs = Set(highlights.map(\.id))
        let otherGames = visible.filter { !highlightedIDs.contains($0.id) }
        HomeContent(model: model, addGame: addGame, browse: browse, engines: engines,
                    visibleGames: visible, quickGames: quick, ready: ready, highlights: highlights,
                    discoveryCandidates: otherGames.isEmpty ? visible : otherGames, refreshing: model.refreshing,
                    selectedProfile: model.selectedProfile, hasSteam: model.steamExecutable != nil, favorites: model.favorites)
    }
}

#if DEBUG
// Use real mouse events to catch obstructed or undersized hit areas.
@MainActor
private final class HomeControlsProbe: ObservableObject {
    enum Target { case shuffle, details }
    weak var shuffle: NSView?
    weak var details: NSView?
    var displayedPick: String?
    private var started = false
    func start(output: URL, model: LauncherModel) {
        guard !started else { return }; started = true
        Task {
            do {
                for _ in 0..<30 {
                    if let window = shuffle?.window, shuffle?.bounds.width ?? 0 > 1 {
                        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try await Task.sleep(for: .milliseconds(400))
                var changed = 0, clicks = 0
                for _ in 0..<4 {
                    let before = displayedPick
                    if click(shuffle) { clicks += 1 }
                    try await Task.sleep(for: .milliseconds(350))
                    if displayedPick != before { changed += 1 }
                }
                let picked = displayedPick, opened = click(details)
                try await Task.sleep(for: .milliseconds(500))
                let result: [String: Any] = ["pickClicks": clicks, "visiblePickChanges": changed,
                    "detailsClick": opened, "selectedPickedGame": picked != nil && model.selectedGameID == picked,
                    "openedLibrary": model.navigationDestination == "Library", "homeRemoved": shuffle?.window == nil]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try await FileService.shared.write(data, to: output)
            } catch { }
        }
    }
    private func click(_ view: NSView?) -> Bool {
        guard let view, let window = view.window, view.bounds.width > 1, view.bounds.height > 1 else { return false }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }
}
private struct HomeProbeTarget: NSViewRepresentable {
    let probe: HomeControlsProbe
    let pick: String?
    let kind: HomeControlsProbe.Target
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSView { let view = PassThroughView(); updateNSView(view, context: context); return view }
    func updateNSView(_ view: NSView, context: Context) {
        if kind == .shuffle { probe.shuffle = view; probe.displayedPick = pick }
        else { probe.details = view }
    }
}
#endif

private struct HomeContent: View {
    let model: LauncherModel
    let addGame: () -> Void
    let browse: () -> Void
    let engines: () -> Void
    let visibleGames: [LibraryGame]
    let quickGames: [LibraryGame]
    let ready: [LibraryGame]
    let highlights: [LibraryGame]
    let discoveryCandidates: [LibraryGame]
    let refreshing: Bool
    let selectedProfile: RuntimeProfile?
    let hasSteam: Bool
    let favorites: Set<String>
    @WayfarerState private var featuredID: String?
    @WayfarerState private var discoveryID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @StateObject private var controlsProbe = HomeControlsProbe()
    #endif
    private var featured: LibraryGame? { highlights.first { $0.id == featuredID } ?? highlights.first }

    private var accent: Color { featured.map(GameIdentity.accent) ?? WayfarerTheme.accent }
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
                                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(featured?.id == game.id ? GameIdentity.accent(game).opacity(0.4) : Color.white.opacity(0.055), lineWidth: 1).allowsHitTesting(false))
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
            } else if !visibleGames.isEmpty {
                LibrarySectionTitle(title: "Find your next adventure", subtitle: "Install a game from your collection to get started.")
                GameShelf(model: model, games: Array(quickGames.prefix(5)))
            }
            if !refreshing && (selectedProfile == nil || !hasSteam) {
                HStack(spacing: 17) {
                    Image(systemName: "cpu").font(.system(size: 22)).foregroundStyle(WayfarerTheme.violet)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Bring your Windows games along").font(.system(size: 13, weight: .semibold))
                        Text(selectedProfile == nil ? "Connect CrossOver, Wine, or GPTK to get started." : "Set up Wayfarer's Windows Steam and sign in.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(selectedProfile == nil ? "Choose engine" : "Set up Steam") {
                        if selectedProfile == nil { engines() } else { model.installSteam() }
                    }.buttonStyle(QuietButtonStyle()).disabled(model.installing)
                }.padding(20).glassPanel(radius: 17)
            }
        }.onAppear { if discoveryID == nil { chooseDiscovery() } }
        .onChange(of: visibleGames.map(\.id)) { _ in
            if !discoveryCandidates.contains(where: { $0.id == discoveryID }) { chooseDiscovery() }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WayfarerHomePreview"))) { note in
            guard ProcessInfo.processInfo.arguments.contains("--feature-preview"), let command = note.object as? String else { return }
            switch command {
            case "spotlight-next": stepSpotlight(1)
            case "spotlight-prev": stepSpotlight(-1)
            case "discovery-shuffle": chooseDiscovery()
            case "discovery-open": openDiscovery()
            default: break
            }
        }
        .task(id: discoveryCandidates.map(\.id)) {
            if discoveryCandidates.count > 1,
               let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--home-controls-probe=") }) {
                controlsProbe.start(output: URL(fileURLWithPath: String(flag.dropFirst("--home-controls-probe=".count))), model: model)
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
                    Text(featured?.name ?? (refreshing ? "Finding your\nnext adventure…" : "Every world.\nOne place to play."))
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
                            Button { model.toggleFavorite(game) } label: { Image(systemName: favorites.contains(game.id) ? "heart.fill" : "heart") }
                                .buttonStyle(QuietButtonStyle()).help("Favorite \(game.name)").accessibilityLabel(favorites.contains(game.id) ? "Remove \(game.name) from favorites" : "Favorite \(game.name)")
                        }.padding(.top, 22)
                    } else {
                        Text(refreshing ? "Your games will appear as your library loads." : "Your Mac favorites and Windows adventures, together.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).padding(.top, 13)
                        if !refreshing { Button(action: addGame) { Label("Add your first game", systemImage: "plus") }.buttonStyle(PlayButtonStyle()).padding(.top, 22) }
                    }
                }.padding(30)
            }
        }.frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(LinearGradient(colors: [accent.opacity(0.45), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1).allowsHitTesting(false))
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

    private func openDiscovery() {
        guard let game = discovery else { return }
        model.navigate("Library")
        model.showGame(game)
    }

    private var discoveryPanel: some View {
        ZStack(alignment: .leading) {
            if let game = discovery { GameArtwork(game: game, wide: true).id(game.id).transition(.opacity).allowsHitTesting(false) }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing).allowsHitTesting(false)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(title: "Something different", color: WayfarerTheme.amber)
                    Text("Surprise me").font(.system(size: 22, weight: .bold)).tracking(-0.5)
                    Text(discovery?.name ?? (refreshing ? "Loading your library…" : "Browse your collection to get started."))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    Button(action: chooseDiscovery) {
                        Text("Pick another").frame(minWidth: 78, minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle()).help("Choose a different game").disabled(discoveryCandidates.count < 2)
                    #if DEBUG
                    .background(HomeProbeTarget(probe: controlsProbe, pick: discovery?.id, kind: .shuffle).allowsHitTesting(false))
                    #endif
                    Button { if discovery != nil { openDiscovery() } else { browse() } } label: {
                        Text(discovery == nil ? "Browse library" : "View game").frame(minWidth: 78, minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle()).foregroundStyle(WayfarerTheme.accent).disabled(discovery == nil && refreshing)
                        .help(discovery.map { "View \($0.name)" } ?? "View game details")
                    #if DEBUG
                    .background(HomeProbeTarget(probe: controlsProbe, pick: discovery?.id, kind: .details).allowsHitTesting(false))
                    #endif
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
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
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(WayfarerTheme.violet.opacity(0.2), lineWidth: 1).allowsHitTesting(false))
                .contentShape(RoundedRectangle(cornerRadius: 18))
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

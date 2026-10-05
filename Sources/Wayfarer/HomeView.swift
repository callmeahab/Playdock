import SwiftUI
import WayfarerCore

struct HomeView: View {
    @ObservedObject var model: LauncherModel
    let addGame: () -> Void
    let browse: () -> Void
    let engines: () -> Void
    private var recent: [LibraryGame] {
        model.library.sorted { $0.lastPlayed == $1.lastPlayed ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.lastPlayed > $1.lastPlayed }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            hero
            HStack(spacing: 12) {
                metric(model.library.count, label: "In your library", icon: "square.grid.2x2")
                metric(model.library.filter { $0.platforms.contains(.macOS) }.count, label: "Mac games", icon: "apple.logo")
                metric(model.library.filter { $0.platforms.contains(.windows) }.count, label: "Windows games", icon: "square.grid.2x2.fill")
            }
            if !recent.isEmpty {
                HStack {
                    LibrarySectionTitle(title: "Made for your downtime", subtitle: "Installed games, all in one place")
                    Spacer()
                    Button(action: browse) { Label("View library", systemImage: "arrow.right") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(WayfarerTheme.accent)
                }
                GameShelf(model: model, games: Array(recent.prefix(6)))
            }
            if model.selectedProfile == nil || model.steamExecutable == nil {
                HStack(spacing: 17) {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 21)).foregroundStyle(WayfarerTheme.accent)
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
            if let game = recent.first { GameArtwork(game: game, wide: true) }
            else {
                LinearGradient(colors: [Color(red: 0.12, green: 0.25, blue: 0.28), WayfarerTheme.surface], startPoint: .topTrailing, endPoint: .bottomLeading)
                Image(systemName: "gamecontroller.fill").font(.system(size: 170, weight: .ultraLight)).foregroundStyle(WayfarerTheme.accent.opacity(0.13))
                    .rotationEffect(.degrees(-13)).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 45)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.6), location: 0.5), .init(color: .black.opacity(0.13), location: 1)], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 7) {
                    Circle().fill(WayfarerTheme.accent).frame(width: 5, height: 5)
                    Text(recent.isEmpty ? "A HOME FOR YOUR GAMES" : "IN YOUR LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.75))
                }
                Text(recent.first?.name ?? "One library.\nEvery world.").font(.system(size: 35, weight: .semibold)).tracking(-0.8)
                    .lineLimit(2).frame(maxWidth: 470, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let game = recent.first {
                    HStack(spacing: 6) { ForEach(game.platforms, id: \.self) { PlatformBadge(platform: $0) } }
                    HStack(spacing: 10) {
                        Button { model.launch(game) } label: { Label(game.preferredPlatform.flatMap { game.installation(for:$0) } != nil ? "Play now" : "Install", systemImage: game.preferredPlatform.flatMap { game.installation(for:$0) } != nil ? "play.fill" : "arrow.down.to.line") }.buttonStyle(PlayButtonStyle()).disabled(model.activeLaunches.values.contains(game.name))
                        Button("Explore library", action: browse).buttonStyle(QuietButtonStyle())
                    }.padding(.top, 3)
                } else {
                    Text("Mac favorites. Windows adventures. All together.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                    Button(action: addGame) { Label("Add your first game", systemImage: "plus") }.buttonStyle(PlayButtonStyle()).padding(.top, 3)
                }
            }.padding(32)
        }.frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func metric(_ value: Int, label: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(WayfarerTheme.accent.opacity(0.8)).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(value)").font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 15)
    }
}

import SwiftUI
import WayfarerCore

private enum LibraryFilter: String, CaseIterable {
    case all = "All games", mac = "Mac", windows = "Windows"
    var platform: GamePlatform? {
        switch self { case .all: return nil; case .mac: return .macOS; case .windows: return .windows }
    }
}
private enum InstallationFilter: String, CaseIterable { case all = "All", installed = "Installed", available = "Ready to install" }
private enum LibrarySort: String, CaseIterable { case name = "Name", recent = "Recently played" }

struct LibraryView: View {
    @ObservedObject var model: LauncherModel
    let favoritesOnly: Bool
    let addGame: () -> Void
    let browse: () -> Void
    @WayfarerState private var search = ""
    @WayfarerState private var filter: LibraryFilter = .all
    @WayfarerState private var sort: LibrarySort = .name
    @WayfarerState private var installationFilter: InstallationFilter = .all
    private var games: [LibraryGame] {
        let result = model.library.filter {
            (!favoritesOnly || model.favorites.contains($0.id)) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
            (filter.platform == nil || $0.platforms.contains(filter.platform!)) &&
            (installationFilter == .all || (installationFilter == .installed ? (filter.platform == nil ? $0.isInstalled : $0.installation(for: filter.platform!) != nil) : (filter.platform == nil ? !$0.isInstalled : $0.installation(for: filter.platform!) == nil)))
        }
        return sort == .recent ? result.sorted { $0.lastPlayed == $1.lastPlayed ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.lastPlayed > $1.lastPlayed } : result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search your games", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search") }
                }.font(.system(size: 12)).padding(12).frame(maxWidth: 320).glassPanel(radius: 11)
                Spacer()
                Menu {
                    Button("Windows Steam") { model.loadSteamLibrary(.windows) }
                    if model.includesMacSteam { Button("Mac Steam") { model.loadSteamLibrary(.macOS) } }
                } label: { Label("Refresh Steam library", systemImage: "arrow.clockwise") }
                .disabled(model.loadingCatalog)
                Picker("Sort games", selection: $sort) { ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 155)
            }
            HStack(spacing: 5) {
                ForEach(LibraryFilter.allCases, id: \.self) { choice in
                    Button { filter = choice } label: {
                        HStack(spacing: 6) {
                            if let platform = choice.platform { Image(systemName: platform == .macOS ? "apple.logo" : "square.grid.2x2.fill").font(.system(size: 10)) }
                            Text(choice.rawValue).font(.system(size: 11, weight: .medium))
                        }.padding(.horizontal, 15).padding(.vertical, 8)
                            .foregroundStyle(filter == choice ? Color.white : Color.secondary)
                            .background(.white.opacity(filter == choice ? 0.1 : 0), in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("\(games.count) \(games.count == 1 ? "game" : "games")").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Picker("Installation", selection: $installationFilter) {
                    ForEach(InstallationFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
                HStack(spacing: 8) {
                    if model.loadingCatalog { ProgressView().controlSize(.small) }
                    Text(model.catalogMessage).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if games.isEmpty { emptyState }
            else { GameShelf(model: model, games: games, preferredPlatform: filter.platform) }
            ForEach(model.libraryWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 14)
            }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: favoritesOnly ? "heart" : "gamecontroller").font(.system(size: 38, weight: .light)).foregroundStyle(WayfarerTheme.accent.opacity(0.8))
            Text(search.isEmpty && filter == .all ? (favoritesOnly ? "Your favorites live here" : "Make room for play") : "No games found").font(.system(size: 20, weight: .medium))
            Text(!search.isEmpty || (filter != .all || installationFilter != .all) ? "Try another name or platform." : favoritesOnly ? "Tap the heart on any game to keep it close." : "Add a Mac app or a Windows game. Installed Mac Steam games appear automatically.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
            if !search.isEmpty || (filter != .all || installationFilter != .all) { Button("Clear filters") { search = ""; filter = .all; installationFilter = .all }.buttonStyle(QuietButtonStyle()) }
            else { Button(favoritesOnly ? "Browse library" : "Add game", action: favoritesOnly ? browse : addGame).buttonStyle(QuietButtonStyle()).padding(.top, 5) }
        }.frame(maxWidth: .infinity).padding(.vertical, 65)
    }
}

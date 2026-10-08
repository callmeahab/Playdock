import SwiftUI
import PlaydockCore

private enum InstallationFilter: String, CaseIterable { case all = "All", installed = "Installed", available = "Ready to install" }
private enum LibrarySort: String, CaseIterable { case name = "Name", recent = "Recently played" }

struct LibraryView: View {
    @ObservedObject var model: LauncherModel
    let favoritesOnly: Bool
    let addGame: () -> Void
    let browse: () -> Void
    @State private var collectionID="all"
    @State private var showHidden=false
    @State private var search = ""
    @State private var sort: LibrarySort = .name
    @State private var installationFilter: InstallationFilter = .all
    private var games: [LibraryGame] {
        let result = model.library.filter {
            (showHidden ? model.preferences(for:$0).hidden : !model.preferences(for:$0).hidden) &&
            (collectionID == "all" || model.inCollection($0,id:collectionID)) &&
            (!favoritesOnly || model.favorites.contains($0.id)) &&
            (search.isEmpty || ($0.name.localizedCaseInsensitiveContains(search) || model.preferences(for:$0).tags.contains{$0.localizedCaseInsensitiveContains(search)})) &&
            (installationFilter == .all || (installationFilter == .installed ? model.executionInstalled($0) : !model.executionInstalled($0)))
        }
        return sort == .recent ? result.sorted { $0.lastPlayed == $1.lastPlayed ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.lastPlayed > $1.lastPlayed } : result
    }
    private var hasFilters: Bool { !search.isEmpty || installationFilter != .all || collectionID != "all" || showHidden }
    var body: some View {
        let games = self.games
        return VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search games or tags", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(ControllerButtonStyle(style: .plain)).foregroundStyle(.secondary).help("Clear search") }
                    }.font(.system(size: 12)).padding(11).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    Menu {
                        Picker("Collection", selection: $collectionID) {
                            Text("All collections").tag("all")
                            ForEach(model.collections) { Text($0.name).tag($0.id) }
                        }
                        Divider()
                        Button("Manage collections…") { model.showingCollections = true }
                    } label: {
                        Label(model.collections.first { $0.id == collectionID }?.name ?? "All collections", systemImage: "folder")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }.menuStyle(.borderlessButton).frame(width: 150).help("Choose a collection")
                    Menu {
                        Picker("Sort games", selection: $sort) { ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Toggle("Show hidden games only", isOn: $showHidden)
                        Divider()
                        Button("Refresh Steam library") { model.loadSteamLibrary(.windows) }.disabled(model.loadingCatalog)
                        Button("Refresh installed games") { model.refresh() }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium)).frame(width: 22) }
                        .menuStyle(.borderlessButton).fixedSize().help("Sort, hidden games & refresh").accessibilityLabel("Library options")
                }
                HStack(spacing: 4) {
                    ForEach(InstallationFilter.allCases, id: \.self) { choice in
                        Button { installationFilter = choice } label: {
                            Text(choice.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .foregroundStyle(installationFilter == choice ? PlaydockTheme.accent : Color.secondary)
                                .background(installationFilter == choice ? PlaydockTheme.accent.opacity(0.12) : .white.opacity(0.035), in: Capsule())
                                .overlay(Capsule().strokeBorder(installationFilter == choice ? PlaydockTheme.accent.opacity(0.45) : .white.opacity(0.06), lineWidth: 1))
                        }
                        .buttonStyle(ControllerButtonStyle(style: .plain))
                        .accessibilityAddTraits(installationFilter == choice ? .isSelected : [])
                    }
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 14).padding(.horizontal, 10)
                    Text("\(games.count) \(games.count == 1 ? "game" : "games")").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                }
            }.padding(16).glassPanel(radius: 17)
            if showHidden { Label("Showing hidden games", systemImage: "eye.slash").font(.system(size: 11)).foregroundStyle(PlaydockTheme.amber) }
            if !model.catalogMessage.isEmpty {
                HStack(spacing: 8) {
                    if model.loadingCatalog { ProgressView().controlSize(.small) }
                    Text(model.catalogMessage).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if games.isEmpty, model.refreshing || model.loadingCatalog {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.refreshing ? "Finding your games…" : "Loading your Steam library…").font(.system(size: 16, weight: .medium))
                    Text("Games will appear here as they’re found.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 65)
            }
            else if games.isEmpty { emptyState }
            else { GameShelf(model: model, games: games) }
            ForEach(model.libraryWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 14)
            }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: favoritesOnly ? "heart" : "gamecontroller").font(.system(size: 38, weight: .light)).foregroundStyle(PlaydockTheme.accent.opacity(0.8))
            Text(!hasFilters ? (favoritesOnly ? "Your favorites live here" : "Make room for play") : "No games found").font(.system(size: 20, weight: .medium))
            Text(hasFilters ? "Try another name, installation status, or collection." : favoritesOnly ? "Tap the heart on any game to keep it close." : "Add a Mac app or a Windows game. Installed Mac Steam games appear automatically.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
            if hasFilters { Button("Clear filters") { search = ""; installationFilter = .all; collectionID = "all"; showHidden = false }.buttonStyle(QuietButtonStyle()) }
            else { Button(favoritesOnly ? "Browse library" : "Add game", action: favoritesOnly ? browse : addGame).buttonStyle(QuietButtonStyle()).padding(.top, 5) }
        }.frame(maxWidth: .infinity).padding(.vertical, 65)
    }
}

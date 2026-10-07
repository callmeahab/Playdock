import SwiftUI
import AppKit
import WayfarerCore

enum AppPage: String, CaseIterable, Identifiable {
    case home = "Home", library = "Library", favorites = "Favorites", downloads = "Downloads", chat = "Chat", steam = "Steam & account", runtimes = "Engines", sessions = "Activity", storage = "Storage", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .settings: return "gearshape.fill"
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .favorites: return "heart.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .steam: return "play.rectangle.fill"
        case .runtimes: return "cpu"
        case .storage: return "externaldrive.fill"
        case .sessions: return "clock.arrow.circlepath"
        }
    }
    var subtitle: String {
        switch self {
        case .settings: return "Library preferences and tools."
        case .home: return "Your Mac and Windows games, together."
        case .library: return "One collection. Every place you play."
        case .favorites: return "Keep your next adventure close."
        case .steam: return "Steam login and account settings."
        case .downloads: return "Steam handles updates. Wayfarer keeps you in the loop."
        case .chat: return "Your friends and conversations, through Steam."
        case .runtimes: return "Choose how your Windows games run."
        case .storage: return "Your libraries, game files, and available space."
        case .sessions: return "Your launches and session history."
        }
    }
}

struct AppWorkspace: View {
    @ObservedObject var model: LauncherModel
    @Binding var page: AppPage
    let addGame: () -> Void
    let addProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.refreshing { LibraryLoadingStatus(model: model).padding(.horizontal, 28).padding(.bottom, 20) }
            if let title = model.pendingGameTitle, model.gameSessions.allSatisfy({ !$0.phase.active }) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Opening \(title)…").font(.system(size: 12, weight: .medium))
                        Text("Steam may need you to sign in or finish an update.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("View Steam session") { model.showWindowsSession() }.buttonStyle(QuietButtonStyle())
                }.padding(16).glassPanel(radius: 14).padding(.horizontal, 28).padding(.bottom, 20)
            }
            if let window = model.nativeGameWindows.first, model.gameSessions.allSatisfy({ !$0.phase.active }) {
                HStack(spacing: 12) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(window.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button("Return to game") { model.session.activateNativeWindow(window.id) }.buttonStyle(QuietButtonStyle())
                }.padding(16).glassPanel(radius: 14).padding(.horizontal, 28).padding(.bottom, 20)
            }
            if page == .steam {
                SessionView(model: model, session: model.session).padding([.horizontal, .bottom], 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if model.missingSelection {
                            Label("Your Windows environment is unavailable. Choose an engine to restore it; Mac games can still play.", systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.secondary).padding(18).glassPanel(radius: 14)
                        }
                        if let game = model.selectedGame, [.home, .library, .favorites].contains(page) {
                            GameDetailView(model: model, game: game) { model.selectedGameID = nil }
                        } else {
                            switch page {
                            case .home: HomeView(model: model, addGame: addGame, browse: { page = .library }, engines: { page = .runtimes })
                            case .library, .favorites: LibraryView(model: model, favoritesOnly: page == .favorites, addGame: addGame, browse: { page = .library })
                            case .runtimes: EnginesView(model: model, addProfile: addProfile)
                            case .downloads: DownloadsView(model: model)
                            case .chat: ChatView(model: model)
                            case .sessions: GameActivityView(model: model)
                            case .storage: StorageManagerView(model: model)
                            case .settings: AppSettingsView(model: model, addGame: addGame, addProfile: addProfile)
                            case .steam: EmptyView()
                            }
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading)
                }.id(page)
            }
        }
    }
}

struct LibraryLoadingStatus: View {
    @ObservedObject var model: LauncherModel
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.refreshing ? model.libraryLoadingMessage : model.loadingCatalog ? model.catalogMessage : "Connecting to Steam…")
                    .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("\(model.library.count) games available").monospacedDigit()
                    Text("·")
                    Text(model.refreshing ? "Games appear as they’re found." : "Your library is ready to browse.")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if !model.connectionBusy.isEmpty {
                    Text(GamePlatform.allCases.filter { model.connectionBusy.contains($0) }.map { model.connectionMessages[$0] ?? "Connecting \($0.name) Steam…" }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }.padding(16).glassPanel(radius: 14).accessibilityElement(children: .combine)
    }

}

struct EnginesView: View {
    @ObservedObject var model: LauncherModel
    let addProfile: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Wayfarer finds Steam in your CrossOver bottles and uses its installed games. Automatic prefers an existing Steam installation; you can also choose a separate Wayfarer environment.")
                .foregroundStyle(.secondary)
            HStack {
                Picker("Compatibility engine", selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
                    Text("Automatic").tag("automatic")
                    if model.missingSelection { Text("Saved environment unavailable").tag(model.selection) }
                    ForEach(model.profiles) { profile in Text("\(profile.runtime.name) / \(profile.name)\(profile.reusesExistingSteam ? " · Existing Steam" : "")").tag(profile.id) }
                }.frame(maxWidth: 540)
                Button("Add runtime…") { addProfile() }
            }
            if let profile = model.selectedProfile {
                VStack(alignment: .leading, spacing: 14) {
                    Label(profile.runtime.name, systemImage: "shippingbox.fill").font(.title3)
                    pathRow("Runtime", profile.runtime.executable.path)
                    pathRow(profile.runtime.kind == .crossOver ? "Bottle" : "Prefix", profile.prefix.path)
                    if profile.reusesExistingSteam {
                        Label("Uses your existing Steam installation and games", systemImage:"checkmark.circle").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    pathRow("Steam", model.steamExecutable?.path ?? "Not installed")
                    HStack {
                        Button(model.steamExecutable == nil ? "Set up Steam and sign in" : "Open Steam") { model.launchSteam() }.disabled(model.installing)
                        Button("Run installer…") { model.runInstaller() }
                    }
                    if profile.runtime.kind == .crossOver && !profile.reusesExistingSteam {
                        Text("This is Wayfarer’s separate Windows environment. Choose an existing Steam bottle above to reuse its login and games.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if profile.runtime.kind == .gptk {
                        Text("Use a fully installed GPTK evaluation environment, including its graphics libraries and Rosetta. Apple's shader tools alone cannot launch Windows games.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.configuration.customProfiles.contains(where: { $0.runtime.id == profile.runtime.id }) {
                        Button("Forget custom runtime") { model.forgetCustomProfile(profile) }
                        Text("The prefix and its installed files stay on disk.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(22).glassPanel(radius: 20)
            }
            if model.installing { ProgressView(model.setupMessage) }
            Text("INSTALLED RUNTIMES").font(.caption).tracking(1.5).foregroundStyle(.secondary)
            ForEach(model.runtimes) { runtime in
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(runtime.name).font(.headline)
                        Text(runtime.executable.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Open") { model.openRuntime(runtime) }
                }.padding(18).glassPanel(radius: 14)
            }
            HStack {
                ForEach(RuntimeKind.allCases, id: \.self) { kind in Link("Get \(kind.name)", destination: kind.setupURL) }
            }
            Text("Runtime installations and game compatibility are managed by their providers. On Apple silicon, x86 Windows software may also need Rosetta.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }

}

struct AppSettingsView: View {
    @ObservedObject var model: LauncherModel
    let addGame: () -> Void
    let addProfile: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Library").font(.title2.weight(.semibold))
                Toggle("Start Steam in the background", isOn: Binding(get: { model.startsSteamInBackground }, set: { model.startsSteamInBackground = $0 }))
                Toggle("Show Mac Steam games", isOn: Binding(get: { model.includesMacSteam }, set: { model.includesMacSteam = $0 }))
                HStack(spacing: 12) {
                    Button("Add game…", action: addGame)
                    Button("Collections & folders…") { model.showingCollections = true }.couchControl("Collections & folders…")
                    Button("Refresh library") { model.refresh() }.disabled(model.refreshing)
                }.buttonStyle(QuietButtonStyle())
            }.padding(24).glassPanel(radius: 20)
            VStack(alignment: .leading, spacing: 18) {
                Text("Steam connections").font(.title2.weight(.semibold))
                SteamConnectionControls(model: model)
                HStack(spacing: 12) {
                    Button("Engines") { model.navigate("Engines") }
                    Button("Add runtime…", action: addProfile)
                    Button("Manage Windows apps…") { model.manageWindowsApps() }.disabled(model.selectedProfile == nil)
                }.buttonStyle(QuietButtonStyle())
            }.padding(24).glassPanel(radius: 20)
            VStack(alignment: .leading, spacing: 18) {
                Text("Tools").font(.title2.weight(.semibold))
                HStack(spacing: 12) {
                    Button("Storage manager") { model.navigate("Storage") }
                    Button("Launch diagnostics…") { model.showingDiagnostics = true }.couchControl("Launch diagnostics…")
                    Button("Open session logs") { model.openLogs() }
                }.buttonStyle(QuietButtonStyle())
            }.padding(24).glassPanel(radius: 20)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

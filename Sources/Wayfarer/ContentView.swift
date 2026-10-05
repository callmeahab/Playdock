import SwiftUI
import AppKit
import WayfarerCore

private enum Page: String, Identifiable {
    case home = "Home", library = "Library", favorites = "Favorites", downloads = "Downloads", chat = "Chat", steam = "Steam & account", runtimes = "Engines", sessions = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .favorites: return "heart.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .steam: return "play.rectangle.fill"
        case .runtimes: return "cpu"
        case .sessions: return "clock.arrow.circlepath"
        }
    }
    var subtitle: String {
        switch self {
        case .home: return "Your Mac and Windows games, together."
        case .library: return "One collection. Every place you play."
        case .favorites: return "Keep your next adventure close."
        case .steam: return "Steam login and account settings."
        case .downloads: return "Steam handles updates. Wayfarer keeps you in the loop."
        case .chat: return "Your friends and conversations, through Steam."
        case .runtimes: return "Choose how your Windows games run."
        case .sessions: return "Your launches and session history."
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: LauncherModel
    @WayfarerState private var page: Page = .home
    @WayfarerState private var addingGame = false
    @WayfarerState private var addingProfile = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                if let title = model.pendingGameTitle {
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
                if let window = model.nativeGameWindows.first {
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
                                notice("Your Windows environment is unavailable. Choose an engine to restore it; Mac games can still play.", symbol: "exclamationmark.triangle")
                            }
                            if let game = model.selectedGame, [.home, .library, .favorites].contains(page) {
                                GameDetailView(model: model, game: game) { model.selectedGameID = nil; page = .library }
                            } else { switch page {
                            case .home:
                                HomeView(model: model, addGame: { addingGame = true }, browse: { page = .library }, engines: { page = .runtimes })
                            case .library, .favorites:
                                LibraryView(model: model, favoritesOnly: page == .favorites, addGame: { addingGame = true }, browse: { page = .library })
                            case .runtimes: runtimes
                            case .downloads: DownloadsView(model: model)
                            case .chat: ChatView(model: model)
                            case .sessions: sessions
                            case .steam: EmptyView()
                            } }
                        }.padding(.horizontal, 28).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.background(WayfarerTheme.background.opacity(reduceTransparency ? 1 : 0.83))
        }
        .background(WindowMaterial(material: .underWindowBackground).allowsHitTesting(false))
        .background(WindowAppearance().allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $addingGame) { AddGameView(model: model) }
        .sheet(isPresented: $addingProfile) { AddProfileView(model: model) }
        .sheet(item: $model.installationRequest) { request in InstallGameView(model: model, request: request) }
        .sheet(item:$model.uninstallationRequest) { request in UninstallGameView(model:model,request:request) }
        .sheet(item: Binding(get:{model.installationRequest == nil && model.uninstallationRequest == nil ? model.steamUIRequest : nil},set:{model.steamUIRequest=$0})) { request in SteamWindowPanel(model:model,session:model.steamWindow,request:request) }
        .onChange(of: model.libraryRequest) { _ in model.selectedGameID = nil; page = .library }
        .onChange(of: model.downloadsRequest) { _ in model.selectedGameID = nil; page = .downloads }
        .onChange(of: model.sessionRequest) { _ in page = .steam }
        .onChange(of: model.chatRequest) { _ in page = .chat }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--show-library") { page = .library }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--show-chat") { page = .chat }
            #endif
        }
        .task {
            #if DEBUG
            if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--steam-panel=")}) {
                for _ in 0..<30 {
                    if !model.refreshing { break }
                    try? await Task.sleep(for:.milliseconds(100))
                }
                model.openSteamClient(flag.hasSuffix("mac") ? .macOS : .windows)
            }
            // Read-only visual preview; does not launch either Steam client.
            if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--show-game=") }) {
                let id = String(flag.dropFirst("--show-game=".count))
                for _ in 0..<30 {
                    if let game = model.library.first(where: { $0.id == id }) { page = .library; model.showGame(game); break }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.session.retry(); model.refresh() }
        .alert("Wayfarer", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
            if let log = model.latestLog { Button("Open log") { NSWorkspace.shared.open(log); model.error = nil } }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 800
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    WayfarerMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Wayfarer").font(.system(size: 20, weight: .semibold))
                        Text("MAKE YOURSELF AT HOME").font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6).padding(.top, 44).padding(.bottom, compact ? 20 : 28)
                .fixedSize(horizontal: false, vertical: true)

                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
                            VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                                Text("DISCOVER").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.bottom, 3)
                                ForEach([Page.home, .library, .favorites, .downloads]) { navigation($0, compact: compact) }
                                Text("PLAY").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, compact ? 12 : 24).padding(.bottom, 3)
                                ForEach([Page.chat, .steam, .runtimes]) { navigation($0, compact: compact) }
                            }
                            Spacer(minLength: compact ? 8 : 20)
                            VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                                engineRow(icon: "apple.logo", title: "Native on Mac", subtitle: "\(count(.macOS)) \(count(.macOS) == 1 ? "game" : "games") in your library", available: true)
                                Divider()
                                engineRow(icon: "square.grid.2x2.fill", title: model.selectedProfile?.runtime.name ?? "Windows engine", subtitle: model.selectedProfile == nil ? "Choose an engine to get started" : "\(count(.windows)) \(count(.windows) == 1 ? "game" : "games") · \(model.selectedProfile!.name)", available: model.selectedProfile != nil)
                            }.padding(compact ? 12 : 15).glassPanel(radius: 16)
                            SteamConnectionControls(model:model)
                        }
                        .frame(minHeight: viewport.size.height, alignment: .top)
                    }
                }
                sidebarFooter.padding(.top, compact ? 12 : 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17)
        }
        .frame(width: 236)
        .background(WindowMaterial().allowsHitTesting(false))
        .background(reduceTransparency ? WayfarerTheme.surface : Color.clear)
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.065)).frame(width: 1).allowsHitTesting(false) }
    }

    private var sidebarFooter: some View {
        HStack {
                Button { page = .sessions } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Toggle("Start Steam in the background", isOn:Binding(get:{model.startsSteamInBackground},set:{model.startsSteamInBackground=$0}))
                    Toggle("Show Mac Steam games", isOn: Binding(get: { model.includesMacSteam }, set: { model.includesMacSteam = $0 }))
                    Button("Refresh library") { model.refresh() }
                    Button("Add game…") { addingGame = true }
                    Button("Open session logs") { model.openLogs() }
                } label: { Label("Settings", systemImage: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize().padding(.vertical, 7).padding(.horizontal, 5)
                .tint(.secondary).help("Library settings")
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 18)
    }

    private func engineRow(icon: String, title: String, subtitle: String, available: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(WayfarerTheme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle().fill(available ? WayfarerTheme.accent : Color.orange).frame(width: 5, height: 5)
        }
    }

    private func navigation(_ destination: Page, compact: Bool) -> some View {
        Button {
            model.selectedGameID = nil; page = destination
            if destination == .steam, model.selectedProfile != nil { model.launchSteam() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: destination.icon).font(.system(size: 14, weight: .medium)).frame(width: 22)
                    .foregroundStyle(page == destination ? WayfarerTheme.accent : Color.secondary)
                Text(destination.rawValue).font(.system(size: 13, weight: page == destination ? .semibold : .medium))
                Spacer()
                if destination == .library { navCount(model.library.count) }
                if destination == .favorites { navCount(model.library.filter { model.favorites.contains($0.id) }.count) }
                if destination == .downloads && !model.transfers.isEmpty { navCount(model.transfers.count) }
            }.padding(.horizontal, 13).padding(.vertical, compact ? 7 : 12)
                .foregroundStyle(page == destination ? Color.white : Color.secondary)
                .background(.white.opacity(page == destination ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .leading) { if page == destination { Capsule().fill(WayfarerTheme.accent).frame(width: 3, height: 16).padding(.leading, 2) } }
        }.buttonStyle(.plain)
    }

    private func navCount(_ number: Int) -> some View {
        Text("\(number)").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text([.home, .library, .favorites].contains(page) && model.selectedGame != nil ? model.selectedGame!.name : page == .home ? "Welcome home." : page.rawValue).font(.system(size: 26, weight: .semibold)).tracking(-0.5).lineLimit(1)
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.refreshing { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Refresh library (⌘R)")
            if (page == .home || page == .library || page == .favorites) && model.selectedGame == nil {
                Button { addingGame = true } label: { Label("Add game", systemImage: "plus") }.buttonStyle(QuietButtonStyle())
            }
        }.padding(.horizontal, 28).padding(.top, 42).padding(.bottom, 24)
    }

    private func count(_ platform: GamePlatform) -> Int { model.library.filter { $0.platforms.contains(platform) }.count }

    private var runtimes: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Wayfarer finds Steam in your CrossOver bottles and uses its installed games. Automatic prefers an existing Steam installation; you can also choose a separate Wayfarer environment.")
                .foregroundStyle(.secondary)
            HStack {
                Picker("Compatibility engine", selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
                    Text("Automatic").tag("automatic")
                    if model.missingSelection { Text("Saved environment unavailable").tag(model.selection) }
                    ForEach(model.profiles) { profile in Text("\(profile.runtime.name) / \(profile.name)\(profile.reusesExistingSteam ? " · Existing Steam" : "")").tag(profile.id) }
                }.frame(maxWidth: 540)
                Button("Add runtime…") { addingProfile = true }
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

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Mac games open natively. Windows sessions keep a log to help troubleshoot launches.").foregroundStyle(.secondary)
            HStack {
                Button { model.openLogs() } label: { Label("Open session logs", systemImage: "folder") }
                if let log = model.latestLog { Button("Open latest log") { NSWorkspace.shared.open(log) } }
            }
            if let log = model.latestLog { pathRow("Latest log", log.path) }
            if model.activeLaunches.isEmpty {
                notice("No active launches. Choose a game from your library to get started.", symbol: "terminal")
            } else {
                ForEach(model.activeLaunches.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    Label(model.activeLaunches[id] ?? "Windows app", systemImage: "play.circle.fill").foregroundStyle(.green)
                }
            }
        }
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }

    private func summary(_ value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).foregroundStyle(WayfarerTheme.blue)
            Text(value).font(.title2).lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(WayfarerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func notice(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 14)
    }
}

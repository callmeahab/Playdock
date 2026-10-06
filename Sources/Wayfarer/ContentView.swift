import SwiftUI
import AppKit
import WayfarerCore

private enum Page: String, Identifiable {
    case home = "Home", library = "Library", favorites = "Favorites", downloads = "Downloads", chat = "Chat", steam = "Steam & account", runtimes = "Engines", sessions = "Activity", storage = "Storage"
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
        case .storage: return "externaldrive.fill"
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
        case .storage: return "Your libraries, game files, and available space."
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
                if let active=model.gameSessions.last(where:{$0.phase.active}) { GameSessionControls(model:model,record:active).padding(.horizontal,28).padding(.bottom,12) }
                if let title = model.pendingGameTitle, model.gameSessions.allSatisfy({!$0.phase.active}) {
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
                            case .sessions: GameActivityView(model:model)
                            case .storage: StorageManagerView(model:model)
                            case .steam: EmptyView()
                            } }
                        }.padding(.horizontal, 28).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.background(LibraryAtmosphere())
        }
        .background(WindowMaterial(material: .underWindowBackground).allowsHitTesting(false))
        .background(WindowAppearance().allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .overlay { if model.showingCouch { CouchView(model:model) } }
        .sheet(isPresented:$model.showingQuickLauncher){QuickLauncherView(model:model)}
        .sheet(item:$model.storageGame){game in GameStorageView(model:model,game:game,platform:model.storagePlatform)}
        .sheet(item:$model.achievementGame){game in AchievementsView(model:model,game:game,platform:model.achievementPlatform)}
        .onChange(of:model.navigationRequest){_ in page=Page(rawValue:model.navigationDestination) ?? .library}
        .sheet(item:$model.featureGame) { game in GamePreferencesView(model:model,game:game) }
        .sheet(isPresented:$model.showingCollections) { CollectionsView(model:model) }
        .sheet(isPresented:$model.showingDiagnostics) { DiagnosticsView(model:model) }
        .sheet(item:$model.windowsAppsProfile,onDismiss:{model.closeWindowsApps()}) { profile in WindowsAppsView(model:model,profile:profile) }
        .sheet(isPresented: $addingGame) { AddGameView(model: model) }
        .sheet(isPresented: $addingProfile) { AddProfileView(model: model) }
        .sheet(item: $model.installationRequest, onDismiss:{ model.cancelInstallation() }) { request in InstallGameView(model: model, request: request) }
        .sheet(item:$model.uninstallationRequest,onDismiss:{ model.closeUninstallDialog() }) { request in UninstallGameView(model:model,request:request) }
        .sheet(item: Binding(get:{model.installationRequest == nil && model.uninstallationRequest == nil ? model.steamUIRequest : nil},set:{if $0 == nil { model.closeSteamPanel() } else { model.steamUIRequest=$0 }})) { request in SteamWindowPanel(model:model,session:model.steamWindow,request:request) }
        .onChange(of: model.libraryRequest) { _ in model.selectedGameID = nil; page = .library }
        .onChange(of: model.downloadsRequest) { _ in model.selectedGameID = nil; page = .downloads }
        .onChange(of: model.sessionRequest) { _ in page = .steam }
        .onChange(of: model.chatRequest) { _ in page = .chat }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--show-library") { page = .library }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--show-storage"){page = .storage}
            if ProcessInfo.processInfo.arguments.contains("--show-activity"){page = .sessions}
            if ProcessInfo.processInfo.arguments.contains("--show-quick"){model.showingQuickLauncher=true}
            if ProcessInfo.processInfo.arguments.contains("--show-couch"){model.showingCouch=true}
            if ProcessInfo.processInfo.arguments.contains("--show-downloads") { page = .downloads }
            if ProcessInfo.processInfo.arguments.contains("--show-windows-apps") {
                Task {
                    while model.refreshing { try? await Task.sleep(for:.milliseconds(100)) }
                    model.manageWindowsApps()
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-collections") { model.showingCollections=true }
            if ProcessInfo.processInfo.arguments.contains("--show-diagnostics") { model.showingDiagnostics=true }
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
            if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--show-game-settings=")}) {
                for _ in 0..<30 {
                    if let game=model.library.first(where:{$0.id==String(flag.dropFirst("--show-game-settings=".count))}) { model.featureGame=game; break }
                    try? await Task.sleep(for:.milliseconds(100))
                }
            }
            if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--install-preview=")}) {
                for _ in 0..<50 {
                    if let game=model.library.first(where:{$0.id==String(flag.dropFirst("--install-preview=".count))}) {
                        model.install(game,platform:.macOS); break
                    }
                    try? await Task.sleep(for:.milliseconds(100))
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-dismiss-probe") {
                try? await Task.sleep(for:.seconds(2))
                let before=NSApp.windows.filter{$0.sheetParent != nil}.count
                let sheet=NSApp.windows.first(where:{$0.sheetParent != nil})
                NSApp.activate(ignoringOtherApps:true); sheet?.makeKeyAndOrderFront(nil)
                if let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:sheet?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? 0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) { NSApp.postEvent(event,atStart:false) }
                try? await Task.sleep(for:.seconds(1))
                let after=NSApp.windows.filter{$0.sheetParent != nil}.count
                print("WAYFARER_DISMISS_PROBE=before:\(before),after:\(after),install:\(model.installationRequest != nil),steam:\(model.steamUIRequest != nil),settings:\(model.featureGame != nil),collections:\(model.showingCollections),diagnostics:\(model.showingDiagnostics)"); fflush(stdout)
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
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--feature-preview"),ProcessInfo.processInfo.arguments.contains("--feature-probe") {
                var previous=""
                while !Task.isCancelled {
                    try? await Task.sleep(for:.milliseconds(250))
                    guard let data=try? Data(contentsOf:URL(fileURLWithPath:"/private/tmp/wayfarer-seven-preview/action.json")),let action=try? JSONDecoder().decode(FeaturePreviewAction.self,from:data),action.id != previous else{continue}
                    previous=action.id
                    let previewWindow = NSApp.windows.first { $0.canBecomeMain && $0.sheetParent == nil }
                    switch action.command {
                    case "activate":NSApp.activate(ignoringOtherApps:true);previewWindow?.makeKeyAndOrderFront(nil)
                    case "quit-preview":NSApp.terminate(nil)
                    case "home":model.navigate("Home")
                    case "library":model.navigate("Library")
                    case "downloads":model.navigate("Downloads")
                    case "resize-small":previewWindow?.setContentSize(NSSize(width:1060,height:700))
                    case "resize-large":previewWindow?.setContentSize(NSSize(width:1320,height:850))
                    case "quick":model.openQuickLauncher()
                    case "storage":model.navigate("Storage")
                    case "activity":model.navigate("Activity")
                    case "couch":model.showingCouch=true
                    case "close":model.showingQuickLauncher=false;model.storageGame=nil;model.achievementGame=nil;model.showingCouch=false
                    case "achievements","storage-detail","game-detail":
                        if let game=model.library.first(where:{$0.id==action.gameID}) {
                            if action.command=="achievements"{model.achievementPlatform = .macOS;model.achievementGame=game}
                            else if action.command=="storage-detail"{model.storagePlatform = .macOS;model.storageGame=game}
                            else{model.navigate("Library");try? await Task.sleep(for:.milliseconds(150));model.showGame(game)}
                        }
                    case "keys":
                        NSApp.activate(ignoringOtherApps:true)
                        let window=NSApp.windows.first(where:{$0.sheetParent != nil}) ?? NSApp.mainWindow;window?.makeKeyAndOrderFront(nil)
                        for code in action.keys ?? [] {
                            if let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window?.windowNumber ?? 0,context:nil,characters:code==53 ? "\u{1b}":"",charactersIgnoringModifiers:code==53 ? "\u{1b}":"",isARepeat:false,keyCode:code){NSApp.postEvent(event,atStart:false)}
                        }
                    default:break
                    }
                    print("FEATURE_PROBE=\(action.command),quick=\(model.showingQuickLauncher),storage=\(model.storageGame != nil),achievements=\(model.achievementGame != nil),couch=\(model.showingCouch)");fflush(stdout)
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
            let compact = geometry.size.height < 900
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    WayfarerMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Wayfarer").font(.system(size: 20, weight: .semibold))
                        Text("A PLACE FOR PLAY").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(WayfarerTheme.accent.opacity(0.7))
                    }
                }
                .padding(.horizontal, 6).padding(.top, 44).padding(.bottom, compact ? 20 : 28)
                .fixedSize(horizontal: false, vertical: true)

                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
                            VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                                Text("YOUR SPACE").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.bottom, 3)
                                ForEach([Page.home, .library, .favorites, .downloads]) { navigation($0, compact: compact) }
                                Text("CONNECTED").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, compact ? 12 : 24).padding(.bottom, 3)
                                ForEach([Page.chat, .steam, .runtimes]) { navigation($0, compact: compact) }
                            }
                            Spacer(minLength: compact ? 8 : 20)
                            VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                                engineRow(icon: "apple.logo", title: "Native on Mac", subtitle: "\(count(.macOS)) Mac games", available: true)
                                Divider()
                                engineRow(icon: "square.grid.2x2.fill", title: model.selectedProfile?.runtime.name ?? "Windows engine", subtitle: model.selectedProfile == nil ? "Choose an engine" : "\(count(.windows)) games · \(model.selectedProfile!.name)", available: model.selectedProfile != nil)
                            }.padding(compact ? 12 : 15)
                                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.045), lineWidth: 1).allowsHitTesting(false))
                            SteamConnectionControls(model:model)
                        }
                        .frame(minHeight: viewport.size.height, alignment: .top)
                    }.scrollIndicators(.hidden)
                }
                sidebarFooter.padding(.top, compact ? 12 : 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17)
        }
        .frame(width: 236)
        .background(SidebarAtmosphere())
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.025)).frame(width: 1).allowsHitTesting(false) }
    }

    private var sidebarFooter: some View {
        HStack {
                Button { page = .sessions } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Toggle("Start Steam in the background", isOn:Binding(get:{model.startsSteamInBackground},set:{model.startsSteamInBackground=$0}))
                    Toggle("Show Mac Steam games", isOn: Binding(get: { model.includesMacSteam }, set: { model.includesMacSteam = $0 }))
                    Button("Storage manager"){model.navigate("Storage")}
                    Button("Controller fullscreen"){model.showingCouch=true}
                    Button("Quick launcher…"){model.openQuickLauncher()}
                    Button("Refresh library") { model.refresh() }
                    Button("Add game…") { addingGame = true }
                    Button("Collections & folders…") { model.showingCollections=true }
                    Button("Launch diagnostics…") { model.showingDiagnostics=true }
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
                if destination == .library { navCount(model.visibleLibrary.count) }
                if destination == .favorites { navCount(model.library.filter { model.favorites.contains($0.id) }.count) }
                if destination == .chat && model.unreadFriendsCount>0 { navCount(model.unreadFriendsCount) }
                if destination == .downloads && !model.transfers.isEmpty { navCount(model.transfers.count) }
            }.padding(.horizontal, 13).padding(.vertical, compact ? 7 : 12)
                .foregroundStyle(page == destination ? Color.white : Color.secondary)
                .background(LinearGradient(colors: [WayfarerTheme.accent.opacity(page == destination ? 0.10 : 0), WayfarerTheme.accent.opacity(page == destination ? 0.025 : 0)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius:11).strokeBorder(WayfarerTheme.accent.opacity(page == destination ? 0.08 : 0),lineWidth:1))
                .overlay(alignment: .leading) { if page == destination { Capsule().fill(WayfarerTheme.accent).frame(width: 3, height: 16).padding(.leading, 2) } }
        }.buttonStyle(.plain)
    }

    private func navCount(_ number: Int) -> some View {
        Text("\(number)").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(title: page == .home && model.selectedGame == nil ? "Your daily escape" : "Wayfarer / \(page.rawValue)", color: .secondary)
                Text([.home, .library, .favorites].contains(page) && model.selectedGame != nil ? "Game overview" : page == .home ? "Good to see you." : page.rawValue)
                    .font(.system(size: 28, weight: .bold)).tracking(-0.7).lineLimit(1)
                if page != .home && model.selectedGame == nil { Text(page.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            Button { model.openQuickLauncher() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                    Text("Quick search")
                    Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 3).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }.buttonStyle(QuietButtonStyle()).help("Quick launcher (⌘K)")
            if model.refreshing { ProgressView().controlSize(.small) }
            Button { model.showingCouch = true } label: { Image(systemName: "gamecontroller").frame(width: 16, height: 16) }
                .buttonStyle(QuietButtonStyle()).help("Controller fullscreen (⌘⇧F)").accessibilityLabel("Controller fullscreen")
            if (page == .home || page == .library || page == .favorites) && model.selectedGame == nil {
                Button { addingGame = true } label: { Image(systemName: "plus").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Add game").accessibilityLabel("Add game")
            } else {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            }
        }.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
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
                Button("Launch diagnostics…") { model.showingDiagnostics=true }
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

#if DEBUG
private struct FeaturePreviewAction:Decodable {let id:String;let command:String;var gameID:String?;var keys:[UInt16]?}
#endif

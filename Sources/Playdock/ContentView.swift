import SwiftUI
import AppKit
import PlaydockCore

struct ContentView: View {
    @ObservedObject var model: LauncherModel
    @State private var page: AppPage = .home
    @State private var addingGame = false
    @State private var addingProfile = false

    var body: some View {
        Group {
            if model.showingCouch { CouchView(model: model, page: $page, addGame: { addingGame = true }, addProfile: { addingProfile = true }) }
            else {
                desktop
            }
        }
        .background(WindowMaterial(material: .underWindowBackground).allowsHitTesting(false))
        .environment(\.gameplayQuiet, model.gameplayQuiet)
        .background(WindowAppearance().allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented:$model.showingQuickLauncher){QuickLauncherView(model:model).controllerControls(model.showingCouch)}
        .sheet(item:$model.storageGame){game in GameStorageView(model:model,game:game,platform:model.storagePlatform).controllerControls(model.showingCouch)}
        .sheet(item:$model.achievementGame){game in AchievementsView(model:model,game:game,platform:model.achievementPlatform).controllerControls(model.showingCouch)}
        .sheet(isPresented: $model.showingSteamBridgeSetup) { SteamBridgeSetupView(model: model).controllerControls(model.showingCouch) }
        .sheet(item: $model.workshopGame) { game in WorkshopView(model: model, game: game).controllerControls(model.showingCouch) }
        .onChange(of:model.navigationRequest){_ in page=AppPage(rawValue:model.navigationDestination) ?? .library}
        .sheet(item:$model.featureGame) { game in GamePreferencesView(model:model,game:game).controllerControls(model.showingCouch) }
        .sheet(isPresented:$model.showingCollections) { CollectionsView(model:model).controllerControls(model.showingCouch) }
        .sheet(isPresented:$model.showingDiagnostics) { DiagnosticsView(model:model).controllerControls(model.showingCouch) }
        .sheet(item:$model.windowsAppsProfile,onDismiss:{model.closeWindowsApps()}) { profile in WindowsAppsView(model:model,profile:profile).controllerControls(model.showingCouch) }
        .sheet(isPresented: $addingGame) { AddGameView(model: model).controllerControls(model.showingCouch) }
        .sheet(isPresented: $addingProfile) { AddProfileView(model: model).controllerControls(model.showingCouch) }
        .sheet(item: $model.installationRequest, onDismiss:{ model.cancelInstallation() }) { request in InstallGameView(model: model, request: request).controllerControls(model.showingCouch) }
        .sheet(item:$model.uninstallationRequest,onDismiss:{ model.closeUninstallDialog() }) { request in UninstallGameView(model:model,request:request).controllerControls(model.showingCouch) }
        .sheet(item: $model.steamLaunchPrompt) { prompt in SteamLaunchPromptView(model: model, prompt: prompt).controllerControls(model.showingCouch) }
        .onChange(of: model.libraryRequest) { _ in model.selectedGameID = nil; page = .library }
        .onChange(of: model.downloadsRequest) { _ in model.selectedGameID = nil; page = .downloads }
        .onChange(of: model.sessionRequest) { _ in page = .sessions }
        .onChange(of: model.chatRequest) { _ in page = .chat }
        .developmentControls(model: model, page: $page)
        .alert("Playdock", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
            if let log = model.latestLog { Button("Open log") { NSWorkspace.shared.open(log); model.error = nil } }
        } message: { Text(model.error ?? "") }
        .controllerControls(model.showingCouch)
    }

    private var desktop: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                AppWorkspace(model: model, page: $page, addGame: { addingGame = true }, addProfile: { addingProfile = true })
            }.background(LibraryAtmosphere())
        }
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 900
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    PlaydockMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Playdock").font(.system(size: 20, weight: .semibold))
                        Text("A PLACE FOR PLAY").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(PlaydockTheme.accent.opacity(0.7))
                    }
                }
                .padding(.horizontal, 6).padding(.top, 44).padding(.bottom, compact ? 20 : 28)
                .fixedSize(horizontal: false, vertical: true)

                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
                            VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                                Text("YOUR SPACE").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.bottom, 3)
                                ForEach([AppPage.home, .library, .favorites, .downloads]) { navigation($0, compact: compact) }
                                Text("CONNECTED").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, compact ? 12 : 24).padding(.bottom, 3)
                                ForEach([AppPage.chat, .runtimes]) { navigation($0, compact: compact) }
                            }
                            Spacer(minLength: compact ? 8 : 20)
                            SteamConnectionControls(model:model)
                        }
                        .frame(minHeight: viewport.size.height, alignment: .top)
                    }.scrollIndicators(.hidden)
                }
                if !sidebarSessions.isEmpty {
                    SidebarGameSessionView(model: model, records: sidebarSessions, showGame: { game in
                        model.showGame(game); page = .library
                    }, showActivity: {
                        model.selectedGameID = nil; page = .sessions
                    })
                    .padding(.top, 12).fixedSize(horizontal: false, vertical: true)
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

    private var sidebarSessions: [GameSessionRecord] {
        model.gameSessions.filter { $0.phase.active }
    }

    private var sidebarFooter: some View {
        HStack {
                Button { page = .sessions } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }.buttonStyle(ControllerButtonStyle(style: .plain))
                Spacer()
                Menu {
                    Button("Settings…") { model.navigate("Settings") }
                    Divider()
                    Toggle("Start Steam in the background", isOn:Binding(get:{model.startsSteamInBackground},set:{model.startsSteamInBackground=$0}))
                    Button("Storage manager"){model.navigate("Storage")}
                    Button("Controller fullscreen"){model.openCouch()}
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

    private func navigation(_ destination: AppPage, compact: Bool) -> some View {
        Button {
            model.selectedGameID = nil; page = destination
        } label: {
            HStack(spacing: 11) {
                Image(systemName: destination.icon).font(.system(size: 14, weight: .medium)).frame(width: 22)
                    .foregroundStyle(page == destination ? PlaydockTheme.accent : Color.secondary)
                Text(destination.rawValue).font(.system(size: 13, weight: page == destination ? .semibold : .medium))
                Spacer()
                if destination == .library { navCount(model.visibleLibrary.count) }
                if destination == .favorites { navCount(model.libraryPresentation.favoriteCount) }
                if destination == .chat && model.unreadFriendsCount>0 { navCount(model.unreadFriendsCount) }
                if destination == .downloads && !model.transfers.isEmpty { navCount(model.transfers.count) }
            }.padding(.horizontal, 13).padding(.vertical, compact ? 7 : 12)
                .foregroundStyle(page == destination ? Color.white : Color.secondary)
                .background(LinearGradient(colors: [PlaydockTheme.accent.opacity(page == destination ? 0.10 : 0), PlaydockTheme.accent.opacity(page == destination ? 0.025 : 0)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius:11).strokeBorder(PlaydockTheme.accent.opacity(page == destination ? 0.08 : 0),lineWidth:1))
                .overlay(alignment: .leading) { if page == destination { Capsule().fill(PlaydockTheme.accent).frame(width: 3, height: 16).padding(.leading, 2) } }
        }.buttonStyle(ControllerButtonStyle(style: .plain))
    }

    private func navCount(_ number: Int) -> some View {
        Text("\(number)").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(title: page == .home && model.selectedGame == nil ? "Your daily escape" : "Playdock / \(page.rawValue)", color: .secondary)
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
            Button { model.openCouch() } label: { Image(systemName: "gamecontroller").frame(width: 16, height: 16) }
                .buttonStyle(QuietButtonStyle()).help("Controller fullscreen (⌘⇧F)").accessibilityLabel("Controller fullscreen")
            if (page == .home || page == .library || page == .favorites) && model.selectedGame == nil {
                Button { addingGame = true } label: { Image(systemName: "plus").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Add game").accessibilityLabel("Add game")
            } else {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }.buttonStyle(QuietButtonStyle()).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            }
        }.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
    }

}

import SwiftUI
import AppKit
import PlaydockCore

struct AppSidebar: View {
    @ObservedFeatures var model: LauncherModel
    @Binding var page: AppPage
    let addGame: () -> Void

    init(model: LauncherModel, page: Binding<AppPage>, addGame: @escaping () -> Void) {
        _model = ObservedFeatures(wrappedValue: model, [.downloads, .library, .settings, .social])
        _page = page; self.addGame = addGame
    }

    var body: some View {
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
                    Button("Add game…") { addGame() }
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
                if destination == .favorites { navCount(model.libraryState.libraryPresentation.favoriteCount) }
                if destination == .chat && model.unreadFriendsCount>0 { navCount(model.unreadFriendsCount) }
                if destination == .downloads && !model.downloadsState.transfers.isEmpty { navCount(model.downloadsState.transfers.count) }
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

}

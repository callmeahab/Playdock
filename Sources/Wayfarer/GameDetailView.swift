import AppKit
import SwiftUI
import WayfarerCore

struct GameDetailView: View {
    @ObservedObject var model: LauncherModel
    let game: LibraryGame
    let back: () -> Void
    private var platform: GamePlatform { model.selectedGamePlatform ?? model.preferredGamePlatform(game) ?? .macOS }
    private var installation: GameInstallation? { game.installation(for: platform) }
    private var hasTransfer: Bool { model.transfers.contains { $0.appID == String(game.id.dropFirst("steam:".count)) && $0.client == platform } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button(action: back) { Label("Back to library", systemImage: "chevron.left") }
                .buttonStyle(ControllerButtonStyle(style: .plain)).font(.system(size: 12)).foregroundStyle(.secondary)
            ZStack(alignment: .bottomLeading) {
                GameArtwork(game: game, wide: true)
                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 6) { ForEach(game.platforms, id: \.self) { PlatformBadge(platform: $0) } }
                    Text(game.name).font(.system(size: 40, weight: .bold)).tracking(-1).lineLimit(2)
                }.padding(28)
            }.frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(GameIdentity.accent(game).opacity(0.3),lineWidth:1))
                .shadow(color:GameIdentity.accent(game).opacity(0.12),radius:22,y:10)
            HStack(spacing: 12) {
                Button { if let active=model.activeSession(game.id){model.bringGameForward(active)} else if hasTransfer { model.showDownloads() } else { model.launch(game, platform: platform) } } label: {
                    Label(model.activeSession(game.id)?.phase == .launching ? "Launching…" : model.activeSession(game.id) != nil ? "Return to game" : hasTransfer ? "View download" : installation == nil ? "Install" : installation?.steamGame?.requiresUpdate == true ? "Update & play" : "Play", systemImage: hasTransfer ? "arrow.down.circle" : installation == nil ? "arrow.down.to.line" : "play.fill")
                        .frame(minWidth: 85)
                }.buttonStyle(PlayButtonStyle()).disabled((installation == nil && game.offer(for: platform) == nil) || model.installing || model.uninstallBusy || model.installationDisabled(game,platform:platform))
                if game.platforms.count > 1 {
                    Picker("Play version", selection: Binding(get: { platform }, set: { model.selectedGamePlatform = $0; model.rememberPlatform($0,game:game) })) {
                        ForEach(game.platforms, id: \.self) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                Button { model.toggleFavorite(game) } label: {
                    Image(systemName: model.favorites.contains(game.id) ? "heart.fill" : "heart")
                }.buttonStyle(QuietButtonStyle()).help("Favorite game")
                Spacer()
                Button("Game settings…") { model.featureGame = game }.buttonStyle(QuietButtonStyle())
                Menu {
                    if game.isSteam {
                        Button("Open Steam in Wayfarer") { model.openSteamClient(platform) }
                    }
                    if let installation {
                        Button("Show game files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([installation.location]) }
                        if installation.steamGame != nil {
                            Divider()
                            Button("Uninstall \(platform.name) version…", role: .destructive) { model.requestUninstall(game, platform: platform) }.disabled(model.uninstallBusy)
                        }
                    }
                } label: { Label("More", systemImage: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Game settings, Steam & game files")
            }.padding(16).glassPanel(radius: 18)
            if model.installationDisabled(game,platform:platform) {
                HStack(spacing:12) {
                    Label(model.installationAvailabilityMessage(platform),systemImage:"network.slash").font(.system(size:12)).foregroundStyle(.secondary)
                    Spacer()
                    if model.connectionMode(platform) == .offline {
                        Button("Go online") { model.setSteamMode(platform,offline:false) }.buttonStyle(QuietButtonStyle()).disabled(model.connectionBusy.contains(platform))
                    } else {
                        Button(model.connectionMode(platform) == .signedOut ? "Sign in" : "Connect Steam") {
                            if model.connectionMode(platform) == .signedOut { model.openSteamClient(platform) } else { model.connectSteam(platform) }
                        }.buttonStyle(QuietButtonStyle()).disabled(model.connectionBusy.contains(platform))
                    }
                }
            }
            if let active = model.activeSession(game.id) { GameSessionControls(model: model, record: active) }
            if game.isSteam {
                HStack(spacing: 12) {
                    Button { model.achievementPlatform = platform; model.achievementGame = game } label: {
                        Label("Achievements", systemImage: "trophy")
                    }.buttonStyle(QuietButtonStyle())
                    if installation != nil {
                        Button { model.storagePlatform = platform; model.storageGame = game } label: {
                            Label("Manage storage", systemImage: "externaldrive")
                        }.buttonStyle(QuietButtonStyle())
                    }
                    Spacer()
                }
            }
            HStack(alignment: .top, spacing: 14) {
                info("VERSION", value: platform == .macOS ? "Native Mac" : model.selectedProfile?.runtime.name ?? "Windows", icon: platform == .macOS ? "apple.logo" : "cpu")
                Divider()
                info("INSTALLATION", value: hasTransfer ? "Queued in Steam" : installation == nil ? "Ready to install" : installation?.steamGame?.requiresUpdate == true ? "Update available" : "Installed", icon: "internaldrive")
                Divider()
                info("ON DISK", value: installation?.steamGame?.sizeOnDisk.map(formatBytes) ?? (installation == nil ? "Choose a location" : game.isSteam ? "Not reported" : "Added application"), icon: "externaldrive")
            }.padding(20).glassPanel(radius: 17)
            if game.platforms.contains(.windows) {
                DisclosureGroup {
                    CompatibilityGuidanceView(model: model, game: game).padding(.top, 15)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu").foregroundStyle(WayfarerTheme.violet)
                        Text("Windows compatibility").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(model.compatibilityTests(game).isEmpty ? "Not tested yet" : "Your tested configurations").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(18).glassPanel(radius: 17)
            }
            VStack(alignment: .leading, spacing: 15) {
                Text("About this installation").font(.system(size: 16, weight: .semibold))
                Text(installation == nil ? "Choose a library and install here. Follow its progress in Downloads." : platform == .macOS ? "Runs directly on your Mac." : "Runs in your selected Windows environment.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if game.lastPlayed > 0 {
                    HStack { Text("Last played").foregroundStyle(.secondary); Spacer(); Text(Date(timeIntervalSince1970: game.lastPlayed), style: .relative) }
                        .font(.system(size: 11))
                }
                if let installation {
                    Divider()
                    HStack {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([installation.location]) } label: {
                            Label("Show game files in Finder", systemImage: "folder")
                        }.buttonStyle(ControllerButtonStyle(style: .plain)).font(.system(size: 12)).foregroundStyle(WayfarerTheme.accent)
                        Spacer()
                        if installation.steamGame != nil {
                            Button("Uninstall…",role:.destructive) { model.requestUninstall(game,platform:platform) }
                                .buttonStyle(QuietButtonStyle()).disabled(model.uninstallBusy)
                        }
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 17)
        }
    }

    private func info(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
}

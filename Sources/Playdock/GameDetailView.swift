import AppKit
import SwiftUI
import PlaydockCore

struct GameDetailView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, game: LibraryGame, back: @escaping () -> Void) {
        self._model = ObservedFeatures(wrappedValue: model, [.downloads, .installation, .runtime, .settings, .steam])
        self.game = game
        self.back = back
    }
    let game: LibraryGame
    let back: () -> Void
    private var platform: GamePlatform { model.preferredGamePlatform(game) ?? .macOS }
    private var installation: GameInstallation? { game.installation(for: platform) }
    private var hasTransfer: Bool { model.downloadsState.transfers.contains { $0.appID == String(game.id.dropFirst("steam:".count)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button(action: back) { Label("Back to library", systemImage: "chevron.left") }
                .buttonStyle(ControllerButtonStyle(style: .plain)).font(.system(size: 12)).foregroundStyle(.secondary)
            ZStack(alignment: .bottomLeading) {
                GameArtwork(game: game, wide: true)
                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 13) {
                    PlatformBadge(platform: platform, runtime: model.performanceProfile(for: game)?.runtime.name)
                    Text(game.name).font(.system(size: 40, weight: .bold)).tracking(-1).lineLimit(2)
                }.padding(28)
            }.frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(GameIdentity.accent(game).opacity(0.3),lineWidth:1))
                .shadow(color:GameIdentity.accent(game).opacity(0.12),radius:22,y:10)
            HStack(spacing: 12) {
                Button { if let active=model.activeSession(game.id){model.bringGameForward(active)} else if hasTransfer { model.showDownloads() } else { model.launch(game) } } label: {
                    Label(model.activeSession(game.id)?.phase == .launching ? "Launching…" : model.activeSession(game.id) != nil ? "Return to game" : hasTransfer ? "View download" : installation == nil ? "Install" : installation?.steamGame?.requiresUpdate == true ? "Update & play" : "Play", systemImage: hasTransfer ? "arrow.down.circle" : installation == nil ? "arrow.down.to.line" : "play.fill")
                        .frame(minWidth: 85)
                }.buttonStyle(PlayButtonStyle()).disabled((installation == nil && game.offer(for: platform) == nil) || model.installationState.uninstallBusy || model.installationDisabled(game,platform:platform))
                Button { model.toggleFavorite(game) } label: {
                    Image(systemName: model.favorites.contains(game.id) ? "heart.fill" : "heart")
                }.buttonStyle(QuietButtonStyle()).help("Favorite game")
                Spacer()
                Button("Game settings…") { model.featureGame = game }.buttonStyle(QuietButtonStyle())
                Menu {
                    if let installation {
                        Button("Show game files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([installation.location]) }
                        if installation.steamGame != nil {
                            Divider()
                            Button("Uninstall…", role: .destructive) { model.requestUninstall(game, platform: platform) }.disabled(model.installationState.uninstallBusy)
                        }
                    }
                } label: { Label("More", systemImage: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Game files and uninstall")
            }.padding(16).glassPanel(radius: 18)
            if model.installationDisabled(game,platform:platform) {
                HStack(spacing:12) {
                    Label(model.gameAvailabilityMessage(game),systemImage: platform == .windows ? "cpu" : "network.slash").font(.system(size:12)).foregroundStyle(.secondary)
                    Spacer()
                    if platform == .windows, game.isSteam, model.runtimeState.bridgeEnvironment?.ready != true {
                        Button("Set up runtime…") { model.showingSteamBridgeSetup = true }.buttonStyle(PlayButtonStyle()).disabled(model.runtimeState.bridgeBusy)
                    } else if !game.isSteam {
                        Button("Choose runtime…") { model.featureGame = game }.buttonStyle(QuietButtonStyle())
                    } else if model.connectionMode() == .offline {
                        Button("Go online") { model.setSteamMode(offline:false) }.buttonStyle(QuietButtonStyle()).disabled(model.steamState.busy)
                    } else {
                        Button(model.connectionMode() == .signedOut ? "Sign in" : "Connect Steam") {
                            if model.connectionMode() == .signedOut { model.showSteamSignInHelp() } else { model.connectSteam() }
                        }.buttonStyle(QuietButtonStyle()).disabled(model.steamState.busy)
                    }
                }
            }
            if let active = model.activeSession(game.id) { GameSessionControls(model: model, record: active) }
            if game.isSteam {
                HStack(spacing: 12) {
                    Button { model.showWorkshop(game) } label: {
                        Label("Workshop & mods", systemImage: "puzzlepiece.extension")
                    }.buttonStyle(QuietButtonStyle())
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
                info("RUNS ON", value: model.executionName(game), icon: platform == .macOS ? "apple.logo" : "cpu")
                Divider()
                info("INSTALLATION", value: hasTransfer ? "Queued in Steam" : installation == nil ? "Ready to install" : installation?.steamGame?.requiresUpdate == true ? "Update available" : "Installed", icon: "internaldrive")
                Divider()
                info("ON DISK", value: installation?.steamGame?.sizeOnDisk.map(formatBytes) ?? (installation == nil ? "Choose a location" : game.isSteam ? "Not reported" : "Added application"), icon: "externaldrive")
            }.padding(20).glassPanel(radius: 17)
            if platform == .windows {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Compatibility settings & prefix files…") { model.featureGame = game }.buttonStyle(QuietButtonStyle())
                        CompatibilityGuidanceView(model: model, game: game)
                    }.padding(.top, 15)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu").foregroundStyle(PlaydockTheme.violet)
                        Text("Compatibility & prefix").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(model.compatibilityTests(game).isEmpty ? "Not tested yet" : "Your tested configurations").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(18).glassPanel(radius: 17)
            }
            VStack(alignment: .leading, spacing: 15) {
                Text("About this installation").font(.system(size: 16, weight: .semibold))
                Text(installation == nil ? "Choose a library and install here. Follow its progress in Downloads." : platform == .macOS ? "Runs directly on your Mac." : "Runs through \(model.performanceProfile(for: game)?.runtime.name ?? "a compatibility runtime") on your Mac.")
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
                        }.buttonStyle(ControllerButtonStyle(style: .plain)).font(.system(size: 12)).foregroundStyle(PlaydockTheme.accent)
                        Spacer()
                        if installation.steamGame != nil {
                            Button("Uninstall…",role:.destructive) { model.requestUninstall(game,platform:platform) }
                                .buttonStyle(QuietButtonStyle()).disabled(model.installationState.uninstallBusy)
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

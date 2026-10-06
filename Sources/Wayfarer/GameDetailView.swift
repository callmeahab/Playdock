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
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            ZStack(alignment: .bottomLeading) {
                GameArtwork(game: game, wide: true)
                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 6) { ForEach(game.platforms, id: \.self) { PlatformBadge(platform: $0) } }
                    Text(game.name).font(.system(size: 34, weight: .semibold)).tracking(-0.7).lineLimit(3)
                }.padding(28)
            }.frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            HStack(spacing: 12) {
                Button { if hasTransfer { model.showDownloads() } else { model.launch(game, platform: platform) } } label: {
                    Label(hasTransfer ? "View download" : installation == nil ? "Install" : installation?.steamGame?.requiresUpdate == true ? "Update & play" : "Play", systemImage: hasTransfer ? "arrow.down.circle" : installation == nil ? "arrow.down.to.line" : "play.fill")
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
                Button { model.featureGame=game } label: { Label("Game settings",systemImage:"gearshape") }.buttonStyle(QuietButtonStyle())
                if game.isSteam {
                    Button("Open Steam") { model.openSteamClient(platform) }.buttonStyle(QuietButtonStyle())
                }
            }
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
            HStack(alignment: .top, spacing: 14) {
                info("VERSION", value: platform == .macOS ? "Native Mac" : model.selectedProfile?.runtime.name ?? "Windows", icon: platform == .macOS ? "apple.logo" : "cpu")
                info("INSTALLATION", value: hasTransfer ? "Queued in Steam" : installation == nil ? "Ready to install" : installation?.steamGame?.requiresUpdate == true ? "Update available" : "Installed", icon: "internaldrive")
                info("ON DISK", value: installation?.steamGame?.sizeOnDisk.map(formatBytes) ?? (installation == nil ? "Choose a location" : game.isSteam ? "Not reported" : "Added application"), icon: "externaldrive")
            }
            VStack(alignment: .leading, spacing: 15) {
                Text("Your game, your way").font(.system(size: 16, weight: .semibold))
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
                        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(WayfarerTheme.accent)
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
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 14)
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
}

import SwiftUI
import WayfarerCore

struct ChatView: View {
    @ObservedObject var model: LauncherModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 30)).foregroundStyle(WayfarerTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stay close, wherever you play").font(.system(size: 20, weight: .semibold))
                    Text("Open your Steam friends and conversations here. Chat uses the account signed in to each Steam environment.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 18)
            ForEach(GamePlatform.allCases.filter { $0 == .windows || model.includesMacSteam }, id: \.self) { platform in
                HStack(spacing: 14) {
                    Image(systemName: platform == .macOS ? "apple.logo" : "square.grid.2x2.fill").font(.system(size: 20)).foregroundStyle(WayfarerTheme.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(platform.name) Steam Chat").font(.system(size: 14, weight: .semibold))
                        Text(model.connectionMode(platform).title).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.connectionMode(platform) == .offline {
                        Button("Go online") { model.setSteamMode(platform, offline: false) }.buttonStyle(QuietButtonStyle()).disabled(model.connectionBusy.contains(platform))
                    }
                    Button("Open chat") { model.openSteamClient(platform, destination: .chat) }
                        .buttonStyle(QuietButtonStyle()).disabled(model.connectionBusy.contains(platform) || (platform == .windows && model.selectedProfile == nil))
                }.padding(20).glassPanel(radius: 16)
            }
            if model.session.prefersChat, model.selectedProfile?.reusesExistingSteam == false {
                SessionView(model:model,session:model.session).frame(height:500)
            }
        }
    }
}

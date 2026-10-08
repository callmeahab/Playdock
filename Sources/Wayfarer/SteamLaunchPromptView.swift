import SwiftUI
import AppKit
import WayfarerCore

struct SteamLaunchPrompt: Identifiable {
    let record: GameSessionRecord
    let launch: SteamGameLaunch
    var id: String { "\(record.id):\(launch.actionID):\(launch.task):\(launch.request ?? "")" }
    var response: SteamLaunchResponse? {
        switch (launch.task, launch.request) {
        case ("SynchronizingCloud", "syncfailed"): .playWithoutCloud
        case ("SynchronizingCloud", "pendingcloudsessions"): .ignorePendingCloud
        case ("RunningInstallScript", _): .ignoreInstallError
        case ("KickingOtherSession", _): .endOtherSession
        default: nil
        }
    }
    var button: String {
        switch response {
        case .playWithoutCloud: "Play without syncing"
        case .ignorePendingCloud: "Use this Mac’s saves"
        case .ignoreInstallError: "Continue anyway"
        case .endOtherSession: "End other session and play"
        default: ""
        }
    }
}

struct SteamLaunchPromptView: View {
    @ObservedObject var model: LauncherModel
    let prompt: SteamLaunchPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Play \(prompt.record.name)", systemImage: "play.circle.fill").font(.title2.weight(.semibold))
            Text(prompt.launch.confirmationMessage).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Cancel launch") { model.respondToSteamLaunch(prompt, response: .cancel) }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if let response = prompt.response {
                    Button(prompt.button) { model.respondToSteamLaunch(prompt, response: response) }.buttonStyle(PlayButtonStyle())
                }
            }.disabled(model.steamLaunchResponseBusy)
        }.padding(28).frame(width: 580).background(WayfarerTheme.background)
        .interactiveDismissDisabled()
    }
}

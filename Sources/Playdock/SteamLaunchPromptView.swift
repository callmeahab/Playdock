import SwiftUI
import AppKit
import PlaydockCore
import PlaydockPresentation

struct SteamLaunchPromptView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, prompt: SteamLaunchPrompt) {
        self._model = ObservedFeatures(wrappedValue: model, [.activity])
        self.prompt = prompt
    }
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
            }.disabled(model.activityState.steamLaunchResponseBusy)
        }.padding(28).frame(width: 580).background(PlaydockTheme.background)
        .interactiveDismissDisabled()
    }
}

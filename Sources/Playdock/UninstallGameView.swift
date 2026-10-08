import SwiftUI
import PlaydockPresentation

struct UninstallGameView:View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, request: GameUninstallationRequest) {
        self._model = ObservedFeatures(wrappedValue: model, [.installation])
        self.request = request
    }
    let request:GameUninstallationRequest
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Label("Uninstall \(request.game.name)?",systemImage:"trash").font(.title2.weight(.semibold))
            Text("Remove the \(request.platform.name) version from this Steam library. You can install it again from your library.")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(request.location.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.installationState.uninstallBusy {
                ProgressView().controlSize(.small)
                Text("You can close this dialog. Steam will finish an uninstall that has already started.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.installationState.uninstallMessage.isEmpty {
                Text(model.installationState.uninstallMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                Button(model.installationState.uninstallBusy ? "Close" : "Cancel") { model.closeUninstallDialog() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if !model.installationState.uninstallMessage.isEmpty && !model.installationState.uninstallBusy {
                    Button("Reconnect") { model.connectSteam() }.buttonStyle(QuietButtonStyle())
                }
                Button("Uninstall",role:.destructive) { model.confirmUninstall() }
                    .buttonStyle(ControllerButtonStyle(style: .borderedProminent)).tint(.red).disabled(model.installationState.uninstallBusy)
            }
        }.padding(30).frame(width:540).background(PlaydockTheme.background)
        .background(DialogEscapeHandler { model.closeUninstallDialog() }.allowsHitTesting(false))
        .onExitCommand { model.closeUninstallDialog() }
    }
}

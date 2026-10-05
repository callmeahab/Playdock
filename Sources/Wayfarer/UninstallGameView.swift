import SwiftUI

struct UninstallGameView:View {
    @ObservedObject var model:LauncherModel
    let request:GameUninstallationRequest
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Label("Uninstall \(request.game.name)?",systemImage:"trash").font(.title2.weight(.semibold))
            Text("Remove the \(request.platform.name) version from this Steam library. You can install it again from your library.")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(request.location.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.uninstallBusy { ProgressView().controlSize(.small) }
            if !model.uninstallMessage.isEmpty {
                Text(model.uninstallMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                Button("Cancel") { model.uninstallationRequest=nil }.buttonStyle(QuietButtonStyle()).disabled(model.uninstallBusy)
                Spacer()
                if !model.uninstallMessage.isEmpty && !model.uninstallBusy {
                    Button("Open Steam") { model.openSteamClient(request.platform) }.buttonStyle(QuietButtonStyle())
                }
                Button("Uninstall",role:.destructive) { model.confirmUninstall() }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(model.uninstallBusy)
            }
        }.padding(30).frame(width:540).background(WayfarerTheme.background)
        .interactiveDismissDisabled(model.uninstallBusy)
        .sheet(item:$model.steamUIRequest) { request in SteamWindowPanel(model:model,session:model.steamWindow,request:request) }
    }
}

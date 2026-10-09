import SwiftUI
import WebKit
import PlaydockCore
import PlaydockPresentation

struct SteamConnectionControls: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [.steam])
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Menu {
                Button("Connect Steam") { model.connectSteam() }
                Button("Go online") { model.setSteamMode(offline:false) }.disabled(model.connectionMode() != .offline)
                Button("Go offline") { model.setSteamMode(offline:true) }.disabled(model.connectionMode() != .online)
                Divider()
                Button("Sign in through Steam…") { model.openSteamForSignIn() }
            } label: {
                Label("Steam", systemImage: "apple.logo")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(.vertical, 3)
            }.menuStyle(.borderlessButton).tint(.secondary).disabled(model.steamState.busy)
            Text(model.steamState.busy ? "Connecting…" : model.steamState.message ?? model.connectionMode().title)
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal,9)
        .task { model.refreshSteamControls() }
    }
}

struct InstallGameView:View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel, request: GameInstallationRequest) {
        self._model = ObservedFeatures(wrappedValue: model, [.installation, .steam])
        self.request = request
    }
    let request:GameInstallationRequest
    @State private var accepted=false
    @State private var agreement:SteamGameEULA?
    private var folders:[SteamInstallFolder] { model.steamState.snapshot?.folders ?? [] }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {
                Image(systemName:"arrow.down.circle.fill").font(.system(size:30)).foregroundStyle(PlaydockTheme.accent)
                VStack(alignment:.leading,spacing:5) {
                    Text("Install \(request.game.name)").font(.title2.weight(.semibold))
                    Text(request.platform == .macOS ? "Runs natively on Mac" : "Runs with CrossOver").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ScrollView {
            VStack(alignment:.leading,spacing:18) {
            Text(model.installationState.installMessage).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if model.installationState.installBusy { ProgressView().controlSize(.small) }
            if let plan=model.installationState.installPlan {
                Picker("Library",selection:Binding(get:{plan.folder},set:{model.chooseInstallFolder($0);accepted=false})) {
                    ForEach(folders) { folder in Text("\(folder.name) · \(formatBytes(folder.freeBytes)) free").tag(folder.id) }
                }.disabled(model.installationState.installBusy)
                if let folder=folders.first(where:{$0.id==plan.folder}) {
                    Text(folder.path).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack { Text("Space required"); Spacer(); Text(formatBytes(plan.requiredBytes)).monospacedDigit() }.font(.system(size:12))
                if plan.requiredBytes>plan.availableBytes { Label("Not enough free space in this library.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.system(size:12)) }
                if plan.needsAgreement {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Game agreements").font(.system(size:13,weight:.medium))
                        ForEach(Array(plan.eulas.enumerated()),id:\.element.id) { index,eula in
                            Button("Read agreement \(index+1)") { agreement=eula }.buttonStyle(ControllerButtonStyle(style: .link))
                        }
                        Toggle("I have read and accept the game agreements",isOn:$accepted).font(.system(size:12))
                    }
                }
            } else if model.connectionMode() == .offline {
                Label("Installed games remain available in Offline Mode. Downloads need an online connection.",systemImage:"network.slash")
                    .font(.system(size:12)).foregroundStyle(.secondary)
            }
            }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack {
                Button("Cancel") { model.cancelInstallation() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if model.installationState.installPlan==nil {
                    if model.connectionMode() == .offline {
                        Button("Go online") { model.setSteamMode(offline:false) }.buttonStyle(PlayButtonStyle()).disabled(model.steamState.busy)
                    } else {
                        Button(model.connectionMode() == .signedOut ? "Sign in to Steam" : "Reconnect") {
                            if model.connectionMode() == .signedOut { model.openSteamForSignIn() }
                            else { model.connectSteam() }
                        }.buttonStyle(QuietButtonStyle())
                        Button("Retry") { model.prepareInstallation() }.buttonStyle(PlayButtonStyle()).disabled(model.installationState.installBusy)
                    }
                } else {
                    if !model.installationState.installPlan!.canConfirm {
                        Button("Reconnect") { model.connectSteam() }.buttonStyle(QuietButtonStyle())
                        Button("Retry") { model.prepareInstallation() }.buttonStyle(QuietButtonStyle()).disabled(model.installationState.installBusy)
                    }
                    Button("Install") { model.confirmInstallation(acceptedAgreements:accepted) }.buttonStyle(PlayButtonStyle())
                        .disabled(model.installationState.installBusy || !model.installationState.installPlan!.canConfirm || (model.installationState.installPlan!.needsAgreement && !accepted))
                }
            }
        }.padding(26).frame(width:540,height:min(model.installationState.installPlan?.needsAgreement == true ? 540 : model.installationState.installPlan == nil ? 300 : 400,max(280,(NSApp.keyWindow?.screen?.visibleFrame.height ?? 700)-140))).background(PlaydockTheme.background)
        .background(DialogEscapeHandler { model.cancelInstallation() }.allowsHitTesting(false))
        .onExitCommand { model.cancelInstallation() }
        .onChange(of:model.installationState.installRevision) { _ in accepted=false; agreement=nil }
        .sheet(item:$agreement) { eula in
            VStack(spacing:12) {
                Text("Game agreement").font(.headline)
                EULAWebView(url:eula.url)
                Button("Done") { agreement=nil }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(20).frame(width:650,height:560).controllerControls(model.showingCouch)
        }
    }
}

private struct EULAWebView:NSViewRepresentable {
    let url:URL
    func makeNSView(context:Context)->WKWebView {
        let config=WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view=WKWebView(frame:.zero,configuration:config); view.load(URLRequest(url:url)); return view
    }
    func updateNSView(_ view:WKWebView,context:Context) {}
}

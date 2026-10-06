import SwiftUI
import WebKit
import WayfarerCore

struct SteamConnectionControls: View {
    @ObservedObject var model:LauncherModel
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(GamePlatform.allCases.filter { $0 == .windows || model.includesMacSteam },id:\.self) { client in
                Menu {
                    Button("Connect Steam") { model.connectSteam(client) }
                    if client == .windows {
                        Button("Manage Windows apps…") { model.manageWindowsApps() }.disabled(model.selectedProfile == nil)
                    }
                    Button("Go online") { model.setSteamMode(client,offline:false) }.disabled(model.connectionMode(client) != .offline)
                    Button("Go offline") { model.setSteamMode(client,offline:true) }.disabled(model.connectionMode(client) != .online)
                    Divider()
                    Button("Open Steam login") { model.openSteamClient(client) }
                } label: {
                    Label("\(client.name) Steam", systemImage: client == .macOS ? "apple.logo" : "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(.vertical, 3)
                }.menuStyle(.borderlessButton).tint(.secondary).disabled(model.connectionBusy.contains(client))
                Text(model.connectionBusy.contains(client) ? "Connecting…" : model.connectionMessages[client] ?? model.connectionMode(client).title)
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if client == .windows,model.windowsSteamNeedsRecovery {
                    Button("Manage Windows apps…") { model.manageWindowsApps() }
                        .buttonStyle(.link).font(.system(size:11)).disabled(model.connectionBusy.contains(client))
                }
            }
        }.padding(.horizontal,9)
        .task { model.refreshSteamControls() }
    }
}

struct InstallGameView:View {
    @ObservedObject var model:LauncherModel
    let request:GameInstallationRequest
    @WayfarerState private var accepted=false
    @WayfarerState private var agreement:SteamGameEULA?
    private var folders:[SteamInstallFolder] { model.steamConnections[request.platform]?.folders ?? [] }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {
                Image(systemName:"arrow.down.circle.fill").font(.system(size:30)).foregroundStyle(WayfarerTheme.accent)
                VStack(alignment:.leading,spacing:5) {
                    Text("Install \(request.game.name)").font(.title2.weight(.semibold))
                    Text("\(request.platform.name) version").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ScrollView {
            VStack(alignment:.leading,spacing:18) {
            Text(model.installMessage).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if model.installBusy { ProgressView().controlSize(.small) }
            if let plan=model.installPlan {
                Picker("Library",selection:Binding(get:{plan.folder},set:{model.chooseInstallFolder($0);accepted=false})) {
                    ForEach(folders) { folder in Text("\(folder.name) · \(formatBytes(folder.freeBytes)) free").tag(folder.id) }
                }.disabled(model.installBusy)
                if let folder=folders.first(where:{$0.id==plan.folder}) {
                    Text(folder.path).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack { Text("Space required"); Spacer(); Text(formatBytes(plan.requiredBytes)).monospacedDigit() }.font(.system(size:12))
                if plan.requiredBytes>plan.availableBytes { Label("Not enough free space in this library.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.system(size:12)) }
                if plan.needsAgreement {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Game agreements").font(.system(size:13,weight:.medium))
                        ForEach(Array(plan.eulas.enumerated()),id:\.element.id) { index,eula in
                            Button("Read agreement \(index+1)") { agreement=eula }.buttonStyle(.link)
                        }
                        Toggle("I have read and accept the game agreements",isOn:$accepted).font(.system(size:12))
                    }
                }
            } else if model.connectionMode(request.platform) == .offline {
                Label("Installed games remain available in Offline Mode. Downloads need an online connection.",systemImage:"network.slash")
                    .font(.system(size:12)).foregroundStyle(.secondary)
            }
            }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack {
                Button("Cancel") { model.cancelInstallation() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if model.installPlan==nil {
                    if model.connectionMode(request.platform) == .offline {
                        Button("Go online") { model.setSteamMode(request.platform,offline:false) }.buttonStyle(PlayButtonStyle()).disabled(model.connectionBusy.contains(request.platform))
                    } else {
                        Button("Open login") { model.openSteamClient(request.platform) }.buttonStyle(QuietButtonStyle())
                        Button("Retry") { model.prepareInstallation() }.buttonStyle(PlayButtonStyle()).disabled(model.installBusy)
                    }
                } else {
                    if !model.installPlan!.canConfirm {
                        Button("Open Steam") { model.openSteamClient(request.platform) }.buttonStyle(QuietButtonStyle())
                        Button("Retry") { model.prepareInstallation() }.buttonStyle(QuietButtonStyle()).disabled(model.installBusy)
                    }
                    Button("Install") { model.confirmInstallation(acceptedAgreements:accepted) }.buttonStyle(PlayButtonStyle())
                        .disabled(model.installBusy || !model.installPlan!.canConfirm || (model.installPlan!.needsAgreement && !accepted))
                }
            }
        }.padding(26).frame(width:540,height:min(model.installPlan?.needsAgreement == true ? 540 : model.installPlan == nil ? 300 : 400,max(280,(NSApp.keyWindow?.screen?.visibleFrame.height ?? 700)-140))).background(WayfarerTheme.background)
        .background(DialogEscapeHandler { model.cancelInstallation() }.allowsHitTesting(false))
        .onExitCommand { model.cancelInstallation() }
        .onChange(of:model.installRevision) { _ in accepted=false; agreement=nil }
        .sheet(item:$model.steamUIRequest) { request in SteamWindowPanel(model:model,session:model.steamWindow,request:request) }
        .sheet(item:$agreement) { eula in
            VStack(spacing:12) {
                Text("Game agreement").font(.headline)
                EULAWebView(url:eula.url)
                Button("Done") { agreement=nil }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(20).frame(width:650,height:560)
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

import SwiftUI
import PlaydockCore

struct WindowsAppsView: View {
    @ObservedObject var model: LauncherModel
    let profile: RuntimeProfile
    @State private var confirmForceQuit=false
    @State private var forceTargets: [RuntimeProcessIdentity.WindowsProcess] = []

    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:14) {
                Image(systemName:"app.badge.checkmark").font(.system(size:28)).foregroundStyle(PlaydockTheme.accent)
                VStack(alignment:.leading,spacing:5) {
                    Text("Windows apps").font(.title2.weight(.semibold))
                    Text(profile.name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("Review apps in this non-Steam environment. Save your progress before closing a game.")
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if model.windowsAppsLoading {
                        HStack { ProgressView().controlSize(.small); Text("Checking this environment…") }
                    } else if model.windowsApps.isEmpty {
                        Label("No Windows apps are running.",systemImage:"checkmark.circle")
                            .foregroundStyle(PlaydockTheme.accent).padding(.vertical,14)
                    } else {
                        ForEach(model.windowsApps) { app in
                            HStack(spacing:12) {
                                Image(systemName:"app").foregroundStyle(.secondary)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(model.windowsAppName(app)).font(.system(size:13,weight:.medium))
                                    Text("\(app.program) · Process \(app.token.pid)").font(.system(size:10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(12).glassPanel(radius:12)
                        }
                    }
                    if !model.windowsAppsMessage.isEmpty {
                        Text(model.windowsAppsMessage).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if model.windowsAppsBusy { ProgressView().controlSize(.small) }
                }.font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading)
            }
            Text("Only the listed apps in this environment are closed. Windows services keep running.")
                .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:10) {
                Button("Cancel") { model.closeWindowsApps() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if model.windowsAppsCanForceQuit,!model.windowsApps.isEmpty {
                    Button("Force quit…") {
                        forceTargets=model.windowsApps; confirmForceQuit=true
                    }.buttonStyle(QuietButtonStyle()).disabled(model.windowsAppsBusy)
                }
                Button("Close apps") {
                    model.closeManagedWindowsApps()
                }.buttonStyle(PlayButtonStyle()).disabled(model.windowsAppsBusy || model.windowsAppsLoading || model.windowsApps.isEmpty)
            }
        }.padding(26).frame(width:560,height:min(480,max(320,(NSApp.keyWindow?.screen?.visibleFrame.height ?? 700)-140)))
        .background(PlaydockTheme.background)
        .background(DialogEscapeHandler { model.closeWindowsApps() }.allowsHitTesting(false))
        .onExitCommand { model.closeWindowsApps() }
        .alert("Force quit Windows apps?",isPresented:$confirmForceQuit) {
            Button("Cancel",role:.cancel) {}
            Button("Force quit",role:.destructive) { model.closeManagedWindowsApps(force:true,reviewedApps:forceTargets) }
        } message: {
            Text("\(forceTargets.map{model.windowsAppName($0)}.joined(separator:", ")) will close immediately. Unsaved progress may be lost.")
        }
        .task {
            while !Task.isCancelled {
                await model.refreshWindowsApps()
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
            }
        }
    }
}

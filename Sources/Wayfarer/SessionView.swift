import SwiftUI
import AppKit

struct SessionView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var session: EmbeddedSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Circle().fill(session.rendering ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(session.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Mac Steam") { model.openSteamClient(.macOS) }.help("Open Mac Steam for login and account settings")
                if session.windows.count > 1 {
                    Picker("Window", selection: Binding(get: { session.selectedWindowID ?? "" }, set: { session.chooseWindow($0) })) {
                        ForEach(session.windows) { item in Text(item.title).tag(item.id) }
                    }.labelsHidden().frame(maxWidth: 230)
                }
                if !model.showingCouch {
                    Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full screen")
                }
                if session.context != nil {
                    Menu {
                        Button(model.selectedProfile?.reusesExistingSteam == true ? "Disconnect from Steam" : "Stop Steam and games") { model.disconnectSession() }
                    } label: { Image(systemName: "ellipsis") }
                }
            }.padding(.horizontal, 18).padding(.vertical, 14)
                .background(.white.opacity(0.025))
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            ZStack {
                Color.black
                SessionSurface(surface: session.surface)
                if !session.rendering {
                    VStack(spacing: 22) {
                        WayfarerMark().scaleEffect(1.5).padding(.bottom, 10)
                        if session.context == nil {
                            Text("Sign in once. Play from Wayfarer.").font(.system(size: 27, weight: .semibold))
                            Text("Sign in to Windows Steam here, then browse and play\nfrom Wayfarer’s native library.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button(model.steamExecutable == nil ? "Set up Steam" : "Open Steam") { model.launchSteam() }
                                .buttonStyle(ControllerButtonStyle(style: .borderedProminent)).disabled(model.selectedProfile == nil || model.installing)
                        } else if model.selectedProfile?.reusesExistingSteam == true {
                            Text("Your existing Steam session").font(.system(size:27,weight:.semibold))
                            Text("Browse, install and play from Wayfarer.\nOpen Steam here for login and account settings.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Open Steam") { model.launchSteam() }.buttonStyle(ControllerButtonStyle(style: .borderedProminent))
                        } else if model.installing {
                            ProgressView().controlSize(.large)
                            Text(model.setupMessage).font(.title3).multilineTextAlignment(.center).frame(maxWidth: 460)
                            Text("Steam's own sign-in screen will open when setup finishes.\nUse your Steam account and Steam Guard to log in.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Cancel setup") { model.disconnectSession() }
                        } else if let error = session.error {
                            Text("Cannot display the session").font(.title2)
                            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                            Button("Restart Steam") { model.disconnectSession(); model.launchSteam() }
                        } else {
                            ProgressView().controlSize(.large)
                            Text(session.message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 450)
                            Button("Refresh session") { session.retry() }
                        }
                    }.padding(32)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.rendering {
                HStack {
                    Text("Click the session to use your keyboard and mouse.")
                    Spacer()
                    Text("⌘Q exits Wayfarer").foregroundStyle(.tertiary)
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .glassPanel(radius: 20)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onDisappear { session.surface.releaseInput() }
    }

}

private struct SessionSurface: NSViewRepresentable {
    let surface: SessionSurfaceView
    func makeNSView(context: Context) -> SessionSurfaceView { surface }
    func updateNSView(_ nsView: SessionSurfaceView, context: Context) {}
    static func dismantleNSView(_ nsView: SessionSurfaceView, coordinator: ()) { nsView.releaseInput() }
}

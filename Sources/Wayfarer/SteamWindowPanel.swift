import SwiftUI
import AppKit

struct SteamWindowPanel:View {
    @ObservedObject var model:LauncherModel
    @ObservedObject var session:SteamWindowSession
    let request:SteamUIRequest
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Label(request.title,systemImage:request.destination == .chat ? "bubble.left.and.bubble.right" : "person.crop.circle").font(.headline)
                Spacer()
                if session.windows.count>1 {
                    Picker("Steam window",selection:Binding(get:{session.selectedWindowID ?? 0},set:{session.chooseWindow($0)})) {
                        ForEach(session.windows) { window in Text(window.title).tag(window.id) }
                    }.labelsHidden().frame(maxWidth:220)
                }
                Button("Done") { session.end(); model.steamUIRequest=nil }.buttonStyle(QuietButtonStyle())
            }.padding(20)
            Divider()
            ZStack {
                Color.black
                SharedSteamSurface(surface:session.surface)
                if !session.capturing {
                    VStack(spacing:14) {
                        WayfarerMark()
                        Text(request.destination == .chat ? "Your Steam chats, here" : "Steam, inside Wayfarer").font(.title2.weight(.semibold))
                        if !session.hasScreenPermission || !session.hasInputPermission {
                            Text("Allow macOS to display and control your Steam window here.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                            permission("Display Steam",detail:"Screen Recording",granted:session.hasScreenPermission,action:session.requestScreenPermission)
                            permission("Control Steam",detail:"Accessibility",granted:session.hasInputPermission,action:session.requestInputPermission)
                            VStack(spacing:8) {
                                Text("Already enabled in System Settings? Remove the old entry and add this copy of Wayfarer.")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Show this Wayfarer app") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                                    .buttonStyle(.link)
                            }
                            Text("Window sharing stays on this Mac. Wayfarer does not save screen recordings.").font(.caption).foregroundStyle(.secondary)
                            Button("Check permissions") { session.retry() }.buttonStyle(QuietButtonStyle())
                        } else {
                            ProgressView()
                            Text(session.error ?? session.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Retry") { session.retry() }.buttonStyle(QuietButtonStyle())
                        }
                    }.padding(32).frame(maxWidth:520)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack {
                Text(session.capturing ? (request.destination == .chat ? "Friends, messages and group chats use your Steam account." : "Use Steam here for login and required confirmations.") : "Steam continues running in the background.")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(14)
        }.frame(width:1000,height:740).background(WayfarerTheme.background)
        .task { session.begin(request,presentWindow:{ model.session.backend.present(root:request.root,prefix:request.prefix,in:$0) }) { model.displaySteamWindow(request) } }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshPermissions()
        }
        .onDisappear { session.end() }
    }
    private func permission(_ title:String,detail:String,granted:Bool,action:@escaping()->Void)->some View {
        HStack(spacing:14) {
            Image(systemName:granted ? "checkmark.circle.fill" : "lock.shield").foregroundStyle(WayfarerTheme.accent)
            VStack(alignment:.leading,spacing:4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(granted ? "Allowed" : "Allow…",action:action).disabled(granted).buttonStyle(QuietButtonStyle())
        }.padding(16).glassPanel(radius:14)
    }
}
private struct SharedSteamSurface:NSViewRepresentable {
    let surface:SteamSharedSurfaceView
    func makeNSView(context:Context)->SteamSharedSurfaceView { surface }
    func updateNSView(_ view:SteamSharedSurfaceView,context:Context) {}
    static func dismantleNSView(_ view:SteamSharedSurfaceView,coordinator:()) { view.releaseInput() }
}

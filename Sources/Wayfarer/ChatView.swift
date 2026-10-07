import SwiftUI
import WayfarerCore

struct ChatView: View {
    @ObservedObject var model: LauncherModel
    @State private var search=""
    private var client:GamePlatform { model.friendsClient }
    private var friends:[SteamFriend] {
        (model.friendsSnapshots[client]?.friends ?? []).filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.game.localizedCaseInsensitiveContains(search)}.sorted {
            if $0.unread != $1.unread { return $0.unread > $1.unread }
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Picker("Steam account",selection:$model.friendsClient) { ForEach(GamePlatform.allCases.filter{$0 == .windows || model.includesMacSteam},id:\.self) { Text("\($0.name) Steam").tag($0) } }.frame(width:235)
                Label(model.connectionMode(client).title,systemImage:model.connectionMode(client) == .online ? "network" : "network.slash").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.refreshFriends(client) } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(QuietButtonStyle()).disabled(model.friendsBusy.contains(client))
                Button("Open chat") { model.openSteamClient(client,destination:.chat) }.buttonStyle(QuietButtonStyle())
            }
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Search friends",text:$search).textFieldStyle(.plain)
                Spacer()
                Text("\(friends.filter(\.isOnline).count) online · \(friends.count) friends").font(.caption).foregroundStyle(.secondary)
            }.padding(14).glassPanel(radius:12)
            HStack {
                Toggle("Chat notifications",isOn:Binding(get:{model.configuration.friendNotifications ?? false},set:{model.setFriendNotifications($0)})).toggleStyle(ControllerToggleStyle(style: .switch))
                Spacer(); Text("Presence and unread counts come from Steam.").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            if let message=model.friendsMessages[client] {
                HStack {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if model.connectionMode(client) == .offline { Button("Go online") { model.setSteamMode(client,offline:false) } }
                    else { Button("Load Steam Friends") { model.loadFriendsEngine(client) }.disabled(model.connectionBusy.contains(client)) }
                }.padding(20).glassPanel(radius:16)
            }
            if model.friendsBusy.contains(client) { ProgressView("Updating friends…").controlSize(.small) }
            if friends.isEmpty && model.friendsSnapshots[client]?.ready == true {
                Text(search.isEmpty ? "No friends on this Steam account yet." : "No friends match your search.").foregroundStyle(.secondary).padding(.vertical,30)
            }
            ForEach(friends) { friend in
                HStack(spacing:14) {
                    Text(String(friend.name.prefix(1)).uppercased()).font(.title2).frame(width:44,height:44).background(WayfarerTheme.accent.opacity(0.12),in:RoundedRectangle(cornerRadius:12))
                    VStack(alignment:.leading,spacing:5) { Text(friend.name).font(.headline); HStack(spacing:6) { Circle().fill(friend.isOnline ? WayfarerTheme.accent : Color.gray).frame(width:6,height:6); Text(friend.presence).font(.caption).foregroundStyle(.secondary) } }
                    Spacer()
                    if friend.unread>0 { Text("\(friend.unread)").font(.caption.bold()).padding(7).background(WayfarerTheme.accent.opacity(0.18),in:Capsule()).accessibilityLabel("\(friend.unread) unread messages") }
                    Button("Chat") { model.openSteamClient(client,destination:.chat,friendID:friend.id) }.buttonStyle(QuietButtonStyle())
                }.padding(16).glassPanel(radius:14)
            }
            if model.session.prefersChat,model.selectedProfile?.reusesExistingSteam == false { SessionView(model:model,session:model.session).frame(height:500) }
        }
        .onAppear { if !model.includesMacSteam { model.friendsClient = .windows }; model.refreshFriends(client) }
        .onChange(of:model.connectionMode(client)) { _ in model.refreshFriends(client) }
        .onChange(of:client) { _ in model.refreshFriends(client) }
    }
}

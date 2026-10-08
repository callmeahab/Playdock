import SwiftUI
import ImageIO
import PlaydockCore

struct ChatView: View {
    @ObservedFeatures var model: LauncherModel

    init(model: LauncherModel) {
        self._model = ObservedFeatures(wrappedValue: model, [.settings, .social, .steam])
    }
    @State private var search=""
    private var friends:[SteamFriend] {
        (model.socialState.snapshot?.friends ?? []).filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.game.localizedCaseInsensitiveContains(search)}.sorted {
            if $0.unread != $1.unread { return $0.unread > $1.unread }
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Text("Steam Friends").font(.headline)
                Label(connection.title,systemImage:connection == .connected ? "network" : "network.slash").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.refreshFriends() } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(QuietButtonStyle()).disabled(model.socialState.busy)
                Link("Web chat", destination: URL(string: "https://steamcommunity.com/chat/")!).buttonStyle(QuietButtonStyle())
            }
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Search friends",text:$search).textFieldStyle(.plain)
                Spacer()
                Text(countLabel).font(.caption).foregroundStyle(.secondary)
            }.padding(14).glassPanel(radius:12)
            HStack {
                Toggle("Chat notifications",isOn:Binding(get:{model.settingsState.configuration.friendNotifications},set:{model.setFriendNotifications($0)})).toggleStyle(ControllerToggleStyle(style: .switch))
                Spacer(); Text("Presence and unread counts come from Steam.").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            if let message=model.socialState.message {
                HStack {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if model.connectionMode() == .offline { Button("Go online") { model.setSteamMode(offline:false) } }
                    else if !model.socialState.busy { Button("Retry connection") { model.loadFriendsEngine() }.disabled(model.steamState.busy) }
                }.padding(20).glassPanel(radius:16)
            }
            if model.socialState.busy { ProgressView("Updating friends…").controlSize(.small) }
            if friends.isEmpty && model.socialState.snapshot?.ready == true {
                Text(search.isEmpty ? "No friends on this Steam account yet." : "No friends match your search.").foregroundStyle(.secondary).padding(.vertical,30)
            }
            LazyVStack(spacing: 14) {
            ForEach(friends) { friend in
                HStack(spacing:14) {
                    FriendAvatar(friend: friend)
                    VStack(alignment:.leading,spacing:5) { Text(friend.name).font(.headline); HStack(spacing:6) { Circle().fill(friend.isOnline ? PlaydockTheme.accent : Color.gray).frame(width:6,height:6); Text(friend.presence).font(.caption).foregroundStyle(.secondary) } }
                    Spacer()
                    if friend.unread>0 { Text("\(friend.unread)").font(.caption.bold()).padding(7).background(PlaydockTheme.accent.opacity(0.18),in:Capsule()).accessibilityLabel("\(friend.unread) unread messages") }
                    if let url = URL(string: "https://steamcommunity.com/profiles/\(friend.id)") {
                        Link("View profile", destination: url).buttonStyle(QuietButtonStyle())
                    }
                }.padding(16).glassPanel(radius:14)
            }
            }
        }
        .task {
            model.refreshFriends()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }
                if NSApp.isActive { model.refreshFriends() }
            }
        }
        .onChange(of:model.connectionMode()) { _ in model.refreshFriends() }
    }
    private var connection: SteamFriendsConnection {
        model.socialState.snapshot?.connection ?? (model.connectionMode() == .offline ? .offline : .connecting)
    }
    private var countLabel: String {
        let snapshot = model.socialState.snapshot
        if !search.isEmpty { return "\(friends.count) matches" }
        guard let snapshot else { return "Loading friends…" }
        guard snapshot.ready else {
            if snapshot.total == 0 { return connection == .offline ? "Go online to load friends" : "Loading friends…" }
            return "\(snapshot.total) friends · \(connection == .connected ? "Presence updating" : "Presence unavailable")"
        }
        return "\(friends.filter(\.isOnline).count) online · \(snapshot.total) friends"
    }
}

private struct FriendAvatar: View {
    let friend: SteamFriend
    @State private var image: CGImage?
    private var source: URL? { friend.avatarURL.flatMap { SteamFriend.avatarURL($0.absoluteString) } }
    var body: some View {
        ZStack {
            PlaydockTheme.accent.opacity(0.12)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Text(String(friend.name.prefix(1)).uppercased()).font(.title2) }
        }
        .frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
        .task(id: source) {
            image = nil
            guard let source else { return }
            let loaded = await FriendAvatarLoader.shared.load(source)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private final class FriendAvatarEntry: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private actor FriendAvatarLoader {
    static let shared = FriendAvatarLoader()
    private let cache: NSCache<NSURL, FriendAvatarEntry> = {
        let value = NSCache<NSURL, FriendAvatarEntry>(); value.countLimit = 256; value.totalCostLimit = 16 * 1024 * 1024; return value
    }()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 10
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
    private var pending: [URL: Task<CGImage?, Never>] = [:]
    func load(_ url: URL) async -> CGImage? {
        guard SteamFriend.avatarURL(url.absoluteString) != nil else { return nil }
        if let saved = cache.object(forKey: url as NSURL) { return saved.image }
        if let request = pending[url] { return await request.value }
        let request = Task { await download(url) }; pending[url] = request
        let image = await request.value; pending[url] = nil
        if let image { cache.setObject(FriendAvatarEntry(image), forKey: url as NSURL, cost: image.width * image.height * 4) }
        return image
    }
    private func download(_ url: URL) async -> CGImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

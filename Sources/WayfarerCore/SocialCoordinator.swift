import Foundation

public struct SocialUpdate: Sendable {
    public let snapshot: SteamFriendsSnapshot?
    public let newUnread: [SteamFriend]
    public let message: String?
    public var refreshing: Bool = false
}

/// Account-scoped unread baselines survive view changes.
public actor SocialCoordinator {
    private var scope: String?
    private var revision = 0
    private var unread: [String: Int] = [:]
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private var stopped = false
    private var retired: [Task<Void, Never>] = []
    private let retryDelay: Duration
    private var snapshot: SteamFriendsSnapshot?
    public init(retryDelay: Duration = .milliseconds(500)) { self.retryDelay = retryDelay }
    public func refresh(scope: String, revision: Int, mode: SteamConnectionMode,
                        fetch: @escaping @Sendable () async throws -> SteamFriendsSnapshot,
                        publish: @escaping @Sendable (SocialUpdate) async -> Void) {
        guard !stopped, revision >= self.revision else { return }
        if revision > self.revision || self.scope != scope { reset(revision: revision); self.scope = scope }
        guard task == nil else { return }
        let id = UUID(); operation = id
        task = Task {
            defer { if operation == id { task = nil } }
            guard mode == .online || mode == .offline else {
                await publish(SocialUpdate(snapshot: nil, newUnread: [], message: "Connect and sign in to Steam.")); return
            }
            do {
                for attempt in 0..<10 {
                    let received = try await fetch()
                    guard !Task.isCancelled, operation == id, self.scope == scope else { return }
                    let snapshot = merge(received)
                    let increased = ingest(snapshot, scope: scope)
                    let retry = !snapshot.ready && [.connecting, .connected].contains(snapshot.connection) && attempt < 9
                    let message: String?
                    switch snapshot.connection {
                    case .offline: message = "Go online to update your friends’ presence."
                    case .unavailable: message = "Friends are unavailable. Retry the connection."
                    case .connecting: message = "Connecting to Steam Friends…"
                    case .connected: message = snapshot.ready ? nil : "Loading friends · \(snapshot.friends.count) of \(snapshot.total)"
                    }
                    await publish(SocialUpdate(snapshot: snapshot, newUnread: increased, message: message, refreshing: retry))
                    guard retry else { return }
                    try await Task.sleep(for: retryDelay)
                }
            } catch {
                guard !Task.isCancelled, operation == id else { return }
                let unavailable = merge(SteamFriendsSnapshot(ready: false, friends: [], connection: .unavailable))
                await publish(SocialUpdate(snapshot: unavailable, newUnread: [], message: "Friends are unavailable. Retry the connection."))
            }
        }
    }
    private func merge(_ received: SteamFriendsSnapshot) -> SteamFriendsSnapshot {
        var result = received
        if !received.ready, let previous = snapshot {
            let incoming = Set(received.friends.map(\.id))
            result.friends += previous.friends.filter { !incoming.contains($0.id) }.map {
                SteamFriend(id: $0.id, name: $0.name, state: nil, game: "", unread: $0.unread, avatarURL: $0.avatarURL)
            }
            result.total = max(received.total, result.friends.count)
        }
        snapshot = result
        return result
    }
    func ingest(_ snapshot: SteamFriendsSnapshot, scope: String) -> [SteamFriend] {
        if self.scope != scope { self.scope = scope; unread = [:] }
        guard snapshot.ready else { return [] }
        let increased = snapshot.friends.filter { friend in unread[friend.id].map { friend.unread > $0 } ?? false }
        unread = Dictionary(uniqueKeysWithValues: snapshot.friends.map { ($0.id, $0.unread) })
        return increased
    }
    public func invalidate(revision: Int) {
        guard revision > self.revision else { return }
        reset(revision: revision)
    }
    private func reset(revision: Int) {
        self.revision = revision; operation = UUID(); if let task { retired.append(task) }; task?.cancel(); task = nil; scope = nil; unread = [:]; snapshot = nil
    }
    public func stop() async {
        stopped = true
        let pending = task
        invalidate(revision: revision + 1)
        await pending?.value
        for task in retired { await task.value }
    }
}

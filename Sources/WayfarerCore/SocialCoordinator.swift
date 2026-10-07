import Foundation

public struct SocialUpdate: Sendable {
    public let snapshot: SteamFriendsSnapshot?
    public let newUnread: [SteamFriend]
    public let message: String?
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
    public init() {}
    public func refresh(scope: String, revision: Int, mode: SteamConnectionMode,
                        fetch: @escaping @Sendable () async throws -> SteamFriendsSnapshot,
                        publish: @escaping @Sendable (SocialUpdate) async -> Void) {
        guard !stopped, revision >= self.revision else { return }
        if revision > self.revision || self.scope != scope { invalidate(revision: revision); self.scope = scope }
        guard task == nil else { return }
        let id = UUID(); operation = id
        task = Task {
            defer { if operation == id { task = nil } }
            guard mode == .online else {
                await publish(SocialUpdate(snapshot: nil, newUnread: [], message: mode == .offline ? "Go online to see your friends." : "Connect and sign in to Steam.")); return
            }
            do {
                let snapshot = try await fetch()
                guard !Task.isCancelled, operation == id, self.scope == scope else { return }
                let increased = ingest(snapshot, scope: scope)
                await publish(SocialUpdate(snapshot: snapshot, newUnread: increased,
                    message: snapshot.ready ? nil : "Friends are still connecting. Load Steam Friends to retry."))
            } catch {
                guard !Task.isCancelled, operation == id else { return }
                await publish(SocialUpdate(snapshot: nil, newUnread: [], message: "Friends are unavailable. Load Steam Friends or open chat to reconnect."))
            }
        }
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
        self.revision = revision; operation = UUID(); if let task { retired.append(task) }; task?.cancel(); task = nil; scope = nil; unread = [:]
    }
    public func stop() async {
        stopped = true
        let pending = task
        invalidate(revision: revision + 1)
        await pending?.value
        for task in retired { await task.value }
    }
}

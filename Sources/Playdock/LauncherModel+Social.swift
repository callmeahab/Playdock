import AppKit
import Foundation
import PlaydockCore
import PlaydockPresentation
import UserNotifications

extension LauncherModel {
    func refreshFriends() {
        guard !runtimeState.bridgeBusy, !shuttingDown, !socialState.busy else { return }
        socialState.busy = true
        let revision = workflowRevision
        Task { [weak self] in
            guard let self else { return }
            await refreshSteamAccount()
            guard !shuttingDown, workflowRevision == revision else { return }
            let key = downloadPolicyKey(), mode = connectionMode()
            await socialState.coordinator.refresh(scope: key, revision: revision, mode: mode,
                fetch: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchFriends(key: key, revision: revision)
                }, publish: { [weak self] update in
                    await self?.applySocialUpdate(update, key: key, revision: revision)
                })
        }
    }
    func fetchFriends(key: String, revision: Int) async throws -> SteamFriendsSnapshot {
        guard !shuttingDown, workflowRevision == revision, downloadPolicyKey() == key else { throw CancellationError() }
        return try await controlClient().friends()
    }
    func applySocialUpdate(_ update: SocialUpdate, key: String, revision: Int) {
        guard !shuttingDown, workflowRevision == revision else { return }
        if !update.refreshing { socialState.busy = false }
        guard downloadPolicyKey() == key else { socialState.snapshot = nil; return }
        if socialState.snapshot != update.snapshot { socialState.snapshot = update.snapshot }
        if socialState.message != update.message { socialState.message = update.message }
        if settingsState.configuration.friendNotifications == true {
            for friend in update.newUnread { notifyUnread(friend) }
        }
    }
    func loadFriendsEngine() {
        connectSteam()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.waitForSteamConnection()
                guard self.connectionMode() == .online else { self.refreshFriends(); return }
                try await self.controlClient().reconnectFriends()
                self.refreshFriends()
            } catch { self.socialState.message=error.localizedDescription }
        }
    }
    func showFriends() { chatRequest=UUID() }
    var unreadFriendsCount: Int { socialState.snapshot?.friends.reduce(0) { $0 + $1.unread } ?? 0 }
    func setFriendNotifications(_ enabled:Bool) {
        if !enabled { settingsState.configuration.friendNotifications=false; save(); return }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]) { [weak self] granted,_ in
            Task { @MainActor in self?.settingsState.configuration.friendNotifications=granted; self?.save(); if !granted { self?.error="Allow notifications for Playdock in System Settings to receive chat alerts." } }
        }
    }
    func notifyUnread(_ friend:SteamFriend) {
        let content=UNMutableNotificationContent(); content.title="New Steam chat"; content.body="\(friend.name) · \(friend.unread) unread \(friend.unread==1 ? "message" : "messages")"; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"playdock-chat-\(friend.id)",content:content,trigger:nil))
    }
}

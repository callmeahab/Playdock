import AppKit
import UserNotifications
import PlaydockCore

@MainActor
final class SteamNotifications: NSObject, UNUserNotificationCenterDelegate {
    weak var model: LauncherModel?
    init(model:LauncherModel) { self.model=model; super.init() }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.sound]) }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void) {
        let client=response.notification.request.content.userInfo["playdockChatClient"] as? String
        Task { @MainActor [weak self] in if let client,let platform=GamePlatform(rawValue:client) { self?.model?.friendsClient=platform }; self?.model?.showFriends(); NSApp.activate(ignoringOtherApps:true) }
        completionHandler()
    }
}

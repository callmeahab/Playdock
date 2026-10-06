import Foundation
import WayfarerCore

/// Read-only integration validation. Prints counts and public app IDs only.
@main struct PlayFeaturesReadProbe {
    static func main() async {
        let discovery=RuntimeDiscovery(),runtimes=discovery.installations(),profiles=discovery.profiles(for:runtimes)
        let configuration=(try? ConfigurationStore().load()) ?? LauncherConfiguration()
        for platform in GamePlatform.allCases {
            let prefix=platform == .windows ? RuntimeDiscovery.preferredProfile(profiles,selectedID:configuration.selectedProfileID)?.prefix:nil
            let root:URL
            if platform == .windows {
                guard let profile=RuntimeDiscovery.preferredProfile(profiles,selectedID:configuration.selectedProfileID),let steam=profile.steamExecutable else{continue};root=steam.deletingLastPathComponent()
            }else{root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")}
            let port=prefix.flatMap{SteamControlEndpoint.runningWindowsPort(root:root,prefix:$0)} ?? (platform == .macOS ? SteamControlEndpoint.runningMacPort(root:root):nil)
            guard let port else{print(platform.name,"backend unavailable");continue}
            let control=SteamControl(endpoint:SteamControlEndpoint(port:port,root:root,prefix:prefix))
            do {
                let snapshot=try await control.snapshot(),folders=try await control.storageFolders(),running=try await control.runningAppIDs()
                print(platform.name,"mode:",snapshot.mode.title,"libraries:",folders.count,"installed:",folders.reduce(0){$0+$1.apps.count},"running:",running.count)
                let scan=prefix.map{SteamLibrary.scan(steamExecutable:root.appendingPathComponent("steam.exe"),prefix:$0)} ?? SteamLibrary.scanMac(root:root)
                if let appID=running.first ?? scan.games.first?.appID {
                    do{let achievements=try await control.achievements(appID:appID);print("Achievements for",appID,"count:",achievements.count,"unlocked:",achievements.filter{$0.achieved}.count)}catch{print("Achievements not provided for",appID)}
                }
            }catch{print(platform.name,"read failed:",error.localizedDescription)}
        }
    }
}

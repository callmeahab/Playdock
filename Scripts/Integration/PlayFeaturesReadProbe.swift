import Foundation
import PlaydockCore

/// Read-only integration validation. Prints counts and public app IDs only.
@main struct PlayFeaturesReadProbe {
    static func main() async {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        let port=SteamControlEndpoint.runningMacPort(root:root)
        guard let port else{print("Mac","backend unavailable");return}
        let control=SteamControl(endpoint:SteamControlEndpoint(port:port,root:root))
        do {
            let snapshot=try await control.snapshot(),folders=try await control.storageFolders(),running=try await control.runningAppIDs()
            print("Mac","mode:",snapshot.mode.title,"libraries:",folders.count,"installed:",folders.reduce(0){$0+$1.apps.count},"running:",running.count)
            let scan=SteamLibrary.scanMac(root:root)
            if let appID=running.first ?? scan.games.first?.appID {
                do{let achievements=try await control.achievements(appID:appID);print("Achievements for",appID,"count:",achievements.count,"unlocked:",achievements.filter{$0.achieved}.count)}catch{print("Achievements not provided for",appID)}
            }
        }catch{print("Mac","read failed:",error.localizedDescription)}
    }
}

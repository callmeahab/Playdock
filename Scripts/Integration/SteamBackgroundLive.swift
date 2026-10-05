import AppKit
import CryptoKit
import WayfarerCore

@main struct SteamBackgroundLive {
    static func main() {
        let discovery=RuntimeDiscovery(),config=(try? ConfigurationStore().load()) ?? LauncherConfiguration()
        let profiles=discovery.profiles(for:discovery.installations())
        let profile=RuntimeDiscovery.preferredProfile(profiles,selectedID:config.selectedProfileID)
        if let profile { print("PROFILE=\(profile.name) REUSED=\(profile.reusesExistingSteam) PREFIX=\(profile.prefix.path)") }
        let macRoot=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        if CommandLine.arguments.contains("--exercise-hidden-mac") {
            let hash=SHA256.hash(data:Data(macRoot.resolvingSymlinksInPath().path.utf8)).map { String(format:"%02x",$0) }.joined()
            let directory=AppPaths.support.appendingPathComponent("SteamBackend/\(hash)")
            let adapter=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("DerivedData/Build/Products/Debug/libWayfarerWineDisplay.dylib")
            let child=Process(); child.executableURL=macRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
            child.arguments=["-silent","steam://open/main"]; child.currentDirectoryURL=macRoot
            child.environment=ProcessInfo.processInfo.environment.merging(["DYLD_INSERT_LIBRARIES":adapter.path,"WAYFARER_STEAM_BACKEND":directory.path]) { _,new in new }
            child.standardOutput=FileHandle.nullDevice; child.standardError=FileHandle.nullDevice
            try! child.run(); Thread.sleep(forTimeInterval:2)
        }
        let scopes:[(String,URL,URL?)]=[("Mac",macRoot,nil)]+(profile?.steamExecutable.map { [("Windows",$0.deletingLastPathComponent(),profile!.prefix)] } ?? [])
        let info=(CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]]) ?? []
        for (platform,root,prefix) in scopes {
            let key=(prefix ?? root).resolvingSymlinksInPath().path
            let hash=SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
            let directory=AppPaths.support.appendingPathComponent("SteamBackend/\(hash)")
            for app in NSWorkspace.shared.runningApplications where RuntimeProcessIdentity.isSteamClient(pid:app.processIdentifier,root:root,prefix:prefix) {
                let pid=app.processIdentifier,token=RuntimeProcessIdentity.token(for:pid)
                let ready=try? String(contentsOf:directory.appendingPathComponent("\(pid).ready"),encoding:.utf8)
                let attached=token.map { ready?.components(separatedBy:"\n").first=="\($0.startedSeconds):\($0.startedMicroseconds)" } ?? false
                let windows=info.filter { ($0[kCGWindowOwnerPID as String] as? Int32)==pid && ($0[kCGWindowLayer as String] as? Int)==0 }.map {
                    ["alpha":$0[kCGWindowAlpha as String] ?? -1,"onscreen":$0[kCGWindowIsOnscreen as String] ?? false,"bounds":$0[kCGWindowBounds as String] ?? [:]] as [String:Any]
                }
                let value:[String:Any]=["platform":platform,"pid":pid,"policy":app.activationPolicy.rawValue,"attached":attached,"executable":app.executableURL?.lastPathComponent ?? "","windows":windows]
                print(String(decoding:try! JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self))
            }
        }
    }
}

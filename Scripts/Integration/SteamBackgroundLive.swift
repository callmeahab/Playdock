import AppKit
import CryptoKit
import WayfarerCore

@main struct SteamBackgroundLive {
    static func main() {
        let macRoot=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        if CommandLine.arguments.contains("--exercise-hidden-mac") {
            let hash=SHA256.hash(data:Data(macRoot.resolvingSymlinksInPath().path.utf8)).map { String(format:"%02x",$0) }.joined()
            let directory=AppPaths.support.appendingPathComponent("SteamBackend/\(hash)")
            let adapter=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("DerivedData/Build/Products/Debug/libWayfarerWineDisplay.dylib")
            let child=Process(); child.executableURL=macRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
            child.arguments=["-silent","steam://open/main"]; child.currentDirectoryURL=macRoot
            child.environment=ProcessInfo.processInfo.environment.merging(["DYLD_INSERT_LIBRARIES":try! SteamBridgeInjection.libraries(adapter:adapter),"WAYFARER_STEAM_BACKEND":directory.path]) { _,new in new }
            child.standardOutput=FileHandle.nullDevice; child.standardError=FileHandle.nullDevice
            try! child.run(); Thread.sleep(forTimeInterval:2)
        }
        let info=(CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]]) ?? []
        let hash=SHA256.hash(data:Data(macRoot.resolvingSymlinksInPath().path.utf8)).map { String(format:"%02x",$0) }.joined()
        let directory=AppPaths.support.appendingPathComponent("SteamBackend/\(hash)")
        for app in NSWorkspace.shared.runningApplications where RuntimeProcessIdentity.isSteamClient(pid:app.processIdentifier,root:macRoot) {
            let pid=app.processIdentifier,token=RuntimeProcessIdentity.token(for:pid)
            let ready=try? String(contentsOf:directory.appendingPathComponent("\(pid).ready"),encoding:.utf8)
            let attached=token.map { ready?.components(separatedBy:"\n").first=="\($0.startedSeconds):\($0.startedMicroseconds)" } ?? false
            let windows=info.filter { ($0[kCGWindowOwnerPID as String] as? Int32)==pid && ($0[kCGWindowLayer as String] as? Int)==0 }.map {
                ["alpha":$0[kCGWindowAlpha as String] ?? -1,"onscreen":$0[kCGWindowIsOnscreen as String] ?? false,"bounds":$0[kCGWindowBounds as String] ?? [:]] as [String:Any]
            }
            let value:[String:Any]=["platform":"Mac","pid":pid,"policy":app.activationPolicy.rawValue,"attached":attached,"executable":app.executableURL?.lastPathComponent ?? "","windows":windows]
            print(String(decoding:try! JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self))
        }
    }
}

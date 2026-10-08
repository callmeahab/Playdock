import Foundation
import Darwin

public enum SteamConnectionMode: String, Codable, Sendable {
    case online, offline, signedOut, unavailable
    public var title: String { switch self { case .online: return "Online"; case .offline: return "Offline Mode"; case .signedOut: return "Sign in to Steam"; case .unavailable: return "Not connected" } }
}

public struct SteamInstallFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let path: String
    public let name: String
    public let freeBytes: UInt64
    public let isDefault: Bool
}
public struct SteamLiveDownload: Identifiable, Codable, Hashable, Sendable {
    public let appID: String
    public let name: String
    public let paused: Bool
    public let active: Bool
    public let downloaded: UInt64
    public let total: UInt64
    public let updateState: String?
    public let phaseDownloaded: UInt64?
    public let phaseTotal: UInt64?
    public let networkBytesPerSecond: UInt64?
    public let diskBytesPerSecond: UInt64?
    public let secondsRemaining: Int?
    public var id: String { appID }
}
public struct SteamControlSnapshot: Codable, Equatable, Sendable {
    public let mode: SteamConnectionMode
    public let folders: [SteamInstallFolder]
    public let downloads: [SteamLiveDownload]
    public let downloadsPaused: Bool
}
public struct SteamAppState: Codable, Sendable {
    public let appID:String
    public let installed:Bool
    public let owned:Bool
    public let displayStatus:Int
    public var isRunning:Bool { [1,4].contains(displayStatus) }
    public var isUninstalling:Bool { displayStatus == 2 }
}
public struct SteamGameLaunch: Codable, Equatable, Sendable {
    public let actionID: UInt32
    public let appID: String
    public let task: String
    public let waitingForUser: Bool
    public let request: String?
    public var isInformational: Bool { ["ShowInterstitials", "CreatingProcess"].contains(task) }
    public var confirmationMessage: String {
        switch (task, request) {
        case ("SynchronizingCloud", "syncfailed"): return "Steam could not synchronize this game’s saves. Playing without syncing may use outdated local saves."
        case ("SynchronizingCloud", "pendingcloudsessions"): return "Steam reports unsynchronized saves from another device. Finish syncing there before playing, or continue with this Mac’s saves."
        case ("SynchronizingCloud", "cloudconflict"): return "Local and Steam Cloud saves conflict. Playdock cannot resolve this conflict yet. Cancel this launch to keep both copies unchanged."
        case ("RunningInstallScript", _): return "Steam could not complete a first-launch component. You can continue, but the game may not work correctly."
        case ("KickingOtherSession", _): return "Steam reports a game running on another device. Continuing will end that device’s Steam session."
        default: return "Steam requires a confirmation that Playdock does not support yet. Cancel this launch before retrying."
        }
    }
    public var message: String {
        if waitingForUser { return "Steam needs confirmation before this game can start." }
        switch task {
        case "ProcessingInstallScript", "RunningInstallScript": return "Steam is preparing first-launch components…"
        case "SynchronizingCloud": return "Steam is synchronizing saves…"
        case "DownloadingDepots", "DownloadingWorkshop": return "Steam is finishing required downloads…"
        case "ProcessingShaderCache": return "Steam is preparing shaders…"
        default: return "Steam is preparing the game…"
        }
    }
}
public enum SteamLaunchResponse: String, Sendable {
    case acknowledge, playWithoutCloud, ignorePendingCloud, ignoreInstallError, endOtherSession, cancel
    func value(for launch: SteamGameLaunch) throws -> String {
        switch (self, launch.task, launch.request) {
        case (.cancel, _, _): return ""
        case (.acknowledge, "ShowInterstitials", _), (.acknowledge, "CreatingProcess", _): return launch.task
        case (.playWithoutCloud, "SynchronizingCloud", "syncfailed"): return "IgnoreCloud"
        case (.ignorePendingCloud, "SynchronizingCloud", "pendingcloudsessions"): return "IgnorePendingCloudSessions"
        case (.ignoreInstallError, "RunningInstallScript", _): return "IgnoreInstallError"
        case (.endOtherSession, "KickingOtherSession", _): return "KickOtherSession"
        default: throw PlaydockError.message("Review this launch confirmation in Steam.")
        }
    }
}
public struct SteamInstallPlan: Codable, Sendable {
    public let appID: String
    public let state: Int
    public let requiredBytes: UInt64
    public let availableBytes: UInt64
    public let folder: Int
    public let currentAppID: UInt32
    public let error: Int
    public let detail: String
    public let eulas: [SteamGameEULA]
    public var needsAgreement: Bool { !eulas.isEmpty }
    public var canConfirm: Bool { [7,8].contains(state) && error == 0 && requiredBytes <= availableBytes }
    public var failureMessage: String? {
        guard error != 0 || state == 15 else { return nil }
        switch error {
        case 5: return "Steam could not confirm a license for this game. Open Steam to check its account, then retry."
        case 6: return "Steam reports no internet connection for this installation. Check your connection, then retry."
        case 7: return "Steam’s download connection timed out. Retry to prepare the installation again."
        case 9: return "Steam could not load this game’s installation configuration. Retry to reload it."
        default: return "Steam could not prepare this installation (error \(error)). Open Steam to check it, then retry."
        }
    }
    public var confirmationMessage: String {
        if let failureMessage { return failureMessage }
        if requiredBytes > availableBytes { return "Choose a library with enough free space." }
        switch state {
        case 4: return "Steam needs a product-key confirmation. Open Steam to complete it, then retry."
        case 6: return "Steam needs a password confirmation. Open Steam to complete it, then retry."
        case 7,8: return "Choose a library and review any game agreements."
        default: return "Steam is preparing this installation. Retry to check its progress."
        }
    }
    public var hasStarted: Bool { [0,9,14].contains(state) && error == 0 }
}
public struct SteamGameEULA: Identifiable, Codable, Sendable {
    public let id: String
    public let version: UInt32
    public let url: URL
}

/// Runs fixed actions in Steam's local SharedJSContext, never caller-provided JavaScript.
public struct SteamControlEndpoint: Sendable {
    public let port: UInt16
    public let root: URL
    public init(port: UInt16, root: URL) { self.port=port; self.root=root }
    public static func availablePort() throws -> UInt16 {
        let fd=socket(AF_INET,SOCK_STREAM,0); guard fd>=0 else { throw CocoaError(.fileReadUnknown) }; defer { Darwin.close(fd) }
        var address=sockaddr_in(); address.sin_family=sa_family_t(AF_INET); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); address.sin_addr.s_addr=INADDR_LOOPBACK.bigEndian
        let bound=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        let read=withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        guard bound==0, read==0 else { throw CocoaError(.fileReadUnknown) }; return UInt16(bigEndian:address.sin_port)
    }
    public static func debuggerURL(_ text: String, port: UInt16) -> URL? {
        guard var parts=URLComponents(string:text), parts.scheme=="ws", ["127.0.0.1","localhost"].contains(parts.host ?? ""),
              parts.user==nil, parts.password==nil, parts.query==nil, parts.fragment==nil,
              parts.path.hasPrefix("/devtools/page/"), !parts.path.contains("..") else { return nil }
        parts.host="127.0.0.1"; parts.port=Int(port); return parts.url
    }
    public static func runningMacPort(root:URL) -> UInt16? {
        runningPort(root:root)
    }
    private static func runningPort(root:URL) -> UInt16? {
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
        process.arguments=["-nP","-a","-c","steamwebh","-c","Steam Hel","-iTCP","-sTCP:LISTEN","-Fn"]
        let pipe=Pipe(); process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard data.count<65536 else { return nil }
        for line in String(decoding:data,as:UTF8.self).split(separator:"\n").prefix(64) where line.hasPrefix("n127.0.0.1:") {
            guard let port=UInt16(line.dropFirst("n127.0.0.1:".count)), port>1024 else { continue }
            if (try? SteamControlEndpoint(port:port,root:root).validateOwner()) != nil { return port }
        }
        return nil
    }
    func validateOwner() throws {
        guard port>1024 else { throw SteamControl.failure }
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
        process.arguments=["-nP","-iTCP:\(port)","-sTCP:LISTEN","-Fpcn"]
        let pipe=Pipe(); process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        try process.run(); let output=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus==0, output.count<65536 else { throw SteamControl.failure }
        var pid:pid_t=0, command="", trusted=false
        for line in String(decoding:output,as:UTF8.self).split(separator:"\n") {
            if line.hasPrefix("p") { pid=pid_t(line.dropFirst()) ?? 0; command="" }
            if line.hasPrefix("c") { command=String(line.dropFirst()).replacingOccurrences(of:"\\x20",with:" ") }
            if line.hasPrefix("n") {
                guard line=="n127.0.0.1:\(port)" || line=="n[::1]:\(port)" else { throw SteamControl.failure }
                if command.lowercased().hasPrefix("steam hel") {
                    trusted = trusted || RuntimeProcessIdentity.belongsToPrefix(pid:pid,prefix:root)
                }
            }
        }
        guard trusted else { throw SteamControl.failure }
    }

}

public actor SteamControl {
    static var failure: PlaydockError { .message("Steam’s local connection is unavailable. Open Steam from Playdock and try again.") }
    private let endpoint: SteamControlEndpoint
    private let session: URLSession
    public init(endpoint: SteamControlEndpoint) {
        self.endpoint=endpoint
        let config=URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest=6; config.timeoutIntervalForResource=10
        config.httpCookieStorage=nil; config.urlCredentialStorage=nil; config.connectionProxyDictionary=[:]
        session=URLSession(configuration:config)
    }
    public func snapshot() async throws -> SteamControlSnapshot { try await perform(.snapshot, as:SteamControlSnapshot.self) }
    /// Unknown state blocks a background restart; never terminate a live game.
    public func setCrossOver(appID: String, enabled: Bool) async throws {
        let _: Ack = try await perform(.crossOver(try identifier(appID), enabled), as: Ack.self)
    }
    public func runningAppIDs() async throws -> [String] { try await perform(.runningApps,as:[String].self) }
    public func activeGameLaunches() async throws -> [SteamGameLaunch] { try await perform(.gameLaunches, as: [SteamGameLaunch].self) }
    public func respondToLaunch(_ launch: SteamGameLaunch, response: SteamLaunchResponse) async throws {
        _ = try identifier(launch.appID)
        guard launch.actionID > 0, launch.waitingForUser else { throw Self.failure }
        _ = try response.value(for: launch)
        let _: Ack = try await perform(.launchResponse(launch, response), as: Ack.self)
    }
    public func ownedGameIDs() async throws -> [String] { try await perform(.ownedGames,as:[String].self) }
    public func prepareInstall(appID: String) async throws -> SteamInstallPlan { try await perform(.prepareInstall(try identifier(appID)),as:SteamInstallPlan.self) }
    public func chooseFolder(appID: String, folder: Int) async throws -> SteamInstallPlan { try await perform(.folder(try identifier(appID),try folderIndex(folder)),as:SteamInstallPlan.self) }
    public func continueInstall(appID: String, agreements: [SteamGameEULA]=[]) async throws -> SteamInstallPlan { try await perform(.install(try identifier(appID),agreements),as:SteamInstallPlan.self) }
    public func cancelInstall(appID: String) async throws { let _: Ack = try await perform(.cancel(try identifier(appID)),as:Ack.self) }
    public func pause(appID: String, paused: Bool) async throws { let _: Ack = try await perform(.pause(try identifier(appID),paused),as:Ack.self) }
    public func enableDownloads(_ enabled: Bool) async throws { let _: Ack = try await perform(.downloads(enabled),as:Ack.self) }
    public func changeMode(offline: Bool) async throws { let _: Ack = try await perform(.mode(offline),as:Ack.self) }
    public func appState(appID:String) async throws -> SteamAppState { try await perform(.appState(try identifier(appID)),as:SteamAppState.self) }
    public func uninstall(appID:String) async throws {
        let _:Ack = try await perform(.uninstall(try identifier(appID)),as:Ack.self)
    }
    public func openFriend(_ steamID:String) async throws {
        guard let id=UInt64(steamID),id>76561197960265728,id<=76561197960265728+UInt64(UInt32.max) else { throw Self.failure }
        let _:Ack = try await perform(.openFriend(UInt32(id-76561197960265728)),as:Ack.self)
    }
    public func capabilities() async throws -> [String:Bool] { try await perform(.capabilities,as:[String:Bool].self) }
    public func friends() async throws -> SteamFriendsSnapshot { try await perform(.friends,as:SteamFriendsSnapshot.self) }
    public func reconnectFriends() async throws { let _: Ack = try await perform(.reconnectFriends, as: Ack.self) }
    public func downloadSettings() async throws -> SteamDownloadSettings { try await perform(.downloadSettings,as:SteamDownloadSettings.self) }
    public func applyDownloadPolicy(_ policy:DownloadPolicy) async throws {
        try policy.validate(); let _:Ack = try await perform(.settings(policy),as:Ack.self)
    }
    public func prioritize(appID:String,index:Int) async throws {
        guard (0..<1000).contains(index) else { throw Self.failure }
        let _:Ack = try await perform(.queue(try identifier(appID),index),as:Ack.self)
    }
    public func cloudStatus(appID:String) async throws -> SteamCloudStatus { try await perform(.cloud(try identifier(appID)),as:SteamCloudStatus.self) }
    public func terminateGame(appID:String) async throws { let _:Ack = try await perform(.terminateGame(try identifier(appID)),as:Ack.self) }
    public func storageFolders() async throws -> [SteamStorageFolder] { try await perform(.storageFolders,as:[SteamStorageFolder].self) }
    public func verifyFiles(appID:String) async throws { let _:Ack = try await perform(.verifyFiles(try identifier(appID)),as:Ack.self) }
    public func moveGame(appID:String,folder:Int) async throws { let _:Ack = try await perform(.moveGame(try identifier(appID),try folderIndex(folder)),as:Ack.self) }
    public func maintenanceProgress(appID:String) async throws -> SteamMaintenanceProgress { try await perform(.maintenanceProgress(try identifier(appID)),as:SteamMaintenanceProgress.self) }
    public func achievements(appID:String) async throws -> [SteamAchievement] { try await perform(.achievements(try identifier(appID)),as:[SteamAchievement].self) }
    public func workshop(appID: String) async throws -> SteamWorkshopSnapshot {
        try await perform(.workshop(try identifier(appID)), as: SteamWorkshopSnapshot.self)
    }
    public func changeWorkshop(appID: String, action: WorkshopAction) async throws {
        switch action {
        case .subscribe(let id, _), .enabled(let id, _):
            guard try WorkshopIdentifier.parse(id) == id else { throw Self.failure }
        case .reorder(let expected, let desired):
            guard expected.count <= 10_000, !expected.isEmpty, Set(expected).count == expected.count,
                  Set(expected) == Set(desired), expected.count == desired.count,
                  expected.allSatisfy({ (try? WorkshopIdentifier.parse($0)) == $0 }) else { throw Self.failure }
        }
        let _: Ack = try await perform(.workshopChange(try identifier(appID), action), as: Ack.self)
    }
    private struct Ack: Decodable { let ok: Bool }
    private func identifier(_ id: String) throws -> UInt32 { _=try NativeGameLaunch.steamURL(appID:id); return UInt32(id)! }
    private func folderIndex(_ value: Int) throws -> Int { guard (0..<1000).contains(value) else { throw Self.failure }; return value }
    private func perform<T: Decodable>(_ action: Action, as type:T.Type) async throws -> T {
        try endpoint.validateOwner()
        let url=URL(string:"http://127.0.0.1:\(endpoint.port)/json/list")!
        let (data,response)=try await session.data(from:url)
        guard (response as? HTTPURLResponse)?.statusCode==200, data.count<1_000_000,
              let pages=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],
              let page=pages.first(where:{ $0["title"] as? String=="SharedJSContext" && ($0["url"] as? String)?.hasPrefix("https://steamloopback.host/")==true }),
              let address=page["webSocketDebuggerUrl"] as? String, let target=SteamControlEndpoint.debuggerURL(address,port:endpoint.port) else { throw Self.failure }
        let socket=session.webSocketTask(with:target); socket.maximumMessageSize=2_000_000; socket.resume()
        defer { socket.cancel(with:.normalClosure,reason:nil) }
        let timeout=Task { try? await Task.sleep(nanoseconds:12_000_000_000); guard !Task.isCancelled else { return }; socket.cancel(with:.goingAway,reason:nil) }
        defer { timeout.cancel() }
        let request:[String:Any] = ["id":1,"method":"Runtime.evaluate","params":["expression":Self.script(action),"returnByValue":true,"awaitPromise":true]]
        let bytes=try JSONSerialization.data(withJSONObject:request)
        try await socket.send(.string(String(decoding:bytes,as:UTF8.self)))
        while true {
            let message=try await socket.receive(); let bytes:Data
            switch message { case .data(let value):bytes=value; case .string(let value):bytes=Data(value.utf8); @unknown default:throw Self.failure }
            guard bytes.count<=2_000_000, let reply=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw Self.failure }
            guard reply["id"] as? Int==1 else { continue }
            guard let result=reply["result"] as? [String:Any] else { throw Self.failure }
            if let details=result["exceptionDetails"] as? [String:Any] {
                let exception=details["exception"] as? [String:Any]
                throw Self.actionError(exception?["description"] as? String)
            }
            guard let object=result["result"] as? [String:Any], let text=object["value"] as? String else { throw Self.failure }
            let decoded=try JSONDecoder().decode(T.self,from:Data(text.utf8)); return decoded
        }
    }
    static func actionError(_ description:String?) -> PlaydockError {
        let messages:[String:String] = [
            "Connect online for friends":"Go online in Steam to connect your friends.",
            "Friends controls are unavailable":"Steam’s friends connection is unavailable. Retry when Steam has connected.",
            "Workshop controls are unavailable":"This Steam build does not expose Workshop controls. Open Workshop in Steam to manage mods.",
            "Workshop response changed":"Steam's Workshop response changed. Open Workshop in Steam and refresh.",
            "Workshop subscriptions changed":"Subscriptions or load order changed in Steam. Refresh before trying again.",
            "Workshop change not confirmed":"Steam has not confirmed this change. Refresh or check Workshop in Steam before retrying.",
            "Connect online for Workshop changes":"Sign in to Steam and go online before changing Workshop items.",
            "Workshop game is not owned":"This Steam account does not report owning the game.",
            "Close game for Workshop changes":"Close the game before changing its mods or load order.",
            "Sign in online to install this game.":"Sign in to Steam and go online before installing this game.",
            "Another installation confirmation is open in Steam.":"Finish or cancel the other installation confirmation in Steam, then retry.",
            "Steam did not prepare the installation.":"Steam could not prepare this installation. Open Steam to check it, then retry.",
            "The installation changed":"This installation was changed in Steam. Retry to reload its details.",
            "Library unavailable":"This Steam library is unavailable. Reconnect its drive or choose another library.",
            "Not enough space":"There is not enough free space in this Steam library.",
            "Steam needs another confirmation":"Steam needs another confirmation. Open Steam to complete it, then retry.",
            "Review this game’s agreements in Steam.":"Open Steam to review this game’s agreements.",
            "Steam’s agreement response changed":"Open Steam to review this game’s agreements.",
            "Close this game before uninstalling.":"Close this game before uninstalling it.",
            "Steam has not reported this installation.":"Steam has not reported this installation. Reconnect Steam and retry.",
            "Steam is already uninstalling this game.":"Steam is already uninstalling this game. Wait for it to finish.",
            "Close this game before changing its files.":"Close this game before moving or verifying its files.",
            "Wait for this game’s download to finish.":"Finish or pause and remove this game’s download in Steam before changing its files.",
            "A storage operation is already running.":"Wait for the current storage operation to finish.",
            "Storage controls are unavailable":"This Steam build does not expose storage controls. Use its built-in Storage settings.",
            "Storage status is unavailable":"Steam no longer reports this operation. Check its Storage settings for the result.",
            "Achievements are unavailable":"Steam did not provide achievements for this game and account. Check that Steam is online; some games do not support achievements.",
            "Game controls are unavailable":"This Steam build does not expose game controls. Close the game from its own menu.",
            "Close the game before changing its compatibility runtime.":"Close the game before changing its compatibility runtime.",
            "Steam–CrossOver controls are unavailable. Repair the integration.":"Steam–CrossOver controls are unavailable. Repair the integration.",
            "Steam did not confirm the compatibility tool. Repair the integration.":"Steam did not confirm the compatibility tool. Repair the integration.",
            "Steam is not signed in.":"Sign in to Steam and try again.",
            "Steam launch confirmation changed.":"Steam’s launch confirmation changed. Retry to review the current request."
        ]
        let first=description?.components(separatedBy:"\n").first ?? ""
        guard first.hasPrefix("Error: "), let message=messages[String(first.dropFirst(7))] else { return failure }
        return .message(message)
    }
    enum Action {
        case crossOver(UInt32, Bool)
        case launchResponse(SteamGameLaunch, SteamLaunchResponse)
        case workshop(UInt32), workshopChange(UInt32, WorkshopAction)
        case terminateGame(UInt32), storageFolders, verifyFiles(UInt32), moveGame(UInt32,Int), maintenanceProgress(UInt32), achievements(UInt32)
        case openFriend(UInt32), capabilities, friends, reconnectFriends, downloadSettings, settings(DownloadPolicy), queue(UInt32,Int), cloud(UInt32)
        case snapshot, runningApps, gameLaunches, ownedGames, prepareInstall(UInt32), folder(UInt32,Int), install(UInt32,[SteamGameEULA]), cancel(UInt32), pause(UInt32,Bool), downloads(Bool), mode(Bool), appState(UInt32), uninstall(UInt32)
    }
    static func script(_ action: Action) -> String {
        let body:String
        switch action {
        case .crossOver(let id, let enabled):
            body = """
            if(!App.BHasCurrentUser())throw Error('Steam is not signed in.');
            const s=localState(\(id));
            if(!s.owned||s.displayStatus<=0)throw Error('Steam has not reported this installation.');
            if([1,2,4].includes(s.displayStatus))throw Error('Close the game before changing its compatibility runtime.');
            const apps=SteamClient.Apps,tool='\(enabled ? SteamIntegrationPaths.toolID : "")';
            if(typeof apps?.SpecifyCompatTool!=='function'||typeof apps?.RegisterForAppDetails!=='function')throw Error('Steam–CrossOver controls are unavailable. Repair the integration.');
            let registration,timer;
            try {
                await new Promise((resolve,reject)=>{
                    let changing=false;
                    timer=setTimeout(()=>reject(Error('Steam did not confirm the compatibility tool. Repair the integration.')),6000);
                    registration=apps.RegisterForAppDetails(\(id),d=>{
                        if(d?.unAppID!==\(id)||(d.strCompatToolName!=null&&typeof d.strCompatToolName!=='string')||!Number.isInteger(d.nCompatToolPriority))return;
                        // A suggested/inherited tool does not enable Steam's per-game compatibility override.
                        if(d.nCompatToolPriority===\(enabled ? 250 : 0)&&\(enabled ? "d.strCompatToolName===tool" : "true")){resolve();return;}
                        if(!changing){changing=true;try{Promise.resolve(apps.SpecifyCompatTool(\(id),tool)).catch(reject);}catch(error){reject(error);}}
                    });
                });
            } finally {clearTimeout(timer);registration?.unregister();}
            return {ok:true};
            """
        case .workshop(let id): body = SteamWorkshopScripts.helpers + "\n" + SteamWorkshopScripts.snapshot(id)
        case .workshopChange(let id, let change): body = SteamWorkshopScripts.helpers + "\n" + SteamWorkshopScripts.change(id, change)
        case .terminateGame(let id): body="if(!App.BHasCurrentUser())throw Error('Steam is not signed in.');const s=localState(\(id));if(!s.owned)throw Error('Steam has not reported this installation.');if(![1,4].includes(s.displayStatus))return {ok:true};if(typeof SteamClient.Apps.TerminateApp!=='function')throw Error('Game controls are unavailable');await SteamClient.Apps.TerminateApp('\(id)',false);return {ok:true};"
        case .storageFolders: body=SteamMaintenanceScripts.folders
        case .verifyFiles(let id): body=SteamMaintenanceScripts.verify(id)
        case .moveGame(let id,let folder): body=SteamMaintenanceScripts.move(id,folder:folder)
        case .maintenanceProgress(let id): body=SteamMaintenanceScripts.progress(id)
        case .achievements(let id): body=SteamMaintenanceScripts.achievements(id)
        case .openFriend(let id): body="const app=window.g_FriendsUIApp;if(!app?.FriendStore?.GetFriend(\(id)))throw Error('Friends are unavailable');app.UIStore.ShowFriendChatDialogWhenReady(app.GetDefaultBrowserContext(),\(id),true,true);return {ok:true};"
        case .capabilities: body=SteamFeatureScripts.capabilities
        case .friends: body=SteamFeatureScripts.friends
        case .reconnectFriends: body=SteamFeatureScripts.reconnectFriends
        case .downloadSettings: body=SteamFeatureScripts.downloadSettings
        case .settings(let policy): body=SteamFeatureScripts.settings(policy)
        case .queue(let id,let index): body="await SteamClient.Downloads.SetQueueIndex(\(id),\(index),'0'); return {ok:true};"
        case .cloud(let id): body=SteamFeatureScripts.cloud(id)
        case .snapshot:
            body="""
            const ready=window.App.BHasCurrentUser(), offline=!!window.App.BIsOfflineMode();
            const folders=ready ? await SteamClient.InstallFolder.GetInstallFolders() : [];
            const store=window.downloadsStore, overview=store?.m_DownloadOverview?.get('0');
            const items=store?.m_DownloadItems?.get('0')||[];
            const bytes=v=>Number.isFinite(Number(v))?Math.min(Number.MAX_SAFE_INTEGER,Math.max(0,Math.trunc(Number(v)))):0;
            const sum=(item,index,key)=>(item.update_type_info||[]).reduce((n,t)=>Math.min(Number.MAX_SAFE_INTEGER,n+bytes(t.progress?.[index]?.[key])),0);
            const phases={Verifying:0,VerifyingInstalledFiles:0,Preallocating:1,Downloading:2,Staging:3,Unpacking:3,VerifyingStagedFiles:4,Validating:4,Copying:5,Committing:6};
            const downloads=items.filter(x=>x.appid>0&&!x.completed).map(x=>{
                const current=overview?.update_appid===x.appid&&!!x.active;
                const state=current?String(overview.update_state||'None').slice(0,64):null;
                const index=state in phases?phases[state]:null,progress=index===null?null:overview?.progress?.[index];
                const network=current?overview?.progress?.[2]:null;
                return {appID:String(x.appid),name:window.appStore?.GetAppOverviewByAppID(x.appid)?.display_name||('Game '+x.appid),paused:!!x.paused,active:!!x.active,
                    downloaded:network?bytes(network.bytes_in_progress):sum(x,2,'bytes_in_progress'),total:network?bytes(network.bytes_total):sum(x,2,'bytes_total'),
                    updateState:state,phaseDownloaded:progress?bytes(progress.bytes_in_progress):null,phaseTotal:progress?bytes(progress.bytes_total):null,
                    networkBytesPerSecond:current?bytes(overview.update_network_bytes_per_second):null,diskBytesPerSecond:current?bytes(overview.update_disc_bytes_per_second):null,
                    secondsRemaining:current&&Number.isFinite(overview.overall_estimated_time_remaining_sec)&&overview.overall_estimated_time_remaining_sec>=0?Math.trunc(overview.overall_estimated_time_remaining_sec):null};
            });
            return {mode:ready?(offline?'offline':'online'):'signedOut',folders:folders.filter(x=>x.bIsMounted).map(x=>({id:x.nFolderIndex,path:x.strFolderPath,name:x.strUserLabel||x.strDriveName||x.strFolderPath,freeBytes:x.nFreeSpace,isDefault:!!x.bIsDefaultFolder})),downloads,downloadsPaused:!!overview?.paused};
            """
        case .runningApps:
            body="""
            const apps=window.appStore?.allApps;
            if(!Array.isArray(apps))throw Error('Running games are unavailable.');
            return apps.filter(a=>[1,4].includes(a.local_per_client_data?.display_status)).map(a=>String(a.appid));
            """
        case .gameLaunches:
            body = """
            const apps=SteamClient.Apps;
            if(typeof apps?.GetActiveGameActions!=='function'||typeof apps?.GetGameActionDetails!=='function')throw Error('Game controls are unavailable');
            const actions=await apps.GetActiveGameActions();
            if(!Array.isArray(actions)||actions.length>100)throw Error('Game controls are unavailable');
            return await Promise.all(actions.filter(a=>a.strActionName==='LaunchApp').map(async a=>{
                const appID=String(a.gameid);
                if(!/^[1-9][0-9]{0,9}$/.test(appID)||Number(appID)>4294967295||!Number.isInteger(a.nGameActionID)||a.nGameActionID<=0)throw Error('Game controls are unavailable');
                let timer;
                try {
                    const details=await new Promise((resolve,reject)=>{
                        timer=setTimeout(()=>reject(Error('Game controls are unavailable')),2000);
                        apps.GetGameActionDetails(a.nGameActionID,resolve);
                    });
                    if(typeof details?.bWaitingForUI!=='boolean'||typeof details.strTaskName!=='string'||details.strTaskName.length>100)throw Error('Game controls are unavailable');
                    const request=details.strTaskName==='SynchronizingCloud'&&['syncfailed','pendingcloudsessions','cloudconflict'].includes(details.strTaskDetails)?details.strTaskDetails:null;
                    return {actionID:a.nGameActionID,appID,task:details.strTaskName,waitingForUser:details.bWaitingForUI,request};
                } finally {clearTimeout(timer);}
            }));
            """
        case .launchResponse(let launch, let response):
            let expected = String(decoding: (try? JSONEncoder().encode(launch)) ?? Data("null".utf8), as: UTF8.self)
            let value = String(decoding: (try? JSONEncoder().encode(response.value(for: launch))) ?? Data("null".utf8), as: UTF8.self)
            body = """
            const expected=\(expected),value=\(value),apps=SteamClient.Apps;
            if(!expected||value===null||typeof apps?.GetActiveGameActions!=='function'||typeof apps?.GetGameActionDetails!=='function')throw Error('Game controls are unavailable');
            const actions=await apps.GetActiveGameActions();
            if(!Array.isArray(actions)||actions.length>100)throw Error('Game controls are unavailable');
            const current=actions.find(a=>a.nGameActionID===expected.actionID);
            if(!current)return {ok:true};
            if(String(current.gameid)!==expected.appID||current.strActionName!=='LaunchApp')throw Error('Steam launch confirmation changed.');
            let timer,details;
            try { details=await new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(Error('Game controls are unavailable')),2000);apps.GetGameActionDetails(expected.actionID,resolve)}); }
            finally {clearTimeout(timer);}
            const request=details?.strTaskName==='SynchronizingCloud'&&['syncfailed','pendingcloudsessions','cloudconflict'].includes(details.strTaskDetails)?details.strTaskDetails:null;
            if(details?.strTaskName!==expected.task||request!==(expected.request??null))throw Error('Steam launch confirmation changed.');
            if(details.bWaitingForUI===false)return {ok:true};
            if(details.bWaitingForUI!==true)throw Error('Game controls are unavailable');
            if(\(response == .cancel ? "true" : "false")) {
                if(typeof apps.CancelGameAction!=='function')throw Error('Game controls are unavailable');
                await apps.CancelGameAction(expected.actionID);
            } else {
                if(typeof apps.ContinueGameAction!=='function')throw Error('Game controls are unavailable');
                await apps.ContinueGameAction(expected.actionID,value);
            }
            return {ok:true};
            """
        case .ownedGames:
            body="""
            if(!window.App.BHasCurrentUser())throw Error('Steam is not signed in.');
            const apps=window.appStore?.allApps;
            if(!Array.isArray(apps)||apps.length>50000)throw Error('Steam library is unavailable.');
            return apps.filter(a=>typeof a.BIsOwned==='function'&&a.BIsOwned()&&Number.isInteger(a.appid)&&a.appid>0).map(a=>String(a.appid));
            """
        case .prepareInstall(let id):
            body="""
            if(!window.App.BHasCurrentUser()||window.App.BIsOfflineMode()||!window.appStore.GetAppOverviewByAppID(\(id))?.BIsOwned()) throw Error('Sign in online to install this game.');
            const existing=await SteamClient.Installs.GetInstallManagerInfo();
            const idle=[0,14,15,16].includes(existing.eInstallState);
            if(existing.eInstallState===15&&existing.rgApps?.length===1&&existing.rgApps[0].nAppID===\(id))await SteamClient.Installs.CancelInstall();
            if(existing.eInstallState===15&&existing.rgApps?.some(x=>x.nAppID!==\(id)))throw Error('Another installation confirmation is open in Steam.');
            if(!idle&&!(existing.rgApps?.length===1&&existing.rgApps[0].nAppID===\(id))) throw Error('Another installation confirmation is open in Steam.');
            if(idle) await SteamClient.Installs.OpenInstallWizard([\(id)]);
            for(let i=0;i<60;i++){const v=await SteamClient.Installs.GetInstallManagerInfo(); if(v.rgApps?.length===1&&v.rgApps[0].nAppID===\(id)&&[4,6,7,8,15].includes(v.eInstallState))return await plan(\(id),true); await new Promise(r=>setTimeout(r,100));} throw Error('Steam did not prepare the installation.');
            """
        case .folder(let id,let folder):
            body="""
            await matching(\(id)); const folders=await SteamClient.InstallFolder.GetInstallFolders();
            if(!folders.some(x=>x.nFolderIndex===\(folder)&&x.bIsMounted))throw Error('Library unavailable');
            await SteamClient.Installs.SetInstallFolder(\(folder)); await SteamClient.Installs.SetCreateShortcuts(false,false); return await plan(\(id),true);
            """
        case .install(let id,let agreements):
            let accepted=String(decoding:(try? JSONEncoder().encode(agreements)) ?? Data("[]".utf8),as:UTF8.self)
            body="""
            const before=await matching(\(id)); if(window.App.BIsOfflineMode()||![7,8].includes(before.eInstallState))throw Error('Steam needs another confirmation');
            const eulas=await agreements(\(id)); const accepted=\(accepted);
            for(const e of eulas){if(!accepted.some(x=>x.id===e.id&&x.version===e.version)) return await plan(\(id));}
            for(const e of eulas) await SteamClient.Apps.MarkEulaAccepted(\(id),e.id,e.version);
            if(before.nDiskSpaceRequired>before.nDiskSpaceAvailable)throw Error('Not enough space');
            await SteamClient.Installs.SetCreateShortcuts(false,false); await SteamClient.Installs.ContinueInstall();
            await new Promise(r=>setTimeout(r,300)); return await plan(\(id));
            """
        case .cancel(let id): body="const v=await SteamClient.Installs.GetInstallManagerInfo(); if(v.rgApps?.length===1&&v.rgApps[0].nAppID===\(id)&&[1,2,3,4,5,6,7,8].includes(v.eInstallState))await SteamClient.Installs.CancelInstall(); return {ok:true};"
        case .pause(let id,let paused): body="await SteamClient.Downloads.\(paused ? "PauseAppUpdate" : "ResumeAppUpdate")(\(id),'0'); return {ok:true};"
        case .downloads(let enabled): body="await SteamClient.Downloads.EnableAllDownloads(\(enabled),'0'); return {ok:true};"
        case .mode(let offline): body="SteamClient.User.\(offline ? "GoOffline" : "GoOnline")(); return {ok:true};"
        case .appState(let id): body="return localState(\(id));"
        case .uninstall(let id):
            body="""
            if(!window.App.BHasCurrentUser()) throw Error('Steam is not signed in.');
            const state=localState(\(id));
            if(!state.installed) return {ok:true};
            if(state.displayStatus<=0) throw Error('Steam has not reported this installation.');
            if([1,4].includes(state.displayStatus)) throw Error('Close this game before uninstalling.');
            if(state.displayStatus===2) throw Error('Steam is already uninstalling this game.');
            await SteamClient.Installs.OpenUninstallWizard([\(id)],true); return {ok:true};
            """
        }
        return """
        (async()=>{
          if(!window.App||!window.SteamClient?.Installs)throw Error('Steam is not ready');
          function localState(id){const app=window.appStore?.GetAppOverviewByAppID(id),s=app?.local_per_client_data; if(!s||!Number.isInteger(s.display_status)||s.display_status<0)throw Error('Steam has not reported this installation.'); const installed=s.installed===undefined&&s.display_status===9?false:s.installed; if(typeof installed!=='boolean')throw Error('Steam has not reported this installation.'); return {appID:String(id),installed,owned:typeof app.BIsOwned==='function'&&!!app.BIsOwned(),displayStatus:s.display_status};}
          async function agreements(id){try {const e=await SteamClient.Apps.LoadEula(id); if(!Array.isArray(e)||e.length>100||e.some(x=>typeof x?.id!=='string'||!x.id.length||x.id.length>512||!Number.isInteger(x.version)||x.version<0||x.version>4294967295||typeof x.url!=='string'||!x.url.startsWith('https://')))throw Error('Steam’s agreement response changed'); return e;}catch(error){if(error?.result===42&&error?.message==='No eula for app')return []; throw error;}}
          async function matching(id){const v=await SteamClient.Installs.GetInstallManagerInfo(); if(v.rgApps?.length!==1||v.rgApps[0].nAppID!==id)throw Error('The installation changed'); return v;}
          async function plan(id,requireMatching=false){const v=requireMatching?await matching(id):await SteamClient.Installs.GetInstallManagerInfo(); const e=await agreements(id); if(e.some(x=>typeof x.url!=='string'||!x.url.startsWith('https://')))throw Error('Review this game’s agreements in Steam.'); return {appID:String(id),state:v.eInstallState,requiredBytes:v.nDiskSpaceRequired,availableBytes:v.nDiskSpaceAvailable,folder:v.iInstallFolder,currentAppID:v.currentAppID,error:v.eAppError,detail:String(v.errorDetail||'').slice(0,512),eulas:e.map(x=>({id:x.id,version:x.version,url:x.url}))};}
          const result=await (async()=>{\(body)})(); return JSON.stringify(result);
        })()
        """
    }
}

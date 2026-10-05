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
    public var id: String { appID }
}
public struct SteamControlSnapshot: Codable, Sendable {
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
    public var hasStarted: Bool { [0,9,14].contains(state) && error == 0 }
}
public struct SteamGameEULA: Identifiable, Codable, Sendable {
    public let id: UInt32
    public let version: UInt32
    public let url: URL
}

/// Steam's private CEF API is accessed only in its local SharedJSContext. No
/// browser page, credentials, cookies, or arbitrary caller-supplied JavaScript.
public struct SteamControlEndpoint: Sendable {
    public let port: UInt16
    public let root: URL
    public let prefix: URL?
    public init(port: UInt16, root: URL, prefix: URL? = nil) { self.port=port; self.root=root; self.prefix=prefix }
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
        runningPort(root:root,prefix:nil)
    }
    public static func runningWindowsPort(root:URL,prefix:URL) -> UInt16? {
        runningPort(root:root,prefix:prefix)
    }
    private static func runningPort(root:URL,prefix:URL?) -> UInt16? {
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
        process.arguments=["-nP","-a","-c","steamwebh","-c","Steam Hel","-iTCP","-sTCP:LISTEN","-Fn"]
        let pipe=Pipe(); process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard data.count<65536 else { return nil }
        for line in String(decoding:data,as:UTF8.self).split(separator:"\n").prefix(64) where line.hasPrefix("n127.0.0.1:") {
            guard let port=UInt16(line.dropFirst("n127.0.0.1:".count)), port>1024 else { continue }
            if (try? SteamControlEndpoint(port:port,root:root,prefix:prefix).validateOwner()) != nil { return port }
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
                if command.lowercased().contains("steamwebh") || (prefix==nil && command.lowercased().hasPrefix("steam hel")) || (prefix != nil && command.lowercased().contains("wineserve")) {
                    if let prefix { trusted = trusted || RuntimeProcessIdentity.belongsToPrefix(pid:pid,prefix:prefix) || ownsPrefixDirectory(pid:pid,prefix:prefix) }
                    else { trusted = trusted || RuntimeProcessIdentity.belongsToPrefix(pid:pid,prefix:root) }
                }
            }
        }
        guard trusted else { throw SteamControl.failure }
    }
    private func ownsPrefixDirectory(pid:pid_t,prefix:URL)->Bool {
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof")
        process.arguments=["-nP","-a","-p",String(pid),"-Fpn",prefix.resolvingSymlinksInPath().path]
        let pipe=Pipe(); process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus==0 && data.count<65536 && String(decoding:data,as:UTF8.self).split(separator:"\n").contains("n\(prefix.resolvingSymlinksInPath().path)")
    }
}

public actor SteamControl {
    static var failure: WayfarerError { .message("Steam’s local connection is unavailable. Open Steam from Wayfarer and try again.") }
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
    public func runningAppIDs() async throws -> [String] { try await perform(.runningApps,as:[String].self) }
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
    static func actionError(_ description:String?) -> WayfarerError {
        let messages:[String:String] = [
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
            "Steam is not signed in.":"Sign in to Steam before uninstalling this game."
        ]
        let first=description?.components(separatedBy:"\n").first ?? ""
        guard first.hasPrefix("Error: "), let message=messages[String(first.dropFirst(7))] else { return failure }
        return .message(message)
    }
    private enum Action {
        case snapshot, runningApps, ownedGames, prepareInstall(UInt32), folder(UInt32,Int), install(UInt32,[SteamGameEULA]), cancel(UInt32), pause(UInt32,Bool), downloads(Bool), mode(Bool), appState(UInt32), uninstall(UInt32)
    }
    private static func script(_ action: Action) -> String {
        let body:String
        switch action {
        case .snapshot:
            body="""
            const ready=window.App.BHasCurrentUser(), offline=!!window.App.BIsOfflineMode();
            const folders=ready ? await SteamClient.InstallFolder.GetInstallFolders() : [];
            const store=window.downloadsStore, overview=store?.m_DownloadOverview?.get('0');
            const items=store?.m_DownloadItems?.get('0')||[];
            return {mode:ready?(offline?'offline':'online'):'signedOut',folders:folders.filter(x=>x.bIsMounted).map(x=>({id:x.nFolderIndex,path:x.strFolderPath,name:x.strUserLabel||x.strDriveName||x.strFolderPath,freeBytes:x.nFreeSpace,isDefault:!!x.bIsDefaultFolder})),downloads:items.filter(x=>x.appid>0&&!x.completed).map(x=>({appID:String(x.appid),name:window.appStore?.GetAppOverviewByAppID(x.appid)?.display_name||('Game '+x.appid),paused:!!x.paused,active:!!x.active,downloaded:(x.update_type_info||[]).reduce((n,t)=>n+Math.max(0,t.progress?.[2]?.bytes_in_progress||0),0),total:(x.update_type_info||[]).reduce((n,t)=>n+Math.max(0,t.progress?.[2]?.bytes_total||0),0)})),downloadsPaused:!!overview?.paused};
            """
        case .runningApps:
            body="""
            const apps=window.appStore?.allApps;
            if(!Array.isArray(apps))throw Error('Running games are unavailable.');
            return apps.filter(a=>[1,4].includes(a.local_per_client_data?.display_status)).map(a=>String(a.appid));
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
            if(!idle&&!existing.rgApps?.some(x=>x.nAppID===\(id))) throw Error('Another installation confirmation is open in Steam.');
            if(idle) await SteamClient.Installs.OpenInstallWizard([\(id)]);
            for(let i=0;i<60;i++){const p=await plan(\(id)); if([4,6,7,8,14,15].includes(p.state))return p; await new Promise(r=>setTimeout(r,100));} throw Error('Steam did not prepare the installation.');
            """
        case .folder(let id,let folder):
            body="""
            await matching(\(id)); const folders=await SteamClient.InstallFolder.GetInstallFolders();
            if(!folders.some(x=>x.nFolderIndex===\(folder)&&x.bIsMounted))throw Error('Library unavailable');
            await SteamClient.Installs.SetInstallFolder(\(folder)); await SteamClient.Installs.SetCreateShortcuts(false,false); return await plan(\(id));
            """
        case .install(let id,let agreements):
            let accepted=agreements.map { "[\($0.id),\($0.version)]" }.joined(separator:",")
            body="""
            const before=await matching(\(id)); if(window.App.BIsOfflineMode()||![7,8].includes(before.eInstallState))throw Error('Steam needs another confirmation');
            const eulas=await agreements(\(id)); const accepted=[\(accepted)];
            for(const e of eulas){if(!accepted.some(x=>x[0]===e.id&&x[1]===e.version)) return await plan(\(id));}
            for(const e of eulas) await SteamClient.Apps.MarkEulaAccepted(\(id),e.id,e.version);
            if(before.nDiskSpaceRequired>before.nDiskSpaceAvailable)throw Error('Not enough space');
            await SteamClient.Installs.SetCreateShortcuts(false,false); await SteamClient.Installs.ContinueInstall();
            await new Promise(r=>setTimeout(r,300)); return await plan(\(id));
            """
        case .cancel(let id): body="await matching(\(id)); await SteamClient.Installs.CancelInstall(); return {ok:true};"
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
          async function agreements(id){try {const e=await SteamClient.Apps.LoadEula(id); if(!Array.isArray(e))throw Error('Steam’s agreement response changed'); return e;}catch(error){if(error?.result===42&&error?.message==='No eula for app')return []; throw error;}}
          async function matching(id){const v=await SteamClient.Installs.GetInstallManagerInfo(); if(!v.rgApps?.some(x=>x.nAppID===id))throw Error('The installation changed'); return v;}
          async function plan(id){const v=await SteamClient.Installs.GetInstallManagerInfo(); const e=await agreements(id); if(e.some(x=>typeof x.url!=='string'||!x.url.startsWith('https://')))throw Error('Review this game’s agreements in Steam.'); return {appID:String(id),state:v.eInstallState,requiredBytes:v.nDiskSpaceRequired,availableBytes:v.nDiskSpaceAvailable,folder:v.iInstallFolder,currentAppID:v.currentAppID,error:v.eAppError,detail:String(v.errorDetail||'').slice(0,512),eulas:e.map(x=>({id:x.id,version:x.version,url:x.url}))};}
          const result=await (async()=>{\(body)})(); return JSON.stringify(result);
        })()
        """
    }
}

import Foundation
import CryptoKit

public enum WorkshopIdentifier {
    public static func parse(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = UInt64(text), value > 0, String(value) == text { return text }
        guard let url = URLComponents(string: text), url.scheme == "https", url.host == "steamcommunity.com",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              ["/sharedfiles/filedetails/", "/sharedfiles/filedetails", "/workshop/filedetails/", "/workshop/filedetails"].contains(url.path),
              let queries = url.queryItems, queries.filter({ $0.name == "id" }).count == 1,
              let id = queries.first(where: { $0.name == "id" })?.value,
              let value = UInt64(id), value > 0, String(value) == id else {
            throw WayfarerError.message("Enter a Workshop item ID or its steamcommunity.com link.")
        }
        return id
    }
    public static func browserURL(appID: String, itemID: String? = nil) throws -> URL {
        _ = try NativeGameLaunch.steamURL(appID: appID)
        if let itemID { return URL(string: "steam://url/CommunityFilePage/\(try parse(itemID))")! }
        return URL(string: "steam://url/SteamWorkshopPage/\(appID)")!
    }
}

public enum WorkshopDownloadState: String, Codable, Sendable {
    case downloaded, needsUpdate, pending, unknown
    public var title: String {
        switch self {
        case .downloaded: "Downloaded"
        case .needsUpdate: "Update pending"
        case .pending: "Awaiting Steam download"
        case .unknown: "Download status unavailable"
        }
    }
}

public struct WorkshopItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var subscribed: Bool?
    public var enabled: Bool?
    public var loadOrder: Int?
    public var download: WorkshopDownloadState
    public var size: UInt64?
    public var location: URL?
    public var dependencies: [String]
    public init(id: String, title: String, summary: String = "", subscribed: Bool? = nil, enabled: Bool? = nil,
                loadOrder: Int? = nil, download: WorkshopDownloadState = .unknown, size: UInt64? = nil,
                location: URL? = nil, dependencies: [String] = []) {
        self.id = id; self.title = title; self.summary = summary; self.subscribed = subscribed; self.enabled = enabled
        self.loadOrder = loadOrder; self.download = download; self.size = size; self.location = location; self.dependencies = dependencies
    }
}

public struct WorkshopCapabilities: Codable, Equatable, Sendable {
    public var subscribe: Bool
    public var disable: Bool
    public var reorder: Bool
    public init(subscribe: Bool = false, disable: Bool = false, reorder: Bool = false) {
        self.subscribe = subscribe; self.disable = disable; self.reorder = reorder
    }
}

public struct SteamWorkshopSnapshot: Codable, Sendable {
    public var appID: String
    public var supported: Bool?
    public var capabilities: WorkshopCapabilities
    public var items: [WorkshopItem]
}

public struct WorkshopSnapshot: Codable, Sendable {
    public enum Source: String, Codable, Sendable { case steam, saved, local }
    public var scope: String
    public var appID: String
    public var updatedAt: Date
    public var source: Source
    public var supported: Bool?
    public var capabilities: WorkshopCapabilities
    public var items: [WorkshopItem]
    public var missingDependencies: Set<String> {
        let subscribed = Set(items.filter { $0.subscribed == true }.map(\.id))
        return Set(items.flatMap(\.dependencies)).subtracting(subscribed)
    }
}

public struct WorkshopItemDetails: Equatable, Sendable {
    public var id: String
    public var appID: String
    public var title: String
    public var summary: String

    public static func decode(_ data: Data, appID: String, itemID: String, collectionData: Data? = nil) throws -> Self {
        guard data.count < 2_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let files = response["publishedfiledetails"] as? [[String: Any]], files.count == 1,
              let file = files.first, file["result"] as? Int == 1,
              file["publishedfileid"] as? String == itemID,
              (file["consumer_app_id"] as? NSNumber)?.stringValue == appID,
              file["banned"] as? Int == 0,
              file["visibility"] as? Int == 0, let title = file["title"] as? String else {
            throw WayfarerError.message("This item is unavailable, belongs to another game, or is a collection. Open it in Steam to review it.")
        }
        if let type = file["file_type"] as? Int {
            guard type == 0 else { throw WayfarerError.message("Open this Workshop content in Steam. Only individual mods can be subscribed to here.") }
        } else {
            guard let collectionData, collectionData.count < 2_000_000,
                  let check = try JSONSerialization.jsonObject(with: collectionData) as? [String: Any],
                  let response = check["response"] as? [String: Any], response["result"] as? Int == 1,
                  let details = response["collectiondetails"] as? [[String: Any]], details.count == 1,
                  details[0]["publishedfileid"] as? String == itemID, details[0]["result"] as? Int == 9 else {
                throw WayfarerError.message("This is a collection, or Steam could not confirm its item type. Open it in Steam to review and subscribe to its contents.")
            }
        }
        return Self(id: itemID, appID: appID, title: String(title.prefix(256)), summary: String((file["description"] as? String ?? "").prefix(1000)))
    }
}

/// Files record downloads, not the current account's subscriptions. Steam owns all changes.
public actor WorkshopService {
    private let cacheDirectory: URL
    private let session: URLSession
    public init(cacheDirectory: URL = AppPaths.support.appendingPathComponent("Workshop")) {
        self.cacheDirectory = cacheDirectory
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config)
    }
    private func cacheURL(scope: String, appID: String) -> URL {
        let key = SHA256.hash(data: Data((scope + ":" + appID).utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(key + ".json")
    }
    public func initial(scope: String, appID: String, root: URL, prefix: URL?, useCache: Bool) throws -> WorkshopSnapshot {
        _ = try NativeGameLaunch.steamURL(appID: appID)
        let local = try localItems(appID: appID, root: root, prefix: prefix)
        var snapshot = WorkshopSnapshot(scope: scope, appID: appID, updatedAt: Date(), source: .local,
                                       capabilities: WorkshopCapabilities(), items: local)
        if useCache, let data = try? Data(contentsOf: cacheURL(scope: scope, appID: appID)), data.count < 4_000_000,
           var saved = try? JSONDecoder().decode(WorkshopSnapshot.self, from: data),
           saved.scope == scope, saved.appID == appID, valid(saved.items) {
            saved.source = .saved; saved.capabilities = WorkshopCapabilities()
            saved.items = merge(saved.items, local: local, live: false)
            snapshot = saved
        }
        return snapshot
    }
    public func resolve(_ live: SteamWorkshopSnapshot, scope: String, root: URL, prefix: URL?, save: Bool) throws -> WorkshopSnapshot {
        _ = try NativeGameLaunch.steamURL(appID: live.appID)
        guard valid(live.items) else { throw WayfarerError.message("Steam's Workshop response changed. Open Workshop in Steam and refresh.") }
        let snapshot = WorkshopSnapshot(scope: scope, appID: live.appID, updatedAt: Date(), source: .steam,
            supported: live.supported, capabilities: live.capabilities,
            items: merge(live.items, local: (try? localItems(appID: live.appID, root: root, prefix: prefix)) ?? [], live: true))
        if save, !Task.isCancelled {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: cacheURL(scope: scope, appID: live.appID), options: .atomic)
        }
        return snapshot
    }
    public func lookup(appID: String, input: String) async throws -> WorkshopItemDetails {
        _ = try NativeGameLaunch.steamURL(appID: appID)
        let id = try WorkshopIdentifier.parse(input)
        let data = try await request("GetPublishedFileDetails", body: "itemcount=1&publishedfileids%5B0%5D=\(id)")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let response = json?["response"] as? [String: Any]
        let files = response?["publishedfiledetails"] as? [[String: Any]]
        let check: Data?
        if files?.first?["file_type"] == nil {
            check = try await request("GetCollectionDetails", body: "collectioncount=1&publishedfileids%5B0%5D=\(id)")
        } else { check = nil }
        return try WorkshopItemDetails.decode(data, appID: appID, itemID: id, collectionData: check)
    }
    private func request(_ method: String, body: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/\(method)/v1/")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { throw WayfarerError.message("Steam could not load this Workshop item. Try again online.") }
        return data
    }
    private func valid(_ items: [WorkshopItem]) -> Bool {
        items.count <= 10_000 && Set(items.map(\.id)).count == items.count && items.allSatisfy { (try? WorkshopIdentifier.parse($0.id)) == $0.id }
    }
    private func merge(_ items: [WorkshopItem], local: [WorkshopItem], live: Bool) -> [WorkshopItem] {
        let files = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var result = items.map { item in
            var copy = item
            copy.location = files[item.id]?.location; copy.size = files[item.id]?.size
            if let file = files[item.id] { copy.download = file.download }
            else if !live, item.download == .downloaded { copy.download = .unknown }
            return copy
        }
        let known = Set(items.map(\.id))
        for var file in local where !known.contains(file.id) {
            if live { file.subscribed = false }
            result.append(file)
        }
        return result.sorted {
            if ($0.subscribed == true) != ($1.subscribed == true) { return $0.subscribed == true }
            if let a = $0.loadOrder, let b = $1.loadOrder, a != b { return a < b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    private func text(at url: URL, maximum: Int = 6_000_000) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw WayfarerError.message("This Workshop manifest is too large to read.") }
        return String(decoding: data, as: UTF8.self)
    }
    private func localItems(appID: String, root: URL, prefix: URL?) throws -> [WorkshopItem] {
        var libraries = [root]
        let foldersURL = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if FileManager.default.fileExists(atPath: foldersURL.path) {
            let folders = try VDFParser.parse(text(at: foldersURL))["libraryfolders"]?.object ?? [:]
            guard folders.count <= 1000 else { throw WayfarerError.message("Too many Steam library folders.") }
            for (key, value) in folders where UInt(key) != nil {
                if let path = value["path"]?.string ?? value.string,
                   let url = prefix.flatMap({ WindowsPath.hostPath(path, prefix: $0) }) ?? (prefix == nil && path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil) { libraries.append(url) }
            }
        }
        var seen = Set<String>(), items: [String: WorkshopItem] = [:]
        for library in libraries where seen.insert(library.resolvingSymlinksInPath().path).inserted {
            try Task.checkCancellation()
            let workshop = library.appendingPathComponent("steamapps/workshop")
            let manifest = workshop.appendingPathComponent("appworkshop_\(appID).acf")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let state = try VDFParser.parse(text(at: manifest))["AppWorkshop"]
            guard state?["appid"]?.string == appID else { throw WayfarerError.message("This Workshop manifest belongs to another game.") }
            let installed = state?["WorkshopItemsInstalled"]?.object ?? [:]
            let details = state?["WorkshopItemDetails"]?.object ?? [:]
            let ids = Set(installed.keys).union(details.keys)
            guard ids.count <= 10_000 else { throw WayfarerError.message("Too many Workshop items.") }
            for id in ids where (try? WorkshopIdentifier.parse(id)) == id {
                let info = installed[id], detail = details[id]
                let base = workshop.appendingPathComponent("content/\(appID)").resolvingSymlinksInPath()
                let path = base.appendingPathComponent(id).resolvingSymlinksInPath()
                let present = path.path.hasPrefix(base.path + "/") && FileManager.default.fileExists(atPath: path.path)
                let stale = detail?["manifest"]?.string != nil && info?["manifest"]?.string != detail?["manifest"]?.string
                items[id] = WorkshopItem(id: id, title: "Workshop item \(id)",
                    download: stale ? .needsUpdate : info != nil && present ? .downloaded : .pending,
                    size: info?["size"]?.string.flatMap(UInt64.init), location: present ? path : nil)
            }
        }
        return Array(items.values)
    }
}

public enum WorkshopAction: Sendable {
    case subscribe(String, Bool)
    case enabled(String, Bool)
    case reorder([String], [String])
}

enum SteamWorkshopScripts {
    static func snapshot(_ appID: UInt32) -> String {
        """
        const apps=SteamClient.Apps;
        if(!App.BHasCurrentUser())throw Error('Steam is not signed in.');
        if(typeof apps.GetSubscribedWorkshopItems!=='function')throw Error('Workshop controls are unavailable');
        const subscriptions=await apps.GetSubscribedWorkshopItems(\(appID));
        validateItems(subscriptions);
        let details=[];
        if(subscriptions.length&&typeof apps.GetSubscribedWorkshopItemDetails==='function'){
            for(let i=0;i<subscriptions.length;i+=100){
                try{const batch=await apps.GetSubscribedWorkshopItemDetails(\(appID),subscriptions.slice(i,i+100).map(x=>x.publishedfileid));if(Array.isArray(batch))details.push(...batch);}catch{}
            }
        }
        const metadata=new Map(details.map(x=>[String(x.publishedfileid),x]));
        let downloaded=null;
        if(typeof apps.GetDownloadedWorkshopItems==='function'){
            try{const list=await apps.GetDownloadedWorkshopItems(\(appID));validateItems(list);downloaded=new Set(list.map(x=>x.publishedfileid));}catch{}
        }
        let supported=null,registration,timer;
        if(typeof apps.RegisterForAppDetails==='function'){
            try{supported=await new Promise(resolve=>{timer=setTimeout(()=>resolve(null),1500);registration=apps.RegisterForAppDetails(\(appID),d=>{if(d?.unAppID===\(appID)&&typeof d.bWorkshopVisible==='boolean')resolve(d.bWorkshopVisible);});});}finally{clearTimeout(timer);registration?.unregister();}
        }
        const items=subscriptions.map((x,index)=>{
            const d=metadata.get(x.publishedfileid);
            return {id:x.publishedfileid,title:String(d?.title||('Workshop item '+x.publishedfileid)).slice(0,256),summary:String(d?.short_description||'').slice(0,1000),
                subscribed:true,enabled:typeof x.disabled_locally==='boolean'?!x.disabled_locally:null,
                loadOrder:Number.isInteger(x.load_order)&&x.load_order>=0?x.load_order:index,
                download:downloaded===null?'unknown':downloaded.has(x.publishedfileid)?'downloaded':'pending',
                dependencies:Array.isArray(d?.children)?d.children.map(c=>typeof c==='string'?c:c?.publishedfileid).filter(validID).slice(0,100):[]};
        });
        return {appID:'\(appID)',supported,capabilities:{subscribe:typeof apps.SubscribeWorkshopItem==='function',disable:typeof apps.SetWorkshopItemsDisabledLocally==='function',reorder:typeof apps.SetWorkshopItemsLoadOrder==='function'},items};
        """
    }
    static let helpers = """
    const validID=id=>typeof id==='string'&&/^[1-9][0-9]{0,19}$/.test(id)&&BigInt(id)<=18446744073709551615n;
    function validateItems(items){if(!Array.isArray(items)||items.length>10000||items.some(x=>!validID(x?.publishedfileid))||new Set(items.map(x=>x.publishedfileid)).size!==items.length)throw Error('Workshop response changed');}
    async function currentItems(appid){const items=await SteamClient.Apps.GetSubscribedWorkshopItems(appid);validateItems(items);return items;}
    function ordered(items){return items.map((x,index)=>({x,index})).sort((a,b)=>(a.x.load_order??a.index)-(b.x.load_order??b.index)).map(v=>v.x.publishedfileid);}
    async function confirm(predicate){for(let i=0;i<25;i++){if(await predicate())return {ok:true};await new Promise(r=>setTimeout(r,200));}throw Error('Workshop change not confirmed');}
    """
    static func change(_ appID: UInt32, _ action: WorkshopAction) -> String {
        let operation: String
        switch action {
        case .subscribe(let itemID, let subscribe):
            operation = """
            if(typeof apps.SubscribeWorkshopItem!=='function')throw Error('Workshop controls are unavailable');
            const id='\(itemID)',subscribed=\(subscribe);
            if(before.some(x=>x.publishedfileid===id)===subscribed)return {ok:true};
            const result=await apps.SubscribeWorkshopItem(\(appID),id,subscribed);if(result===false)throw Error('Workshop change not confirmed');
            return await confirm(async()=>(await currentItems(\(appID))).some(x=>x.publishedfileid===id)===subscribed);
            """
        case .enabled(let itemID, let enabled):
            operation = """
            const id='\(itemID)',disabled=\(!enabled),item=before.find(x=>x.publishedfileid===id);
            if(!item)throw Error('Workshop subscriptions changed');
            if(typeof item.disabled_locally!=='boolean'||typeof apps.SetWorkshopItemsDisabledLocally!=='function')throw Error('Workshop controls are unavailable');
            const result=await apps.SetWorkshopItemsDisabledLocally(\(appID),[id],disabled);if(result===false)throw Error('Workshop change not confirmed');
            return await confirm(async()=>(await currentItems(\(appID))).find(x=>x.publishedfileid===id)?.disabled_locally===disabled);
            """
        case .reorder(let expected, let desired):
            let previous = expected.map { "'\($0)'" }.joined(separator: ",")
            let next = desired.map { "'\($0)'" }.joined(separator: ",")
            operation = """
            const expected=[\(previous)],desired=[\(next)];
            if(JSON.stringify(ordered(before))!==JSON.stringify(expected))throw Error('Workshop subscriptions changed');
            if(typeof apps.SetWorkshopItemsLoadOrder!=='function')throw Error('Workshop controls are unavailable');
            const result=await apps.SetWorkshopItemsLoadOrder(\(appID),desired);if(result===false)throw Error('Workshop change not confirmed');
            return await confirm(async()=>JSON.stringify(ordered(await currentItems(\(appID))))===JSON.stringify(desired));
            """
        }
        return """
        if(!App.BHasCurrentUser()||App.BIsOfflineMode())throw Error('Connect online for Workshop changes');
        const state=localState(\(appID));
        if(!state.owned)throw Error('Workshop game is not owned');
        if(state.isRunning||[1,4,2].includes(state.displayStatus))throw Error('Close game for Workshop changes');
        const apps=SteamClient.Apps;if(typeof apps.GetSubscribedWorkshopItems!=='function')throw Error('Workshop controls are unavailable');
        const before=await currentItems(\(appID));
        \(operation)
        """
    }
}

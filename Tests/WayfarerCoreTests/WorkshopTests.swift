import Foundation
import XCTest
@testable import WayfarerCore

final class WorkshopTests: XCTestCase {
    func testItemIdentifiersPreserve64BitPrecisionAndRejectUntrustedLinks() throws {
        let id = "18446744073709551615"
        XCTAssertEqual(try WorkshopIdentifier.parse(id), id)
        XCTAssertEqual(try WorkshopIdentifier.parse("https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)&searchtext=test"), id)
        for input in ["0", "01", "-10", "18446744073709551616", "10';quit()", "https://other.test/sharedfiles/filedetails/?id=10", "https://steamcommunity.com@other.test/sharedfiles/filedetails/?id=10", "http://steamcommunity.com/sharedfiles/filedetails/?id=10", "https://steamcommunity.com/sharedfiles/filedetails/?id=10&id=20", "https://steamcommunity.com/workshop/browse/?id=10"] {
            XCTAssertThrowsError(try WorkshopIdentifier.parse(input), input)
        }
        XCTAssertEqual(try WorkshopIdentifier.browserURL(appID: "100", itemID: id).absoluteString, "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
        XCTAssertEqual(try WorkshopIdentifier.browserURL(appID: "100").absoluteString, "https://steamcommunity.com/app/100/workshop/")
        XCTAssertThrowsError(try WorkshopIdentifier.browserURL(appID: "0"))
    }
    func testLookupRequiresExactItemGameAndPublicIndividualContent() throws {
        func data(_ changes: [String: Any] = [:]) throws -> Data {
            let file: [String: Any] = ["publishedfileid": "9007199254740993", "consumer_app_id": 100, "result": 1, "file_type": 0, "banned": 0, "visibility": 0, "title": "Mod", "description": "Description"]
            return try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [file.merging(changes) { _, new in new }]]])
        }
        XCTAssertEqual(try WorkshopItemDetails.decode(data(), appID: "100", itemID: "9007199254740993").title, "Mod")
        for changes: [String: Any] in [["consumer_app_id": 200], ["publishedfileid": "1000"], ["result": 9], ["banned": 1], ["visibility": 2], ["file_type": 2]] {
            XCTAssertThrowsError(try WorkshopItemDetails.decode(data(changes), appID: "100", itemID: "9007199254740993"))
        }
    }
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkshopTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testLegacyMetadataUsesCollectionCheckAndRejectsCollectionsOrUnknownType() throws {
        let data = Data(#"{"response":{"publishedfiledetails":[{"publishedfileid":"10","consumer_app_id":100,"result":1,"banned":0,"visibility":0,"title":"Mod"}]}}"#.utf8)
        func check(_ result: Int, id: String = "10") -> Data {
            Data("{\"response\":{\"result\":1,\"collectiondetails\":[{\"publishedfileid\":\"\(id)\",\"result\":\(result)}]}}".utf8)
        }
        XCTAssertEqual(try WorkshopItemDetails.decode(data, appID: "100", itemID: "10", collectionData: check(9)).title, "Mod")
        for result in [1, 2, 15] { XCTAssertThrowsError(try WorkshopItemDetails.decode(data, appID: "100", itemID: "10", collectionData: check(result))) }
        XCTAssertThrowsError(try WorkshopItemDetails.decode(data, appID: "100", itemID: "10", collectionData: check(9, id: "20")))
        XCTAssertThrowsError(try WorkshopItemDetails.decode(data, appID: "100", itemID: "10"))
    }
    func testLiveSnapshotSurvivesUnreadableLocalManifestAndCacheWriteFailure() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let workshop = root.appendingPathComponent("steamapps/workshop")
        try FileManager.default.createDirectory(at: workshop, withIntermediateDirectories: true)
        try Data("broken manifest".utf8).write(to: workshop.appendingPathComponent("appworkshop_100.acf"))
        let cache = root.appendingPathComponent("not-a-directory"); try Data([1]).write(to: cache)
        let service = WorkshopService(cacheDirectory: cache)
        let live = SteamWorkshopSnapshot(appID: "100", capabilities: WorkshopCapabilities(), items: [WorkshopItem(id: "10", title: "Mod", subscribed: true, download: .downloaded)])
        let resolved = try await service.resolve(live, scope: "test", root: root, save: true)
        XCTAssertEqual(resolved.source, .steam); XCTAssertEqual(resolved.items.first?.download, .downloaded)
        XCTAssertEqual(resolved.items.first?.title, "Mod")
    }
    private func install(root: URL, appID: String = "100", id: String = "10", installedManifest: String = "1", currentManifest: String = "1") throws {
        let workshop = root.appendingPathComponent("steamapps/workshop")
        try FileManager.default.createDirectory(at: workshop.appendingPathComponent("content/\(appID)/\(id)"), withIntermediateDirectories: true)
        try Data("\"AppWorkshop\" { \"appid\" \"\(appID)\" \"WorkshopItemsInstalled\" { \"\(id)\" { \"manifest\" \"\(installedManifest)\" \"size\" \"1024\" } } \"WorkshopItemDetails\" { \"\(id)\" { \"manifest\" \"\(currentManifest)\" } } }".utf8)
            .write(to: workshop.appendingPathComponent("appworkshop_\(appID).acf"))
    }
    func testDownloadedFilesNeverImplySubscriptionAndDetectStaleManifest() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try install(root: root, installedManifest: "1", currentManifest: "2")
        let service = WorkshopService(cacheDirectory: root.appendingPathComponent("cache"))
        let local = try await service.initial(scope: "mac:account", appID: "100", root: root, useCache: false)
        XCTAssertEqual(local.source, .local); XCTAssertNil(local.items.first?.subscribed)
        XCTAssertEqual(local.items.first?.download, .needsUpdate)
        XCTAssertEqual(local.items.first?.size, 1024)
        XCTAssertNotNil(local.items.first?.location)
        let live = SteamWorkshopSnapshot(appID: "100", capabilities: WorkshopCapabilities(), items: [])
        let resolved = try await service.resolve(live, scope: "mac:account", root: root, save: false)
        XCTAssertEqual(resolved.items.first?.subscribed, false)
    }
    func testCacheSeparatesAccountsEnvironmentsAndGamesAndCannotEnableChanges() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkshopService(cacheDirectory: root.appendingPathComponent("cache"))
        let live = SteamWorkshopSnapshot(appID: "100", supported: true, capabilities: WorkshopCapabilities(subscribe: true, disable: true, reorder: true),
                                        items: [WorkshopItem(id: "10", title: "Mod", subscribed: true, enabled: false, loadOrder: 0)])
        _ = try await service.resolve(live, scope: "accountA:mac", root: root, save: true)
        let saved = try await service.initial(scope: "accountA:mac", appID: "100", root: root, useCache: true)
        XCTAssertEqual(saved.source, .saved); XCTAssertEqual(saved.items.first?.title, "Mod"); XCTAssertFalse(saved.capabilities.subscribe)
        for scope in ["accountB:mac", "accountA:windows:bottle"] {
            let other = try await service.initial(scope: scope, appID: "100", root: root, useCache: true)
            XCTAssertTrue(other.items.isEmpty); XCTAssertEqual(other.source, .local)
        }
        let otherGame = try await service.initial(scope: "accountA:mac", appID: "200", root: root, useCache: true)
        XCTAssertTrue(otherGame.items.isEmpty)
    }
    func testExtraSteamLibraryIsReadAndEscapingModSymlinkIsNotExposed() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library 2")
        try install(root: library)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try Data("\"libraryfolders\" { \"0\" { \"path\" \"\(library.path)\" } }".utf8).write(to: root.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let service = WorkshopService(cacheDirectory: root.appendingPathComponent("cache"))
        let first = try await service.initial(scope: "test", appID: "100", root: root, useCache: false)
        XCTAssertEqual(first.items.count, 1); XCTAssertNotNil(first.items.first?.location)
        let path = library.appendingPathComponent("steamapps/workshop/content/100/10")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root)
        let second = try await service.initial(scope: "test", appID: "100", root: root, useCache: false)
        XCTAssertNil(second.items.first?.location)
    }
    func testInvalidChangesFailBeforeConnectingToSteam() async {
        let control = SteamControl(endpoint: SteamControlEndpoint(port: 0, root: URL(fileURLWithPath: "/missing")))
        for action: WorkshopAction in [.subscribe("10';quit", true), .enabled("0", true), .reorder(["10", "10"], ["10", "10"]), .reorder(["10", "20"], ["10", "30"])] {
            do { try await control.changeWorkshop(appID: "100", action: action); XCTFail("Invalid change accepted") } catch { }
        }
    }
    private func run(_ action: SteamControl.Action, fixture: String = "") throws -> [String: Any] {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("Node required for Steam fixtures") }
        let literal = String(decoding: try JSONEncoder().encode(SteamControl.script(action)), as: UTF8.self)
        let source = """
        globalThis.window=globalThis;
        globalThis.App={BHasCurrentUser:()=>true,BIsOfflineMode:()=>false};
        let items=[{publishedfileid:'9007199254740993',disabled_locally:false,load_order:0}],calls=0,unregistered=0;
        globalThis.appStore={GetAppOverviewByAppID:()=>({BIsOwned:()=>true,local_per_client_data:{installed:true,display_status:11}})};
        globalThis.SteamClient={Installs:{},Apps:{
            GetSubscribedWorkshopItems:async app=>{if(app!==100)throw Error('wrong game');return items;},
            GetSubscribedWorkshopItemDetails:async(app,ids)=>[{publishedfileid:ids[0],title:'Mod',short_description:'Summary',children:['20'],privateField:'secret'}],
            GetDownloadedWorkshopItems:async()=>[{publishedfileid:'9007199254740993'}],
            RegisterForAppDetails:(app,callback)=>{callback({unAppID:100,bWorkshopVisible:true});return{unregister:()=>unregistered++};},
            SubscribeWorkshopItem:async(app,id,subscribed)=>{calls++;items=subscribed?[...items,{publishedfileid:id,disabled_locally:false,load_order:items.length}]:items.filter(x=>x.publishedfileid!==id);},
            SetWorkshopItemsDisabledLocally:async(app,ids,disabled)=>{calls++;items=items.map(x=>ids.includes(x.publishedfileid)?{...x,disabled_locally:disabled}:x);},
            SetWorkshopItemsLoadOrder:async(app,ids)=>{calls++;items=ids.map((id,index)=>({...items.find(x=>x.publishedfileid===id),load_order:index}));}
        }};
        \(fixture)
        eval(\(literal)).then(value=>process.stdout.write(JSON.stringify({value:JSON.parse(value),items,calls,unregistered}))).catch(error=>process.stdout.write(JSON.stringify({error:error.message,items,calls,unregistered})));
        """
        let process = Process(); process.executableURL = URL(fileURLWithPath: node); process.arguments = ["-e", source]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testBridgeSelectionWaitsForToolAcknowledgmentAndReleasesRegistration() throws {
        let fixture = """
        let details,tool='';
        SteamClient.Apps.RegisterForAppDetails=(app,callback)=>{details=callback;callback({unAppID:app,strCompatToolName:tool,nCompatToolPriority:tool?250:0});return {unregister:()=>unregistered++};};
        SteamClient.Apps.SpecifyCompatTool=(app,value)=>{calls++;tool=value;queueMicrotask(()=>details({unAppID:app,strCompatToolName:tool,nCompatToolPriority:tool?250:0}));};
        """
        for enabled in [true, false] {
            let result = try run(.crossOver(100, enabled), fixture: fixture + (enabled ? "" : "tool='wayfarer-proton';"))
            XCTAssertNil(result["error"])
            XCTAssertEqual(result["calls"] as? Int, 1)
            XCTAssertEqual(result["unregistered"] as? Int, 1)
        }
        let unchanged = try run(.crossOver(100, true), fixture: fixture + "tool='wayfarer-proton';")
        XCTAssertEqual(unchanged["calls"] as? Int, 0)
        let refused = try run(.crossOver(100, true), fixture: fixture + "appStore.GetAppOverviewByAppID=()=>({BIsOwned:()=>true,local_per_client_data:{installed:true,display_status:4}});")
        XCTAssertNotNil(refused["error"])
        XCTAssertEqual(refused["calls"] as? Int, 0)
        let timedOut = try run(.crossOver(100, true), fixture: fixture + "SteamClient.Apps.SpecifyCompatTool=()=>{calls++;};globalThis.setTimeout=callback=>{queueMicrotask(callback);return 0;};")
        XCTAssertNotNil(timedOut["error"])
        XCTAssertEqual(timedOut["unregistered"] as? Int, 1)
    }

    func testSnapshotUsesExactStringIdentifiersAndReleasesDetailRegistration() throws {
        let result = try run(.workshop(100))
        XCTAssertNil(result["error"]); XCTAssertEqual(result["unregistered"] as? Int, 1)
        let value = try XCTUnwrap(result["value"] as? [String: Any])
        let snapshot = try JSONDecoder().decode(SteamWorkshopSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(snapshot.items.first?.id, "9007199254740993")
        XCTAssertEqual(snapshot.items.first?.title, "Mod"); XCTAssertEqual(snapshot.items.first?.download, .downloaded)
        XCTAssertEqual(snapshot.items.first?.dependencies, ["20"])
        XCTAssertFalse(String(describing: value).contains("secret"))
    }
    func testUnsupportedDetailsStillReturnSubscriptionsWithoutPretendingSupport() throws {
        let result = try run(.workshop(100), fixture: "delete SteamClient.Apps.RegisterForAppDetails;delete SteamClient.Apps.GetSubscribedWorkshopItemDetails;delete SteamClient.Apps.SetWorkshopItemsLoadOrder;")
        XCTAssertNil(result["error"])
        let value = try XCTUnwrap(result["value"] as? [String: Any])
        let snapshot = try JSONDecoder().decode(SteamWorkshopSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(snapshot.supported); XCTAssertFalse(snapshot.capabilities.reorder)
        XCTAssertEqual(snapshot.items.count, 1)
    }
    func testChangesRequireOnlineOwnedClosedGameBeforeCallingSteam() throws {
        for fixture in ["App.BHasCurrentUser=()=>false;", "App.BIsOfflineMode=()=>true;", "appStore.GetAppOverviewByAppID=()=>({BIsOwned:()=>false,local_per_client_data:{installed:true,display_status:11}});", "appStore.GetAppOverviewByAppID=()=>({BIsOwned:()=>true,local_per_client_data:{installed:true,display_status:4}});"] {
            let result = try run(.workshopChange(100, .subscribe("20", true)), fixture: fixture)
            XCTAssertNotNil(result["error"]); XCTAssertEqual(result["calls"] as? Int, 0)
        }
    }
    func testSubscriptionAndLocalEnableAreConfirmedFromFreshState() throws {
        let subscribed = try run(.workshopChange(100, .subscribe("20", true)))
        XCTAssertNil(subscribed["error"]); XCTAssertEqual(subscribed["calls"] as? Int, 1)
        let removed = try run(.workshopChange(100, .subscribe("9007199254740993", false)))
        XCTAssertNil(removed["error"]); XCTAssertTrue((removed["items"] as? [[String: Any]])?.isEmpty == true)
        let disabled = try run(.workshopChange(100, .enabled("9007199254740993", false)))
        XCTAssertNil(disabled["error"]); XCTAssertEqual((disabled["items"] as? [[String: Any]])?.first?["disabled_locally"] as? Bool, true)
    }
    func testReorderRejectsStaleSubscriptionListAndConfirmsNewOrder() throws {
        let old = ["9007199254740993", "20"], new = ["20", "9007199254740993"]
        let stale = try run(.workshopChange(100, .reorder(old, new)))
        XCTAssertEqual(stale["error"] as? String, "Workshop subscriptions changed"); XCTAssertEqual(stale["calls"] as? Int, 0)
        let changed = try run(.workshopChange(100, .reorder(old, new)), fixture: "items.push({publishedfileid:'20',disabled_locally:false,load_order:1});")
        XCTAssertNil(changed["error"]); XCTAssertEqual((changed["items"] as? [[String: Any]])?.first?["publishedfileid"] as? String, "20")
    }
    func testUnconfirmedChangeDoesNotReportSuccess() throws {
        let result = try run(.workshopChange(100, .subscribe("20", true)), fixture: "SteamClient.Apps.SubscribeWorkshopItem=async()=>{calls++;};globalThis.setTimeout=callback=>{queueMicrotask(callback);return 0;};")
        XCTAssertEqual(result["error"] as? String, "Workshop change not confirmed"); XCTAssertNil(result["value"])
    }
    func testChangedResponseAndUnsupportedActionNeverCallMutation() throws {
        let invalid = try run(.workshopChange(100, .enabled("9007199254740993", false)), fixture: "items[0].publishedfileid=9007199254740993;")
        XCTAssertEqual(invalid["error"] as? String, "Workshop response changed"); XCTAssertEqual(invalid["calls"] as? Int, 0)
        let unsupported = try run(.workshopChange(100, .enabled("9007199254740993", false)), fixture: "delete SteamClient.Apps.SetWorkshopItemsDisabledLocally;")
        XCTAssertEqual(unsupported["error"] as? String, "Workshop controls are unavailable"); XCTAssertEqual(unsupported["calls"] as? Int, 0)
    }
}

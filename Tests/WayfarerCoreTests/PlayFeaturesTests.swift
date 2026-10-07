import XCTest
@testable import WayfarerCore

final class PlayFeaturesTests:XCTestCase {
    func testNativeSessionSnapshotCoalescesDuplicatePIDsAndSkipsPendingApplications() {
        let old = URL(fileURLWithPath: "/Applications/Old.app")
        let current = URL(fileURLWithPath: "/Applications/Current.app")
        let other = URL(fileURLWithPath: "/Applications/Other.app")
        let snapshot = SessionMonitorInput.nativeBundleSnapshot([
            (0, old), (-1, old), (0, current), (123, old), (456, other), (123, current)
        ])
        XCTAssertEqual(snapshot, [123: current, 456: other])
    }
    func testDisconnectedGameIsNotReportedAsCrashOrFinished() {
        var record=GameSessionRecord(gameID:"steam:100",name:"Game",platform:.windows,environmentID:"bottle")
        let date=record.requestedAt
        record.observe(running:true,now:date.addingTimeInterval(3))
        record.observe(running:nil,now:date.addingTimeInterval(20))
        XCTAssertEqual(record.phase,.disconnected);XCTAssertTrue(record.phase.active);XCTAssertNil(record.endedAt)
        record.observe(running:true,now:date.addingTimeInterval(30));XCTAssertEqual(record.phase,.playing)
        record.observe(running:false,now:date.addingTimeInterval(45));XCTAssertEqual(record.phase,.finished);XCTAssertEqual(record.duration,42)
    }
    func testLaunchAcknowledgementDoesNotEndSessionAndTimeoutNeedsKnownNotRunning() {
        var record=GameSessionRecord(gameID:"steam:100",name:"Game",platform:.macOS,environmentID:nil)
        record.observe(running:false,now:record.requestedAt.addingTimeInterval(10));XCTAssertEqual(record.phase,.launching)
        record.observe(running:nil,now:record.requestedAt.addingTimeInterval(130));XCTAssertTrue(record.phase.active)
        record.observe(running:false,now:record.requestedAt.addingTimeInterval(131));XCTAssertEqual(record.phase,.failed)
    }
    func testStopRetainsActiveGuardUntilGameActuallyExits() {
        var record=GameSessionRecord(gameID:"steam:100",name:"Game",platform:.macOS,environmentID:nil)
        record.observe(running:true);record.phase = .stopping;record.observe(running:true)
        XCTAssertEqual(record.phase,.stopping);XCTAssertTrue(record.phase.active)
        record.observe(running:false);XCTAssertEqual(record.phase,.finished)
    }
    func testRecoveryRequiresPreviousConnectionAndSafeStateAndBacksOff() {
        var policy=BackendRecovery();let now=Date()
        policy.failed();policy.failed();XCTAssertFalse(policy.shouldRetry(now:now,safe:true,enabled:true))
        policy.connected();policy.failed();policy.failed()
        XCTAssertFalse(policy.shouldRetry(now:now,safe:false,enabled:true));XCTAssertFalse(policy.shouldRetry(now:now,safe:true,enabled:false));XCTAssertTrue(policy.shouldRetry(now:now,safe:true,enabled:true))
        policy.attempted(now:now);XCTAssertFalse(policy.shouldRetry(now:now.addingTimeInterval(29),safe:true,enabled:true));XCTAssertTrue(policy.shouldRetry(now:now.addingTimeInterval(31),safe:true,enabled:true))
        policy.attempted(now:now);policy.attempted(now:now);XCTAssertFalse(policy.shouldRetry(now:now.addingTimeInterval(1000),safe:true,enabled:true))
        policy.connected();XCTAssertEqual(policy.attempts,0)
    }
    func testControllerGridHandlesPartialLastRowAndEmptyList(){XCTAssertEqual(ControllerGrid.destination(index:9,count:12,columns:5,dx:0,dy:1),11);XCTAssertEqual(ControllerGrid.destination(index:0,count:12,columns:5,dx:-1,dy:0),0);XCTAssertEqual(ControllerGrid.destination(index:10,count:0,columns:5,dx:1,dy:0),0)}
    func testQuickSearchMatchesTokensTagsAndDiacritics(){XCTAssertTrue(QuickSearch.matches("cafe coop",name:"Café game",tags:["Coop"]));XCTAssertFalse(QuickSearch.matches("cafe racing",name:"Café game",tags:["Coop"]))}
    func testCompatibilityFingerprintChangesWithEngineFile()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let wine=root.appendingPathComponent("wine");try Data("v1".utf8).write(to:wine)
        let profile=RuntimeProfile(runtime:RuntimeInstallation(kind:.wine,executable:wine),prefix:root,name:"Test")
        let old=CompatibilityTest.fingerprint(profile);try Data("v2-is-different".utf8).write(to:wine);XCTAssertNotEqual(old,CompatibilityTest.fingerprint(profile))
    }
    func testAchievementCacheSeparatesAccountsPlatformsAndEnvironments()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let cache=AchievementCache(directory:root)
        let item=try JSONDecoder().decode(SteamAchievement.self,from:Data(#"{"id":"one","name":"Achievement","description":"Description","achieved":true,"hidden":false}"#.utf8))
        let scope=String(repeating:"long-root/",count:50)+"accountA:mac"
        try cache.save(AchievementSnapshot(scope:scope,appID:"100",updatedAt:Date(),achievements:[item]));XCTAssertEqual(try cache.load(scope:scope,appID:"100").achievements.count,1)
        for other in ["accountB:mac","accountA:windows:bottle2"]{XCTAssertThrowsError(try cache.load(scope:other,appID:"100"))}
    }
    func testNewRecordsPersistWithoutChangingOlderConfiguration()throws{
        var config=LauncherConfiguration();config.gameSessions=[GameSessionRecord(gameID:"steam:100",name:"Game",platform:.windows,environmentID:"one")]
        let decoded=try JSONDecoder().decode(LauncherConfiguration.self,from:JSONEncoder().encode(config));XCTAssertEqual(decoded.gameSessions?.count,1);XCTAssertNil(decoded.compatibilityTests)
    }
    func testSizeMeasurementDoesNotFollowLinksOutsideAppAndHasBound()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let app=root.appendingPathComponent("Game.app"),outside=root.appendingPathComponent("Other");try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true);try Data(repeating:1,count:50000).write(to:outside);try Data([1,2,3]).write(to:app.appendingPathComponent("main"));let before=try InstalledSize.bytes(at:app);try FileManager.default.createSymbolicLink(at:app.appendingPathComponent("link"),withDestinationURL:outside);XCTAssertEqual(try InstalledSize.bytes(at:app),before);XCTAssertThrowsError(try InstalledSize.bytes(at:app,maximumEntries:0))
    }
    func testCrashEvidenceExcludesUnknownCodesChildrenAndOldSessions(){
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.dateFormat="yyyy-MM-dd HH:mm:ss";let date=format.date(from:"2026-10-06 12:00:00")!
        let start="[2026-10-06 12:00:00] AppID 100 adding PID 22 as a tracked process game.exe\n[2026-10-06 12:00:00] AppID 100 adding PID 23 as a tracked process helper.exe\n"
        XCTAssertNil(SteamGameExit.abnormalCode(text:start+"[2026-10-06 12:02:00] AppID 100 no longer tracking PID 23, exit code 5",appID:"100",since:date))
        for code in [-1,0]{XCTAssertNil(SteamGameExit.abnormalCode(text:start+"[2026-10-06 12:02:00] AppID 100 no longer tracking PID 22, exit code \(code)",appID:"100",since:date))}
        let crashed=start+"[2026-10-06 12:02:00] AppID 100 no longer tracking PID 22, exit code 5"
        XCTAssertEqual(SteamGameExit.abnormalCode(text:crashed,appID:"100",since:date),5);XCTAssertNil(SteamGameExit.abnormalCode(text:crashed,appID:"100",since:date.addingTimeInterval(300)))
    }
    private func run(_ action:SteamControl.Action,fixture:String)throws->[String:Any]{
        guard let node=["/opt/homebrew/bin/node","/usr/local/bin/node","/usr/bin/node"].first(where:{FileManager.default.isExecutableFile(atPath:$0)})else{throw XCTSkip("Node required for API fixture")}
        let literal=String(decoding:try JSONEncoder().encode(SteamControl.script(action)),as:UTF8.self)
        let source="""
        globalThis.window=globalThis;globalThis.App={BHasCurrentUser:()=>true,BIsOfflineMode:()=>false};
        let terminated=0,verified=0,moved=0;
        globalThis.SteamClient={Installs:{},Apps:{TerminateApp:async(id,force)=>{terminated++;if(id!=='100'||force!==false)throw Error('wrong target');}},InstallFolder:{}};
        globalThis.appStore={GetAppOverviewByAppID:()=>({BIsOwned:()=>true,local_per_client_data:{installed:true,display_status:11}})};
        globalThis.downloadsStore={m_DownloadItems:new Map([['0',[]]])};
        \(fixture)
        eval(\(literal)).then(value=>process.stdout.write(JSON.stringify({value:JSON.parse(value),terminated,verified,moved}))).catch(error=>process.stdout.write(JSON.stringify({error:error.message,terminated,verified,moved})));
        """
        let task=Process();task.executableURL=URL(fileURLWithPath:node);task.arguments=["-e",source];let pipe=Pipe();task.standardOutput=pipe;task.standardError=FileHandle.nullDevice;try task.run();let output=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();XCTAssertEqual(task.terminationStatus,0);return try XCTUnwrap(JSONSerialization.jsonObject(with:output) as? [String:Any])
    }
    private var foldersFixture:String{"""
    SteamClient.InstallFolder.GetInstallFolders=async()=>[{nFolderIndex:0,strFolderPath:'/source',strUserLabel:'One',bIsMounted:true,nFreeSpace:1000,vecApps:[{nAppID:100,nUsedSize:100}]},{nFolderIndex:1,strFolderPath:'/target',strDriveName:'Two',bIsMounted:true,nFreeSpace:200,vecApps:[]}];
    SteamClient.InstallFolder.RegisterForMoveContentProgress=callback=>{globalThis.moveCallback=callback};
    SteamClient.InstallFolder.MoveInstallFolderForApp=async(id,index)=>{moved++;if(id!==100||index!==1)throw Error('wrong target');moveCallback({appid:id,eError:20,flProgress:.25})};
    """}
    func testStopTargetsOnlySelectedRunningGameAndDoesNotForceQuit()throws{
        let result=try run(.terminateGame(100),fixture:"appStore.GetAppOverviewByAppID=()=>({BIsOwned:()=>true,local_per_client_data:{installed:true,display_status:1}});")
        XCTAssertNil(result["error"]);XCTAssertEqual(result["terminated"] as? Int,1)
        let idle=try run(.terminateGame(100),fixture:"");XCTAssertEqual(idle["terminated"] as? Int,0)
    }
    func testMaintenanceRefusesRunningGameDownloadAndUnknownOverview()throws{
        for fixture in ["appStore.GetAppOverviewByAppID=()=>({BIsOwned:()=>true,local_per_client_data:{installed:true,display_status:1}});","downloadsStore.m_DownloadItems.set('0',[{appid:100}]);","appStore.GetAppOverviewByAppID=()=>({});"]{
            let result=try run(.moveGame(100,1),fixture:foldersFixture+fixture);XCTAssertNotNil(result["error"]);XCTAssertEqual(result["moved"] as? Int,0)
        }
    }
    func testMoveValidatesMountedDestinationAndSpaceBeforeMutation()throws{
        for fixture in ["SteamClient.InstallFolder.GetInstallFolders=async()=>[];","SteamClient.InstallFolder.GetInstallFolders=async()=>[{nFolderIndex:0,bIsMounted:true,vecApps:[{nAppID:100,nUsedSize:500}]},{nFolderIndex:1,bIsMounted:true,nFreeSpace:100,vecApps:[]}];","SteamClient.InstallFolder.GetInstallFolders=async()=>[{nFolderIndex:0,bIsMounted:true,vecApps:[{nAppID:100,nUsedSize:100}]},{nFolderIndex:1,bIsMounted:false,nFreeSpace:1000,vecApps:[]}];"]{
            let result=try run(.moveGame(100,1),fixture:foldersFixture+fixture);XCTAssertNotNil(result["error"]);XCTAssertEqual(result["moved"] as? Int,0)
        }
        let valid=try run(.moveGame(100,1),fixture:foldersFixture);XCTAssertNil(valid["error"]);XCTAssertEqual(valid["moved"] as? Int,1)
    }
    func testVerifyAcceptsActionIDAndWaitsForNativeCompletion()throws{
        let result=try run(.verifyFiles(100),fixture:"SteamClient.Apps.RegisterForGameActionTaskChange=callback=>{globalThis.taskChanged=callback};SteamClient.Apps.GetGameActionDetails=()=>{};SteamClient.Apps.VerifyApp=async id=>{verified++;taskChanged(42,'100','VerifyApp','Completed','5');return {nGameActionID:42}};")
        XCTAssertNil(result["error"]);XCTAssertEqual(result["verified"] as? Int,1)
    }
    func testMaintenanceProgressDoesNotInventCompletionFromPercentage()throws{
        let result=try run(.maintenanceProgress(100),fixture:"window.__WayfarerMaintenance={entries:{100:{kind:'move',progress:1,task:'Moving files',completed:false,failed:false}}};")
        let value=try XCTUnwrap(result["value"] as? [String:Any]);XCTAssertEqual(value["completed"] as? Bool,false)
    }
    func testHiddenAchievementSpoilersAndExtraAccountFieldsAreNotExported()throws{
        let result=try run(.achievements(100),fixture:"SteamClient.Apps.GetMyAchievementsForApp=async()=>({result:1,data:{account:'private',rgAchievements:[{strID:'secret',strName:'Spoiler',strDescription:'Ending spoiler',bHidden:true,bAchieved:false,access_token:'private'},{strID:'first',strName:'First',strDescription:'Done',bHidden:false,bAchieved:true,rtUnlocked:100,flAchieved:20}]}});")
        let items=try XCTUnwrap(result["value"] as? [[String:Any]]);XCTAssertEqual(items[0]["name"] as? String,"Hidden achievement")
        let data=String(decoding:try JSONSerialization.data(withJSONObject:items),as:UTF8.self);XCTAssertFalse(data.contains("Spoiler"));XCTAssertFalse(data.contains("private"));XCTAssertEqual(items[1]["unlockedAt"] as? Int,100)
    }
    func testUnavailableAchievementsAreDistinctFromValidEmptyList()throws{
        let unavailable=try run(.achievements(100),fixture:"SteamClient.Apps.GetMyAchievementsForApp=async()=>({result:15});");XCTAssertNotNil(unavailable["error"])
        let empty=try run(.achievements(100),fixture:"SteamClient.Apps.GetMyAchievementsForApp=async()=>({result:1,data:{rgAchievements:[]}});");XCTAssertNil(empty["error"]);XCTAssertEqual((empty["value"] as? [Any])?.count,0)
    }
}

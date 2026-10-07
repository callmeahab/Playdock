import XCTest
@testable import WayfarerCore

final class InstallationRecoveryTests: XCTestCase {
    private func plan() throws -> SteamInstallPlan {
        try JSONDecoder().decode(SteamInstallPlan.self,from:Data(#"{"appID":"100","state":7,"requiredBytes":100,"availableBytes":200,"folder":0,"currentAppID":100,"error":0,"detail":"","eulas":[]}"#.utf8))
    }
    func testFailedConfirmationClearsDetailsAndAllowsRetry() throws {
        var state=SteamInstallDialogState()
        let prepare=state.begin("Preparing")
        state.finish(prepare,plan:try plan(),message:"Ready")
        XCTAssertTrue(state.plan?.canConfirm == true)
        let confirm=state.begin("Starting",keepPlan:true)
        state.finish(confirm,message:"Installation changed. Retry.")
        XCTAssertNil(state.plan); XCTAssertFalse(state.busy)
        let retry=state.begin("Retrying")
        state.finish(retry,plan:try plan(),message:"Ready")
        XCTAssertTrue(state.plan?.canConfirm == true)
    }
    func testCancelDuringConnectionClosesImmediatelyAndIgnoresLateReply() throws {
        var state=SteamInstallDialogState()
        let previous=state.begin("Connecting")
        state.dismiss()
        XCTAssertFalse(state.busy); XCTAssertNil(state.plan)
        state.finish(previous,plan:try plan(),message:"Ready")
        XCTAssertNil(state.plan); XCTAssertEqual(state.message,"")
    }
    func testOldReplyCannotOverwriteNewRequest() throws {
        var state=SteamInstallDialogState()
        let previous=state.begin("Old request")
        state.dismiss()
        let current=state.begin("New request")
        state.finish(previous,message:"Old failure")
        XCTAssertTrue(state.busy); XCTAssertEqual(state.message,"New request")
        state.finish(current,plan:try plan(),message:"Ready")
        XCTAssertNotNil(state.plan); XCTAssertFalse(state.busy)
    }
    /// Run production scripts against an isolated Steam fixture.
    private func run(_ action:SteamControl.Action, fixture:String) throws -> [String:Any] {
        guard let node=["/opt/homebrew/bin/node","/usr/local/bin/node","/usr/bin/node"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else { throw XCTSkip("Node is required for Steam script fixtures") }
        let literal=String(decoding:try JSONEncoder().encode(SteamControl.script(action)),as:UTF8.self)
        let source="""
        globalThis.window=globalThis;
        globalThis.App={BHasCurrentUser:()=>true,BIsOfflineMode:()=>false};
        globalThis.appStore={GetAppOverviewByAppID:()=>({BIsOwned:()=>true})};
        let cancelled=0,opened=0,continued=0,reads=0;
        const info=(state,ids)=>({eInstallState:state,rgApps:ids.map(nAppID=>({nAppID})),nDiskSpaceRequired:100,nDiskSpaceAvailable:200,iInstallFolder:0,currentAppID:100,eAppError:0,errorDetail:''});
        globalThis.SteamClient={Installs:{CancelInstall:async()=>{cancelled++},OpenInstallWizard:async()=>{opened++},ContinueInstall:async()=>{continued++},SetCreateShortcuts:async()=>{}},Apps:{LoadEula:async()=>[]}};
        globalThis.setTimeout=callback=>{callback();return 0};
        \(fixture)
        eval(\(literal)).then(value=>process.stdout.write(JSON.stringify({value:JSON.parse(value),cancelled,opened,continued,reads}))).catch(error=>process.stdout.write(JSON.stringify({error:error.message,cancelled,opened,continued,reads})));
        """
        let process=Process(); process.executableURL=URL(fileURLWithPath:node); process.arguments=["-e",source]
        let output=Pipe(); process.standardOutput=output; process.standardError=FileHandle.nullDevice
        try process.run(); let data=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    }
    func testPreparationWaitsPastOldCompletedWizard() throws {
        let result=try run(.prepareInstall(100),fixture:"SteamClient.Installs.GetInstallManagerInfo=async()=>info(++reads<4?14:7,reads<4?[200]:[100]);")
        XCTAssertNil(result["error"]); XCTAssertEqual(result["opened"] as? Int,1)
        XCTAssertEqual((result["value"] as? [String:Any])?["state"] as? Int,7)
    }
    func testRetryAcknowledgesOwnFailedWizardBeforeOpeningFreshConfirmation() throws {
        let result=try run(.prepareInstall(100),fixture:"""
        let state=15;
        SteamClient.Installs.GetInstallManagerInfo=async()=>({...info(state,[100]),eAppError:state===15?6:0});
        SteamClient.Installs.CancelInstall=async()=>{cancelled++;state=0};
        SteamClient.Installs.OpenInstallWizard=async()=>{opened++;state=7};
        """)
        XCTAssertNil(result["error"]); XCTAssertEqual(result["cancelled"] as? Int,1); XCTAssertEqual(result["opened"] as? Int,1)
        XCTAssertEqual((result["value"] as? [String:Any])?["state"] as? Int,7)
        XCTAssertEqual((result["value"] as? [String:Any])?["error"] as? Int,0)
    }
    func testCancelIsSafeWhenWizardGoneChangedOrDownloadStarted() throws {
        for fixture in ["info(14,[])","info(7,[200])","info(7,[100,200])","info(9,[100])","info(10,[100])","info(11,[100])"] {
            let result=try run(.cancel(100),fixture:"SteamClient.Installs.GetInstallManagerInfo=async()=>\(fixture);")
            XCTAssertNil(result["error"]); XCTAssertEqual(result["cancelled"] as? Int,0)
        }
        let own=try run(.cancel(100),fixture:"SteamClient.Installs.GetInstallManagerInfo=async()=>info(7,[100]);")
        XCTAssertEqual(own["cancelled"] as? Int,1)
    }
    func testChangedWizardCannotConfirmAnotherGame() throws {
        let result=try run(.install(100,[]),fixture:"SteamClient.Installs.GetInstallManagerInfo=async()=>info(7,[200]);")
        XCTAssertEqual(result["error"] as? String,"The installation changed")
        XCTAssertEqual(result["continued"] as? Int,0)
    }
    func testFriendsSnapshotExcludesMessagesAndAccountSecrets() throws {
        let result=try run(.friends,fixture:"""
        const friend={steamid64:'76561198000000001',persona:{m_strPlayerName:'Friend',m_ePersonaState:1},current_game_name:'Game',access_token:'never-export'};
        globalThis.g_FriendsUIApp={FriendStore:{friends_list_ready:true,all_friends_accountids:[42],GetFriend:()=>friend},ChatStore:{GetFriendChat:()=>({unread_message_count:3,messages:['private conversation']})}};
        """)
        let value=try XCTUnwrap(result["value"] as? [String:Any])
        let friends=try XCTUnwrap(value["friends"] as? [[String:Any]])
        XCTAssertEqual(friends.count,1); XCTAssertEqual(friends[0]["unread"] as? Int,3)
        XCTAssertEqual(Set(friends[0].keys),["id","name","state","game","unread"])
        let text=String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        XCTAssertFalse(text.contains("never-export")); XCTAssertFalse(text.contains("private conversation"))
    }
    func testCloudReadsFreshSubscriptionAndUnregistersWithoutExportingExtraFields() throws {
        let result=try run(.cloud(100),fixture:"""
        globalThis.setTimeout=()=>0;
        globalThis.clearTimeout=()=>{};
        globalThis.appDetailsStore={RequestAppDetails:()=>{throw Error('Cached details must not be used')}};
        SteamClient.Apps.RegisterForAppDetails=(id,callback)=>{callback({unAppID:id,bCloudEnabledForApp:true,bCloudEnabledForAccount:true,eCloudStatus:3,nCloudProgressPercent:0,strAccountName:'private account'});return {unregister:()=>{cancelled++}}};
        """)
        XCTAssertNil(result["error"]); XCTAssertEqual(result["cancelled"] as? Int,1)
        let value=try XCTUnwrap(result["value"] as? [String:Any])
        XCTAssertEqual(value["state"] as? Int,3)
        XCTAssertEqual(Set(value.keys),["appEnabled","accountEnabled","state","progress"])
    }

    func testActiveDownloadUsesFreshOverviewInsteadOfStaleQueueCounters() throws {
        let result=try run(.snapshot,fixture:"""
        SteamClient.InstallFolder={GetInstallFolders:async()=>[]};
        globalThis.downloadsStore={m_DownloadItems:new Map([['0',[{appid:100,active:true,completed:false,paused:false,update_type_info:[{progress:[{}, {}, {bytes_in_progress:0,bytes_total:2000}]}]},{appid:200,active:false,completed:false,paused:false,update_type_info:[{progress:[{}, {}, {bytes_in_progress:20,bytes_total:100}]}]}]]]),m_DownloadOverview:new Map([['0',{update_appid:100,update_state:'Downloading',update_network_bytes_per_second:50,update_disc_bytes_per_second:90,overall_estimated_time_remaining_sec:30,progress:[{},{},{bytes_in_progress:500,bytes_total:2000}]}]])};
        """)
        let value=try XCTUnwrap(result["value"] as? [String:Any]),downloads=try XCTUnwrap(value["downloads"] as? [[String:Any]])
        let active=try JSONDecoder().decode(SteamLiveDownload.self,from:JSONSerialization.data(withJSONObject:downloads[0]))
        XCTAssertEqual(active.downloaded,500); XCTAssertEqual(active.total,2000); XCTAssertEqual(active.networkBytesPerSecond,50)
        let progress=SteamDownloadProgress(live:active,saved:nil)
        XCTAssertEqual(progress.fraction,0.25); XCTAssertEqual(progress.phase,"Downloading")
        let queued=try JSONDecoder().decode(SteamLiveDownload.self,from:JSONSerialization.data(withJSONObject:downloads[1]))
        XCTAssertEqual(queued.downloaded,20); XCTAssertNil(queued.networkBytesPerSecond); XCTAssertNil(queued.updateState)
    }
    func testPreallocationShowsDiskProgressWhileNetworkBytesAreStillZero() throws {
        let live=try JSONDecoder().decode(SteamLiveDownload.self,from:Data(#"{"appID":"100","name":"Game","paused":false,"active":true,"downloaded":0,"total":2000,"updateState":"Preallocating","phaseDownloaded":1000,"phaseTotal":4000,"networkBytesPerSecond":0,"diskBytesPerSecond":500}"#.utf8))
        let progress=SteamDownloadProgress(live:live,saved:nil)
        XCTAssertEqual(progress.phase,"Preparing disk space"); XCTAssertEqual(progress.fraction,0.25)
        XCTAssertEqual(progress.total,4000); XCTAssertEqual(progress.diskBytesPerSecond,500)
        XCTAssertTrue(progress.detail?.contains("reserving disk space") == true)
    }
    func testUnknownWorkingPhaseDoesNotInventZeroPercentDownload() throws {
        let live=try JSONDecoder().decode(SteamLiveDownload.self,from:Data(#"{"appID":"100","name":"Game","paused":false,"active":true,"downloaded":0,"total":2000,"updateState":"NewSteamPhase"}"#.utf8))
        let progress=SteamDownloadProgress(live:live,saved:nil)
        XCTAssertEqual(progress.phase,"Waiting for Steam"); XCTAssertNil(progress.fraction)
    }

}

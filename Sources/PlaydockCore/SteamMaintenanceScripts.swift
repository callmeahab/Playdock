import Foundation

enum SteamMaintenanceScripts {
    static let folders = """
    if(!App.BHasCurrentUser())throw Error('Steam is not signed in.');
    const folders=await SteamClient.InstallFolder.GetInstallFolders();
    const bytes=v=>Number.isFinite(Number(v))?Math.min(Number.MAX_SAFE_INTEGER,Math.max(0,Math.trunc(Number(v)))):0;
    return folders.filter(f=>f.bIsMounted).slice(0,100).map(f=>({id:f.nFolderIndex,path:String(f.strFolderPath).slice(0,4096),name:String(f.strUserLabel||f.strDriveName||'Steam library').slice(0,128),freeBytes:bytes(f.nFreeSpace),apps:(f.vecApps||[]).slice(0,10000).map(a=>({id:String(a.nAppID),bytes:bytes(a.nUsedSize)}))}));
    """
    static let jobs = """
    const jobs=window.__PlaydockMaintenance||(window.__PlaydockMaintenance={entries:{},moveRegistered:false,verifyRegistered:false});
    """
    static func guardGame(_ id:UInt32)->String { """
    if(!App.BHasCurrentUser())throw Error('Steam is not signed in.');
    const state=localState(\(id));
    if(!state.installed||!state.owned||state.displayStatus<=0)throw Error('Steam has not reported this installation.');
    if([1,4].includes(state.displayStatus))throw Error('Close this game before changing its files.');
    if(state.displayStatus===2)throw Error('Steam is already uninstalling this game.');
    const items=window.downloadsStore?.m_DownloadItems?.get('0');
    if(!Array.isArray(items))throw Error('Storage controls are unavailable');
    if(items.some(a=>String(a.appid)==='\(id)'))throw Error('Wait for this game’s download to finish.');
    \(jobs)
    if(jobs.entries[\(id)]&&!jobs.entries[\(id)].completed&&!jobs.entries[\(id)].failed)throw Error('A storage operation is already running.');
    """ }
    static func verify(_ id:UInt32)->String { """
    \(guardGame(id))
    const apps=SteamClient.Apps;
    if(typeof apps.VerifyApp!=='function'||typeof apps.GetGameActionDetails!=='function'||typeof apps.RegisterForGameActionTaskChange!=='function')throw Error('Storage controls are unavailable');
    if(!jobs.verifyRegistered){
      apps.RegisterForGameActionTaskChange((action,game,kind,task,detail)=>{const j=jobs.entries[Number(game)];if(j?.kind==='verify'&&(j.action===action||j.action===0)){j.task=String(task||'Verifying').slice(0,160);j.completed=task==='Completed';j.failed=task==='Failed';if(j.completed)j.progress=1;}});
      jobs.verifyRegistered=true;
    }
    const j=jobs.entries[\(id)]={kind:'verify',action:0,progress:null,task:'Starting verification',completed:false,failed:false};
    try{const result=await apps.VerifyApp(\(id));if(!Number.isInteger(result?.nGameActionID)||result.nGameActionID<=0)throw Error('Storage controls are unavailable');j.action=result.nGameActionID;}catch(e){delete jobs.entries[\(id)];throw e;}
    return {ok:true};
    """ }
    static func move(_ id:UInt32,folder:Int)->String { """
    \(guardGame(id))
    const api=SteamClient.InstallFolder;
    if(typeof api.MoveInstallFolderForApp!=='function'||typeof api.RegisterForMoveContentProgress!=='function')throw Error('Storage controls are unavailable');
    if(Object.values(jobs.entries).some(j=>j.kind==='move'&&!j.completed&&!j.failed))throw Error('A storage operation is already running.');
    const folders=await api.GetInstallFolders(),source=folders.find(f=>(f.vecApps||[]).some(a=>a.nAppID===\(id))),target=folders.find(f=>f.nFolderIndex===\(folder)&&f.bIsMounted);
    if(!source||!source.bIsMounted||!target||source.nFolderIndex===target.nFolderIndex||(target.vecApps||[]).some(a=>a.nAppID===\(id)))throw Error('Library unavailable');
    const app=source.vecApps.find(a=>a.nAppID===\(id));
    if(!Number.isFinite(Number(app.nUsedSize))||Number(app.nUsedSize)>Number(target.nFreeSpace))throw Error('Not enough space');
    if(!jobs.moveRegistered){api.RegisterForMoveContentProgress(v=>{const j=jobs.entries[v.appid];if(j?.kind==='move'){j.progress=Number.isFinite(v.flProgress)?Math.min(1,Math.max(0,v.flProgress)):null;j.completed=v.eError===0;j.failed=v.eError!==0&&v.eError!==20;j.task=j.failed?'Steam could not move these files':j.completed?'Completed':'Moving game files';}});jobs.moveRegistered=true;}
    const j=jobs.entries[\(id)]={kind:'move',progress:null,task:'Starting move',completed:false,failed:false};
    try{await api.MoveInstallFolderForApp(\(id),\(folder));}catch(e){delete jobs.entries[\(id)];throw e;}return {ok:true};
    """ }
    static func progress(_ id:UInt32)->String { """
    \(jobs)
    const j=jobs.entries[\(id)];if(!j)throw Error('Storage status is unavailable');
    if(j.kind==='verify'&&j.action&&!j.completed&&!j.failed){
      await new Promise(resolve=>{let timer=setTimeout(resolve,2500);SteamClient.Apps.GetGameActionDetails(j.action,v=>{clearTimeout(timer);const done=Number(v.strNumDone),total=Number(v.strNumTotal);if(total>0&&done>=0)j.progress=Math.min(1,done/total);if(v.strTaskName)j.task=String(v.strTaskName).slice(0,160);if(v.strTaskName==='Completed')j.completed=true;if(v.strTaskName==='Failed')j.failed=true;resolve();});});
    }
    return {kind:j.kind,progress:j.progress,task:j.task,completed:j.completed,failed:j.failed};
    """ }
    static func achievements(_ id:UInt32)->String { """
    if(!App.BHasCurrentUser())throw Error('Steam is not signed in.');
    if(typeof SteamClient.Apps.GetMyAchievementsForApp!=='function')throw Error('Achievements are unavailable');
    const response=await SteamClient.Apps.GetMyAchievementsForApp('\(id)');
    if(response?.result!==1||!Array.isArray(response.data?.rgAchievements)||response.data.rgAchievements.length>5000)throw Error('Achievements are unavailable');
    const number=v=>typeof v==='number'&&Number.isFinite(v)?v:null;
    return response.data.rgAchievements.map(a=>{const hidden=!!a.bHidden&&!a.bAchieved;return {id:String(a.strID).slice(0,256),name:hidden?'Hidden achievement':String(a.strName||a.strID).slice(0,256),description:hidden?'Keep playing to discover this achievement.':String(a.strDescription||'').slice(0,2000),achieved:!!a.bAchieved,hidden:!!a.bHidden,unlockedAt:!!a.bAchieved?number(a.rtUnlocked):null,currentProgress:hidden?null:number(a.flCurrentProgress),globalPercent:hidden?null:number(a.flAchieved)};});
    """ }
}

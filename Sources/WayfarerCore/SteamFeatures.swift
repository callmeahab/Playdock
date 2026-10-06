import Foundation

public struct SteamFriend: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let state: Int
    public let game: String
    public let unread: Int
    public var presence: String { !game.isEmpty ? "Playing \(game)" : [0:"Offline", 1:"Online", 2:"Busy", 3:"Away", 4:"Snooze", 5:"Looking to trade", 6:"Looking to play"][state] ?? "Online" }
    public var isOnline: Bool { state != 0 }
}
public struct SteamFriendsSnapshot: Codable, Sendable {
    public let ready: Bool
    public let friends: [SteamFriend]
    public var unread: Int { friends.reduce(0) { $0 + $1.unread } }
}
public struct SteamCloudStatus: Codable, Sendable {
    public let appEnabled: Bool
    public let accountEnabled: Bool
    public let state: Int?
    public let progress: Int?
    public var syncTitle: String { [0:"Status unavailable",1:"Disabled",2:"Status unavailable",3:"Up to date",4:"Checking",5:"Out of sync",6:"Uploading",7:"Downloading",8:"Sync failed",9:"Conflict",10:"Pending on another device"][state ?? -1] ?? "Status unavailable" }
    public var title: String { !accountEnabled ? "Disabled for this Steam account" : !appEnabled ? "Disabled or unsupported for this game" : "Steam Cloud enabled" }
}
public struct SteamDownloadSettings: Codable, Sendable {
    public let bandwidthKBps: Int
    public let scheduled: Bool
    public let startHour: Int
    public let endHour: Int
}

enum SteamFeatureScripts {
    static let capabilities = "return {friendsEngine:!!window.g_FriendsUIApp?.FriendStore,friends:!!window.g_FriendsUIApp?.FriendStore?.friends_list_ready,settings:typeof window.settingsStore?.GetClientSetting==='function',details:typeof window.SteamClient?.Apps?.RegisterForAppDetails==='function' };"
    static let friends = """
    const app=window.g_FriendsUIApp, store=app?.FriendStore;
    if(!store?.friends_list_ready)return {ready:false,friends:[]};
    const ids=Array.from(store.all_friends_accountids||[]); if(ids.length>10000)throw Error('Friends list is unavailable');
    return {ready:true,friends:ids.map(id=>{const friend=store.GetFriend(id),persona=friend?.persona,chat=app.ChatStore?.GetFriendChat(id,false);if(!friend||!persona)return null; return {id:String(friend.steamid64),name:String(persona.m_strPlayerName||'Friend').slice(0,128),state:Number(persona.m_ePersonaState)||0,game:String(friend.current_game_name||'').slice(0,256),unread:Math.min(9999,Math.max(0,Number(chat?.unread_message_count)||0))};}).filter(x=>x&&/^7656119[0-9]{10}$/.test(x.id))};
    """
    static let downloadSettings = """
    const s=window.settingsStore?.clientSettings;
    if(!s||!Number.isInteger(s.download_throttle_rate)||!Number.isInteger(s.restrict_auto_updates_start)||!Number.isInteger(s.restrict_auto_updates_end))throw Error('Download settings are unavailable');
    return {bandwidthKBps:s.download_throttle_rate,scheduled:!!s.restrict_auto_updates,startHour:s.restrict_auto_updates_start,endHour:s.restrict_auto_updates_end};
    """
    static func settings(_ policy: DownloadPolicy) -> String {
        """
        const store=window.settingsStore;if(typeof store?.GetClientSetting!=='function')throw Error('Download settings are unavailable');
        const values={download_throttle_rate:\(policy.bandwidthKBps),restrict_auto_updates_start:\(policy.startHour),restrict_auto_updates_end:\(policy.endHour),restrict_auto_updates:\(policy.enabled)};
        for(const [key,value] of Object.entries(values)){const current=store.GetClientSetting(key);if(!Array.isArray(current)||typeof current[1]!=='function')throw Error('Download settings are unavailable');await current[1](value);}
        for(let i=0;i<30;i++){if(Object.entries(values).every(([k,v])=>store.clientSettings[k]===v))return {ok:true};await new Promise(r=>setTimeout(r,100));}throw Error('Steam did not confirm download settings');
        """
    }
    static func cloud(_ id: UInt32) -> String {
        """
        const apps=window.SteamClient?.Apps;if(typeof apps?.RegisterForAppDetails!=='function')throw Error('Cloud status is unavailable');
        let registration,timer;
        try {
            const d=await new Promise((resolve,reject)=>{
                timer=setTimeout(()=>reject(Error('Cloud status is unavailable')),5000);
                registration=apps.RegisterForAppDetails(\(id),value=>{if(value?.unAppID===\(id)&&typeof value.bCloudEnabledForApp==='boolean'&&typeof value.bCloudEnabledForAccount==='boolean')resolve(value);});
            });
            return {appEnabled:d.bCloudEnabledForApp,accountEnabled:d.bCloudEnabledForAccount,state:Number.isInteger(d.eCloudStatus)?d.eCloudStatus:null,progress:Number.isInteger(d.nCloudProgressPercent)?d.nCloudProgressPercent:null};
        } finally {clearTimeout(timer);registration?.unregister();}
        """
    }
}

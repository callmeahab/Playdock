import XCTest
@testable import PlaydockCore

final class SteamFriendsTests: XCTestCase {
    private func snapshot(_ fixture: String) throws -> SteamFriendsSnapshot {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("Node required for Steam fixtures") }
        let script = String(decoding: try JSONEncoder().encode(SteamControl.script(.friends)), as: UTF8.self)
        let source = """
        globalThis.window=globalThis;
        globalThis.App={BHasCurrentUser:()=>true,BIsOfflineMode:()=>false};
        globalThis.SteamClient={Installs:{}};
        let requested=false;
        const players=new Map([
          [1,{steamid64:'76561198000000001',display_name:'Nickname',current_game_name:'Game',persona:{m_strPlayerName:'Name',m_bNameInitialized:true,m_bStatusInitialized:true,m_ePersonaState:1,is_online:true,m_strAvatarHash:'0123456789abcdef0123456789abcdef01234567'}}],
          [2,{steamid64:'76561198000000002',persona:{m_strPlayerName:'Not loaded',m_bNameInitialized:false,m_bStatusInitialized:false}}]
        ]);
        for(const player of players.values())player.BHaveReceivedPersonaUpdateSince=()=>true;
        globalThis.g_FriendsUIApp={CMInterface:{BIsConnected:()=>true},FriendStore:{friends_list_ready:false,m_bInitialPersonaStatesLoaded:false,m_tsLastConnect:1,all_friends_accountids:[1,2],GetFriend:id=>players.get(id),EnsureFriendsListLoaded:delay=>{if(delay!==false)throw Error('deferred loading');requested=true;}}};
        \(fixture)
        eval(\(script)).then(value=>{if(!requested&&!g_FriendsUIApp.FriendStore.friends_list_ready&&!App.BIsOfflineMode())throw Error('hidden loading not requested');process.stdout.write(value)}).catch(()=>process.exitCode=1);
        """
        let task = Process(); task.executableURL = URL(fileURLWithPath: node); task.arguments = ["-e", source]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        return try JSONDecoder().decode(SteamFriendsSnapshot.self, from: data)
    }
    func testHiddenBackendLoadsImmediatelyAndKeepsExpectedCountUntilPersonasArrive() throws {
        let partial = try snapshot("")
        XCTAssertFalse(partial.ready); XCTAssertEqual(partial.total, 2); XCTAssertEqual(partial.friends.count, 1)
        XCTAssertNil(partial.friends[0].state); XCTAssertEqual(partial.friends[0].presence, "Presence unavailable")
        XCTAssertEqual(partial.friends[0].name, "Nickname")
        XCTAssertNotNil(partial.friends[0].avatarURL)
    }
    func testMissingPresenceIsNeverReportedAsOfflineAndInvisibleIsNotOnline() throws {
        let partial = try snapshot("g_FriendsUIApp.FriendStore.friends_list_ready=true;players.get(2).persona.m_bNameInitialized=true;")
        XCTAssertEqual(partial.friends.count, 2); XCTAssertNil(partial.friends[1].state); XCTAssertFalse(partial.ready)
        let complete = try snapshot("""
        g_FriendsUIApp.FriendStore.friends_list_ready=true;g_FriendsUIApp.FriendStore.m_bInitialPersonaStatesLoaded=true;
        Object.assign(players.get(2).persona,{m_bNameInitialized:true,m_bStatusInitialized:true,m_ePersonaState:7,is_online:false});
        """)
        XCTAssertTrue(complete.ready); XCTAssertEqual(complete.friends[0].presence, "Playing Game")
        XCTAssertFalse(complete.friends[1].isOnline); XCTAssertEqual(complete.friends[1].presence, "Offline")
    }
    func testOfflineSnapshotDoesNotPresentCachedPresenceAsLive() throws {
        let offline = try snapshot("App.BIsOfflineMode=()=>true;g_FriendsUIApp.FriendStore.friends_list_ready=true;")
        XCTAssertEqual(offline.connection, .offline); XCTAssertFalse(offline.ready)
        XCTAssertNil(offline.friends[0].state); XCTAssertEqual(offline.friends[0].game, "")
    }
    func testReconnectDoesNotDisplayPersonaStateFromThePreviousConnection() throws {
        let stale = try snapshot("g_FriendsUIApp.FriendStore.friends_list_ready=true;players.get(1).BHaveReceivedPersonaUpdateSince=()=>false;")
        XCTAssertNil(stale.friends[0].state); XCTAssertEqual(stale.friends[0].game, "")
        XCTAssertFalse(stale.ready)
    }
    func testAvatarURLsAreRestrictedToSteamImages() {
        XCTAssertNotNil(SteamFriend.avatarURL("https://avatars.steamstatic.com/0123456789abcdef0123456789abcdef01234567_medium.jpg"))
        for value in ["file:///Users/private.jpg", "https://localhost/image.jpg", "http://avatars.steamstatic.com/image.jpg", "https://avatars.steamstatic.com/image.jpg?token=private"] {
            XCTAssertNil(SteamFriend.avatarURL(value))
        }
    }
}

import XCTest
@testable import PlaydockCore

final class FeatureTests:XCTestCase {
    func testProfileAndCollectionSurviveSettingsRoundTrip() throws {
        var configuration=LauncherConfiguration(),prefs=GamePreferences()
        prefs.environmentID="original-bottle"; prefs.launchOptions=#"-novid -name "Player One""#; prefs.hidden=true; prefs.tags=["Strategy"]
        let folder=GameCollection(name:"Evenings"),child=GameCollection(name:"Strategy",parentID:folder.id,rule:.tag)
        prefs.collectionIDs=[folder.id]; configuration.gamePreferences=["steam:10":prefs]; configuration.collections=[folder,child]
        let restored=try JSONDecoder().decode(LauncherConfiguration.self,from:JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.gamePreferences["steam:10"],prefs); XCTAssertEqual(restored.collections,[folder,child]); XCTAssertEqual(try prefs.arguments(),["-novid","-name","Player One"])
    }
    func testMalformedLaunchOptionsAreRejected() {
        var prefs=GamePreferences(); prefs.launchOptions="-name \"unterminated"; XCTAssertThrowsError(try prefs.arguments())
        prefs.launchOptions="bad\0option"; XCTAssertThrowsError(try prefs.arguments())
    }
    func testSmartCollectionMembershipAndParentCycle() throws {
        let game=LibraryGame(id:"steam:10",installations:[.macSteam(SteamGame(appID:"10",name:"Test",library:URL(fileURLWithPath:"/tmp"),artwork:nil,lastPlayed:100))])
        var prefs=GamePreferences(); prefs.tags=["Strategy"]
        var tagged=GameCollection(name:"Strategy",rule:.tag); tagged.tag="strategy"
        XCTAssertTrue(tagged.matches(game,preferences:prefs,favorites:[]))
        XCTAssertTrue(GameCollection(name:"Mac",rule:.mac).matches(game,preferences:prefs,favorites:[]))
        XCTAssertFalse(GameCollection(name:"Windows",rule:.windows).matches(game,preferences:prefs,favorites:[]))
        var parent=GameCollection(name:"Parent"),child=GameCollection(name:"Child",parentID:parent.id)
        parent.parentID=child.id
        XCTAssertThrowsError(try GameCollection.validate(parent,in:[parent,child]))
        child.parentID=nil; XCTAssertNoThrow(try GameCollection.validate(child,in:[parent,child]))
    }
    func testOvernightAndDaytimeDownloadBoundaries() throws {
        let calendar=Calendar(identifier:.gregorian)
        func date(_ hour:Int) -> Date { calendar.date(from:DateComponents(year:2026,month:10,day:5,hour:hour))! }
        var policy=DownloadPolicy(); policy.enabled=true; policy.startHour=22; policy.endHour=7
        XCTAssertTrue(policy.allows(date(22),calendar:calendar)); XCTAssertTrue(policy.allows(date(0),calendar:calendar)); XCTAssertTrue(policy.allows(date(6),calendar:calendar))
        XCTAssertFalse(policy.allows(date(7),calendar:calendar)); XCTAssertFalse(policy.allows(date(21),calendar:calendar))
        policy.startHour=9; policy.endHour=17
        XCTAssertTrue(policy.allows(date(9),calendar:calendar)); XCTAssertFalse(policy.allows(date(17),calendar:calendar))
        policy.enabled=false; XCTAssertTrue(policy.allows(date(0),calendar:calendar))
    }
    func testScheduleValidationAndQueuePreserveUnprioritizedGames() {
        var policy=DownloadPolicy(); policy.enabled=true; policy.endHour=policy.startHour; XCTAssertThrowsError(try policy.validate())
        policy.enabled=false; policy.bandwidthKBps = -1; XCTAssertThrowsError(try policy.validate())
        policy.bandwidthKBps=0; policy.priorityAppIDs=["30","30","99","10"]
        XCTAssertEqual(policy.ordered(["10","20","30"]),["30","10","20"])
    }
    func testReportExcludesSecretsPathsAndLogArguments() {
        let secret="password=do-not-share access_token=abc123 person@example.com https://host/path?sessionid=secret 76561198000000001 /Users/alice/private 192.168.1.10"
        let entry=LaunchDiagnostic(gameID:"steam:1",name:"Game",platform:.windows,environment:"CrossOver",outcome:secret)
        let report=DiagnosticReport.make(version:"0.1",os:"macOS",architecture:"arm64",runtimes:["CrossOver"],connections:["Windows":"Online"],history:[entry])
        for value in ["do-not-share","abc123","person@example.com","sessionid=secret","76561198000000001","alice","192.168.1.10"] { XCTAssertFalse(report.contains(value),value) }
        XCTAssertTrue(report.contains("CrossOver")); XCTAssertTrue(report.contains("[redacted]"))
    }
    func testCloudNeverGuessesUnknownSyncState() throws {
        let status=try JSONDecoder().decode(SteamCloudStatus.self,from:Data(#"{"appEnabled":true,"accountEnabled":true,"state":999,"progress":null}"#.utf8))
        XCTAssertEqual(status.syncTitle,"Status unavailable")
        let synced=try JSONDecoder().decode(SteamCloudStatus.self,from:Data(#"{"appEnabled":true,"accountEnabled":true,"state":3,"progress":0}"#.utf8))
        XCTAssertEqual(synced.syncTitle,"Up to date")
    }
    func testSaveBackupRestorePreservesRecoveryAndNewFiles() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let saves=root.appendingPathComponent("game-saves"); try FileManager.default.createDirectory(at:saves,withIntermediateDirectories:true)
        let file=saves.appendingPathComponent("slot.sav"); try Data("before".utf8).write(to:file)
        let store=SaveBackupStore(root:root.appendingPathComponent("snapshots")); let original=try store.create(gameID:"steam:10:mac",name:"Original",folders:[saves])
        XCTAssertEqual(original.files.map(\.path),["slot.sav"])
        try Data("after".utf8).write(to:file); try Data("new".utf8).write(to:saves.appendingPathComponent("new.sav"))
        let recovery=try store.restore(original)
        XCTAssertEqual(try String(contentsOf:file),"before"); XCTAssertEqual(try String(contentsOf:saves.appendingPathComponent("new.sav")),"new")
        XCTAssertEqual(try store.list(gameID:"steam:10:mac").count,2)
        try store.restore(recovery); XCTAssertEqual(try String(contentsOf:file),"after")
    }
    func testDamagedSnapshotLeavesCurrentSaveUnchanged() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let saves=root.appendingPathComponent("saves"); try FileManager.default.createDirectory(at:saves,withIntermediateDirectories:true)
        let file=saves.appendingPathComponent("slot.sav"); try Data("before".utf8).write(to:file)
        let store=SaveBackupStore(root:root.appendingPathComponent("snapshots")),backup=try store.create(gameID:"game",name:"Test",folders:[saves])
        try Data("current".utf8).write(to:file)
        let all=FileManager.default.enumerator(at:store.root,includingPropertiesForKeys:nil)!
        let saved=all.compactMap{$0 as? URL}.first{$0.lastPathComponent=="slot.sav"}!
        try Data("corrupt".utf8).write(to:saved)
        XCTAssertThrowsError(try store.restore(backup)); XCTAssertEqual(try String(contentsOf:file),"current")
    }
    func testSaveSymlinksAndSnapshotRecursionAreRejected() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let saves=root.appendingPathComponent("saves"); try FileManager.default.createDirectory(at:saves,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:saves.appendingPathComponent("escape"),withDestinationURL:root)
        XCTAssertThrowsError(try SaveBackupStore(root:root.appendingPathComponent("backups")).create(gameID:"game",name:"Test",folders:[saves]))
        XCTAssertThrowsError(try SaveBackupStore(root:saves.appendingPathComponent("backups")).create(gameID:"game",name:"Test",folders:[saves]))
    }
}

import XCTest
@testable import WayfarerCore

final class SteamCatalogCacheTests: XCTestCase {
    func testAccountPlatformAndEnvironmentRemainIsolatedAcrossRestart() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let cache=SteamCatalogCache(directory:directory), root=directory.appendingPathComponent("Steam"), account="76561198000000001"
        let game=SteamCatalogGame(appID:"10",name:"Saved game",client:.windows,profileID:"bottle-a")
        let date=Date(timeIntervalSince1970:1_700_000_000)
        try cache.save(games:[game],account:account,root:root,client:.windows,profileID:"bottle-a",updatedAt:date)
        let reopened=SteamCatalogCache(directory:directory)
        let record=try XCTUnwrap(reopened.load(account:account,root:root,client:.windows,profileID:"bottle-a"))
        XCTAssertEqual(record.games,[game]); XCTAssertEqual(record.updatedAt,date)
        XCTAssertNil(try reopened.load(account:"76561198000000002",root:root,client:.windows,profileID:"bottle-a"))
        XCTAssertNil(try reopened.load(account:account,root:root,client:.macOS,profileID:nil))
        XCTAssertNil(try reopened.load(account:account,root:root,client:.windows,profileID:"bottle-b"))
        XCTAssertNil(try reopened.load(account:account,root:directory.appendingPathComponent("OtherSteam"),client:.windows,profileID:"bottle-a"))
    }
    func testFreshEmptyLibraryRemovesStaleGamesAndRejectedWriteKeepsLastGoodCache() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let cache=SteamCatalogCache(directory:directory),account="76561198000000001"
        let game=SteamCatalogGame(appID:"10",name:"Licensed game",client:.macOS)
        try cache.save(games:[game],account:account,root:directory,client:.macOS,profileID:nil)
        XCTAssertThrowsError(try cache.save(games:[SteamCatalogGame(appID:"invalid",name:"Invalid",client:.macOS)],account:account,root:directory,client:.macOS,profileID:nil))
        XCTAssertEqual(try cache.load(account:account,root:directory,client:.macOS,profileID:nil)?.games,[game])
        try cache.save(games:[],account:account,root:directory,client:.macOS,profileID:nil)
        XCTAssertEqual(try cache.load(account:account,root:directory,client:.macOS,profileID:nil)?.games,[])
    }
    func testOfflineOnlyBlocksUninstalledVersionAndKeepsInstalledOtherPlatform() throws {
        let root=URL(fileURLWithPath:"/Steam")
        let installed=SteamGame(appID:"10",name:"Installed",library:root,lastPlayed:0)
        let windows=SteamCatalogGame(appID:"10",name:"Installed",client:.windows,profileID:"bottle")
        let mac=SteamCatalogGame(appID:"10",name:"Installed",client:.macOS)
        let game=try XCTUnwrap(GameLibrary.merge(mac:[],windows:[installed],profileID:"bottle",added:[],catalog:[windows,mac]).first)
        XCTAssertFalse(game.unavailableOffline(for:.windows))
        XCTAssertTrue(game.unavailableOffline(for:.macOS))
        XCTAssertEqual(game.preferredInstallation?.platform,.windows)
    }
    func testAdapterSurvivesARebuiltSourceWithoutChangingMappedVersion() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("adapter.dylib"),cache=root.appendingPathComponent("cache")
        try Data("first build".utf8).write(to:source)
        let first=try NativeRuntime.prepareAdapter(source:source,cache:cache)
        try Data("second build".utf8).write(to:source)
        let second=try NativeRuntime.prepareAdapter(source:source,cache:cache)
        XCTAssertNotEqual(first,second)
        XCTAssertEqual(try Data(contentsOf:first),Data("first build".utf8))
        XCTAssertEqual(try Data(contentsOf:second),Data("second build".utf8))
        XCTAssertEqual(try NativeRuntime.prepareAdapter(source:source,cache:cache),second)
    }
    func testWineRejectsAppleSiliconOnlyAdapterBeforeLaunchingSteam() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1]).write(to:file)
        XCTAssertFalse(try NativeRuntime.supportsIntelAdapter(file))
        let runtime=RuntimeInstallation(kind:.wine,executable:URL(fileURLWithPath:"/wine"))
        XCTAssertThrowsError(try NativeRuntime.attachSteamBackend(LaunchCommand(executable:runtime.executable,arguments:[]),runtime:runtime,loader:runtime.executable,adapter:file,directory:file.deletingLastPathComponent()))
    }
}

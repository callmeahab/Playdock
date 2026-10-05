import XCTest
@testable import WayfarerCore

final class SteamCatalogTests: XCTestCase {
    private func license(_ ids: [UInt32], state: String = "Active", packageID: UInt32 = 10) -> String {
        "License packageID \(packageID):\n - State   :\n\(state)\n (flags 0x200)\n - Purchased : ignored\n - Apps :\n" + ids.map { "\($0),\n" }.joined() + " (\(ids.count) in total)\n - Depots :\n99,\n (1 in total)\n"
    }
    func testAccountMetadataKeysAreCaseInsensitive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data(#"""
        "Users" { "76561198000000000" { "mostrecent" "1" "AccountName" "ignored" } }
        """#.utf8).write(to: root.appendingPathComponent("config/loginusers.vdf"))
        XCTAssertEqual(SteamCatalog.recentAccount(root:root),"76561198000000000")
    }

    func testModernAccountMetadataWithoutMostRecent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("config/loginusers.vdf")
        try Data(#"""
        "users" { "76561198000000000" { "Timestamp" "100" } }
        """#.utf8).write(to:file)
        XCTAssertEqual(SteamCatalog.recentAccount(root:root),"76561198000000000")
        try Data(#"""
        "users" { "76561198000000000" { "Timestamp" "100" } "76561198000000001" { "Timestamp" "200" } }
        """#.utf8).write(to:file)
        XCTAssertEqual(SteamCatalog.recentAccount(root:root),"76561198000000001")
        try Data(#"""
        "users" { "76561198000000000" { "Timestamp" "100" } "76561198000000001" { "Timestamp" "100" } }
        """#.utf8).write(to:file)
        XCTAssertNil(SteamCatalog.recentAccount(root:root))
    }

    func testFreshResponseBoundsAndCompleteActiveLicenses() throws {
        let nonce = UUID(), other = UUID()
        let log = "[2026-10-05 11:00:00] ExecCommandLine: -wayfarer-library-request=\(nonce.uuidString) +licenses_print\n" + license([10, 20]) + license([30], state: "Expired", packageID: 20) + "No active license found for appID \(SteamCatalog.boundaryAppID(nonce)).\n" + license([40])
        let response = try XCTUnwrap(SteamCatalog.response(log, nonce: nonce))
        XCTAssertEqual(try SteamCatalog.activePackageIDs(response), [10])
        XCTAssertNil(SteamCatalog.response(log, nonce: other))
        XCTAssertNil(SteamCatalog.response(log.components(separatedBy: "No active license found for appID")[0], nonce: nonce))
        XCTAssertEqual(try SteamCatalog.activePackageIDs(license([10,20]).replacingOccurrences(of: " (2 in total)", with: " (196 in total)")), [10])
        XCTAssertThrowsError(try SteamCatalog.activePackageIDs(license([10])+license([20])))
    }
    private func cache(version: UInt32) -> Data {
        var data = Data(), body = Data()
        func number<T: FixedWidthInteger>(_ value: T, to target: inout Data) { var le = value.littleEndian; withUnsafeBytes(of: &le) { target.append(contentsOf: $0) } }
        let keys = ["appinfo", "common", "name", "type", "oslist"]
        func key(_ tag: UInt8, _ index: Int) {
            body.append(tag)
            if version == 41 { number(UInt32(index), to: &body) } else { body.append(contentsOf: keys[index].utf8); body.append(0) }
        }
        key(0,0); key(0,1)
        for (index,value) in [(2,"Game A"),(3,"Game"),(4,"windows,macos")] { key(1,index); body.append(contentsOf: value.utf8); body.append(0) }
        body.append(contentsOf: [8,8,8])
        number(UInt32(0x07564400) | version, to: &data); number(UInt32(1), to: &data)
        let offsetPosition = data.count
        if version == 41 { number(UInt64(0), to: &data) }
        number(UInt32(10), to: &data); number(UInt32((version >= 40 ? 60 : 40)+body.count), to: &data)
        data.append(Data(repeating: 0, count: version >= 40 ? 60 : 40)); data.append(body); number(UInt32(0), to: &data)
        if version == 41 {
            var offset = UInt64(data.count).littleEndian
            withUnsafeBytes(of: &offset) { data.replaceSubrange(offsetPosition..<(offsetPosition+8), with: $0) }
            number(UInt32(keys.count), to: &data)
            for key in keys { data.append(contentsOf: key.utf8); data.append(0) }
        }
        return data
    }
    func testAppInfoVersionsBoundsAndOwnershipSeparation() throws {
        for version: UInt32 in [39,40,41] {
            let data = cache(version: version)
            XCTAssertEqual(try SteamAppInfo.read(data, appIDs: [10])[10]?.name, "Game A")
            XCTAssertTrue(try SteamAppInfo.read(data, appIDs: [11]).isEmpty)
            XCTAssertThrowsError(try SteamAppInfo.read(data.prefix(20), appIDs: [10]))
        }
        var corrupted = cache(version: 41); corrupted[8] = 255; corrupted[9] = 255
        XCTAssertThrowsError(try SteamAppInfo.read(corrupted, appIDs: [10]))
    }
    func testUninstalledVersionsMergeWithoutLosingPlatformOrPrefixBinding() throws {
        let windows = SteamCatalogGame(appID: "10", name: "Game A", client: .windows, profileID: "owned")
        let mac = SteamCatalogGame(appID: "10", name: "Game A", client: .macOS)
        let wrong = SteamCatalogGame(appID: "20", name: "Other prefix", client: .windows, profileID: "external")
        let games = GameLibrary.merge(mac: [], windows: [], profileID: "owned", added: [], catalog: [windows,mac,wrong])
        XCTAssertEqual(games.count,1)
        let game = try XCTUnwrap(games.first)
        XCTAssertFalse(game.isInstalled); XCTAssertEqual(game.name,"Game A")
        XCTAssertEqual(game.preferredPlatform,.macOS); XCTAssertEqual(game.platforms,[.macOS,.windows])
        XCTAssertNil(game.installation(for: .windows)); XCTAssertEqual(game.offer(for: .windows)?.profileID,"owned")
        XCTAssertEqual(try NativeGameLaunch.steamInstallURL(appID: "10").absoluteString,"steam://install/10")
        XCTAssertThrowsError(try NativeGameLaunch.steamInstallURL(appID: "10/other"))
    }
    private func packageCache(version: UInt32 = 40) -> Data {
        var data = Data()
        func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func key(_ tag: UInt8, _ value: String) { data.append(tag); data.append(contentsOf: value.utf8); data.append(0) }
        number(UInt32(0x06565500) | version); number(UInt32(1)); number(UInt32(10))
        data.append(Data(repeating: 0,count:version == 40 ? 32 : 24)); key(0,"10"); key(0,"appids"); key(2,"0"); number(UInt32(10)); data.append(8)
        key(0,"depotids"); key(2,"0"); number(UInt32(99)); data.append(contentsOf:[8,8,8]); number(UInt32.max)
        return data
    }

    func testSnapshotUsesOnlyLicensedGamesAndClientOS() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("appcache"), withIntermediateDirectories: true)
        try cache(version:41).write(to:root.appendingPathComponent("appcache/appinfo.vdf"))
        try packageCache().write(to:root.appendingPathComponent("appcache/packageinfo.vdf"))
        for version: UInt32 in [39,40] { XCTAssertEqual(try SteamAppInfo.packageApps(packageCache(version: version), packageIDs:[10])[10], [10]) }
        XCTAssertEqual(Array(packageCache().prefix(4)),[0x28,0x55,0x56,0x06])
        XCTAssertThrowsError(try SteamAppInfo.packageApps(packageCache().prefix(20), packageIDs:[10]))
        XCTAssertTrue(try SteamAppInfo.packageApps(packageCache(), packageIDs:[99]).isEmpty)
        let snapshot = try SteamCatalog.snapshot(response:license([10]),root:root,client:.windows,profileID:"owned")
        XCTAssertEqual(snapshot.games.map(\.appID),["10"])
        XCTAssertEqual(snapshot.games.first?.profileID,"owned")
        XCTAssertTrue(try SteamCatalog.snapshot(response:license([11],packageID:11),root:root,client:.windows).games.isEmpty)
        XCTAssertTrue(try SteamCatalog.snapshot(response:license([10],state:"Expired"),root:root,client:.windows).games.isEmpty)
        XCTAssertEqual(try SteamCatalog.snapshot(ownedAppIDs:["10"],root:root,client:.macOS).games.map(\.appID),["10"])
        XCTAssertTrue(try SteamCatalog.snapshot(ownedAppIDs:[],root:root,client:.macOS).games.isEmpty)
        XCTAssertThrowsError(try SteamCatalog.snapshot(ownedAppIDs:["10;quit"],root:root,client:.windows))
    }
}

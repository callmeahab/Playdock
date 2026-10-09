import XCTest
@testable import PlaydockCore

final class SteamBridgeTests: XCTestCase {
    func testSteamWindowsLibraryIsIndependentOfNonSteamEnvironmentSelection() {
        let game = SteamGame(appID: "100", name: "Windows game", library: URL(fileURLWithPath: "/Steam"), artwork: nil, lastPlayed: 0)
        let offer = SteamCatalogGame(appID: "200", name: "Available game", client: .windows, profileID: RuntimeProfile.steamBridgeID, artwork: nil, heroArtwork: nil)
        for profile in [nil, "bottle-a", "bottle-b"] as [String?] {
            let library = GameLibrary.merge(mac: [], windows: [game], profileID: profile, added: [], catalog: [offer])
            XCTAssertEqual(library.count, 2)
            XCTAssertEqual(library.first { $0.id == "steam:100" }?.installation(for: .windows), .macSteamWindows(game))
            XCTAssertNotNil(library.first { $0.id == "steam:200" }?.offer(for: .windows))
        }
    }
    func testBridgeIdentityIsIndependentOfTheSelectedBottle() {
        var profile = RuntimeProfile(runtime: RuntimeInstallation(kind: .crossOver, executable: URL(fileURLWithPath: "/runner/bin/wine")), prefix: URL(fileURLWithPath: "/compatdata"), name: "Bridge")
        let original = profile.id
        profile.nativeSteamBridge = true
        XCTAssertEqual(profile.id, RuntimeProfile.steamBridgeID)
        XCTAssertNotEqual(profile.id, original)
    }
    func testPerGamePrefixesFollowTheirSteamLibraryAndRejectInvalidIdentifiers() {
        let external = URL(fileURLWithPath: "/Volumes/Games/SteamLibrary")
        let game = SteamGame(appID: "100", name: "Game", library: external, artwork: nil, lastPlayed: 0)
        XCTAssertEqual(game.bridgePrefix?.path, "/Volumes/Games/SteamLibrary/steamapps/compatdata/100/pfx")
        var invalid = game; invalid.appID = "../escape"
        XCTAssertNil(invalid.bridgePrefix)
    }
    func testMissingAndEscapingResourcesAreRejectedBeforeInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SteamIntegrationSetupService.validateResources(root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("payload"), withDestinationURL: URL(fileURLWithPath: "/usr/bin"))
        XCTAssertThrowsError(try SteamIntegrationSetupService.validateResources(root))
    }
    func testExplicitUnsupportedCrossOverDoesNotFallBackToAnotherInstalledBuild() {
        var environment = SteamIntegrationEnvironment()
        environment.steamPresent = true; environment.steamSupported = true
        let unsupported = SteamIntegrationCrossOver(path: "/CrossOver.app", name: "CrossOver", version: "26.3", supported: false, licensed: true,
            supportDetail: "No patch table", licenseDetail: "Activated")
        let supported = SteamIntegrationCrossOver(path: "/Preview.app", name: "CrossOver Preview", version: "20261006", supported: true, licensed: true,
            supportDetail: "Supported", licenseDetail: "Activated")
        environment.crossOver = [unsupported, supported]
        XCTAssertTrue(environment.canSetUp(crossOver: nil))
        XCTAssertFalse(environment.canSetUp(crossOver: unsupported.path))
        XCTAssertFalse(environment.canSetUp(crossOver: "/Missing.app"))
        XCTAssertEqual(environment.selectedCrossOver(path: nil), supported)
    }
    func testDirectSteamLaunchLoadsBothBridgeAndPlaydockAdapter() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Steam.app")
        let contents = app.appendingPathComponent("Contents"), binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let adapter = URL(fileURLWithPath: "/Playdock/adapter.dylib"), bridge = binaries.appendingPathComponent("libPlaydockSteam.dylib")
        let plist = contents.appendingPathComponent("Info.plist")
        func configure(_ value: String) throws {
            let info = ["LSEnvironment": ["DYLD_INSERT_LIBRARIES": value]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        }
        try configure("")
        XCTAssertEqual(try SteamBridgeInjection.libraries(adapter: adapter, steamApp: app), adapter.path)
        XCTAssertEqual(try SteamBridgeInjection.libraries(adapter: nil, steamApp: app), "")
        try configure(bridge.path)
        XCTAssertThrowsError(try SteamBridgeInjection.libraries(adapter: adapter, steamApp: app))
        try Data("bridge fixture".utf8).write(to: bridge)
        XCTAssertEqual(try SteamBridgeInjection.libraries(adapter: adapter, steamApp: app), adapter.path + ":" + bridge.path)
        XCTAssertEqual(try SteamBridgeInjection.libraries(adapter: nil, steamApp: app), bridge.path)
        try configure(bridge.path + ":/foreign/library.dylib")
        XCTAssertThrowsError(try SteamBridgeInjection.libraries(adapter: adapter, steamApp: app))
        XCTAssertThrowsError(try SteamBridgeInjection.libraries(adapter: nil, steamApp: app))
    }

    func testMissingHelperReportsARecoverableError() async {
        let service = SteamIntegrationSetupService(helper: URL(fileURLWithPath: "/missing/PlaydockSteamIntegration"))
        do { _ = try await service.inspect(); XCTFail("Missing helper accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("helper is missing")) }
    }
}

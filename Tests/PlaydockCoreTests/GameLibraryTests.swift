import XCTest
@testable import PlaydockCore

final class GameLibraryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func write(_ relative: String, data: Data) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }
    private func write(_ relative: String, text: String) throws { try write(relative, data: Data(text.utf8)) }

    private func application(_ relative: String, header: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe]) throws -> URL {
        let plist: [String: Any] = ["CFBundleExecutable": "Game", "CFBundleIdentifier": "test.playdock.game", "CFBundlePackageType": "APPL"]
        try write(relative + "/Contents/Info.plist", data: PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        let executable = try write(relative + "/Contents/MacOS/Game", data: Data(header + [0, 0, 0, 0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return root.appendingPathComponent(relative)
    }

    func testDualInstallBecomesOneGameAndPrefersMacWithoutLosingWindowsChoice() {
        let mac = SteamGame(appID: "100", name: "Both platforms", library: root, artwork: nil, lastPlayed: 20)
        let windows = SteamGame(appID: "100", name: "Both platforms", library: root, artwork: root.appendingPathComponent("cover.jpg"), lastPlayed: 10)
        let catalog = GameLibrary.merge(mac: [mac], windows: [windows], profileID: "owned-prefix", added: [])
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[0].platforms, [.macOS, .windows])
        XCTAssertEqual(catalog[0].preferredInstallation, .macSteam(mac))
        XCTAssertEqual(catalog[0].installation(for: .windows), .macSteamWindows(windows))
        XCTAssertEqual(catalog[0].artwork, windows.artwork)
        XCTAssertEqual(catalog[0].lastPlayed, 20)
        XCTAssertEqual(GameLibrary.merge(mac: [], windows: [windows], profileID: "owned-prefix", added: [])[0].preferredInstallation?.platform, .windows)
    }

    func testShortcutsRemainVisibleWithoutSelectingTheirEnvironment() {
        let mac = AddedGame(name: "Mac game", executable: root.appendingPathComponent("Game.app"), profileID: "", platform: .macOS)
        let windows = AddedGame(name: "Windows game", executable: root.appendingPathComponent("game.exe"), profileID: "engine-a")
        XCTAssertEqual(GameLibrary.merge(mac: [], windows: [], profileID: nil, added: [mac, windows]).map(\.name), ["Mac game", "Windows game"])
        XCTAssertEqual(GameLibrary.merge(mac: [], windows: [], profileID: "engine-b", added: [mac, windows]).map(\.name), ["Mac game", "Windows game"])
        XCTAssertEqual(GameLibrary.merge(mac: [], windows: [], profileID: "engine-a", added: [mac, windows]).count, 2)
    }

    func testAvailableMacVersionIsDefaultEvenWhenOnlyWindowsIsInstalled() {
        let windows = SteamGame(appID:"100",name:"Both versions",library:root,artwork:nil,lastPlayed:10)
        let mac = SteamCatalogGame(appID:"100",name:"Both versions",client:.macOS,profileID:nil,artwork:nil,heroArtwork:nil)
        let library = GameLibrary.merge(mac:[],windows:[windows],profileID:"engine",added:[],catalog:[mac])
        XCTAssertEqual(library[0].preferredPlatform,.macOS)
        XCTAssertNil(library[0].installation(for:.macOS))
        XCTAssertNotNil(library[0].installation(for:.windows))
        XCTAssertNotNil(library[0].offer(for:.macOS))
        XCTAssertEqual(library[0].executionTarget()?.platform, .macOS)
        XCTAssertEqual(library[0].executionTarget()?.isInstalled, false)
        XCTAssertEqual(library[0].executionTarget(online: false)?.platform, .windows)
        XCTAssertEqual(library[0].executionTarget(online: false)?.installation, .macSteamWindows(windows))
    }

    func testAutomaticRoutingChoosesNativeOrCompatibilityWithoutAUserVersionChoice() {
        let mac = SteamCatalogGame(appID: "100", name: "Dual platform", client: .macOS, profileID: nil, artwork: nil, heroArtwork: nil)
        let windows = SteamCatalogGame(appID: "100", name: "Dual platform", client: .windows, profileID: RuntimeProfile.steamBridgeID, artwork: nil, heroArtwork: nil)
        let dual = LibraryGame(id: "steam:100", installations: [], availableVersions: [windows, mac])
        XCTAssertEqual(dual.executionTarget()?.offer, mac)
        XCTAssertEqual(dual.executionTarget(online: false)?.platform, .macOS)
        let windowsOnly = LibraryGame(id: "steam:100", installations: [], availableVersions: [windows])
        XCTAssertEqual(windowsOnly.executionTarget()?.offer, windows)
        XCTAssertFalse(windowsOnly.executionTarget()!.isInstalled)
        let installed = SteamGame(appID: "100", name: "Native", library: root, artwork: nil, lastPlayed: 0)
        XCTAssertEqual(LibraryGame(id: "steam:100", installations: [.macSteam(installed), .macSteamWindows(installed)]).executionTarget(online: false)?.installation, .macSteam(installed))
    }

    func testNativeScanUsesMacPathsAndRejectsWindowsDepotsPartialDownloadsAndTraversal() throws {
        func manifest(_ id: String, _ name: String, _ directory: String, flags: Int = 4) -> String {
            "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"\(name)\" \"installdir\" \"\(directory)\" \"StateFlags\" \"\(flags)\" }"
        }
        let extra = root.appendingPathComponent("Other Library")
        try write("Steam/steamapps/libraryfolders.vdf", text: "\"libraryfolders\" { \"0\" { \"path\" \"\(root.appendingPathComponent("Steam").path)\" } \"1\" { \"path\" \"\(extra.path)\" } }")
        _ = try application("Steam/steamapps/common/MacGame/Game.app")
        _ = try application("Other Library/steamapps/common/Second/Game.app")
        _ = try application("Steam/steamapps/common/Fake/Game.app", header: [0x4d, 0x5a, 0, 0])
        try write("Steam/steamapps/appmanifest_100.acf", text: manifest("100", "Native Mac", "MacGame"))
        try write("Steam/steamapps/appmanifest_101.acf", text: manifest("101", "Windows depot", "Fake"))
        try write("Steam/steamapps/appmanifest_102.acf", text: manifest("102", "Downloading", "MacGame", flags: 2))
        try write("Steam/steamapps/appmanifest_103.acf", text: manifest("103", "Traversal", "../MacGame"))
        try write("Other Library/steamapps/appmanifest_200.acf", text: manifest("200", "Other Mac", "Second"))
        let scan = SteamLibrary.scanMac(root: root.appendingPathComponent("Steam"))
        XCTAssertEqual(scan.games.map(\.appID), ["100", "200"])
        XCTAssertEqual(scan.games[0].installDirectory, root.appendingPathComponent("Steam/steamapps/common/MacGame"))
        XCTAssertTrue(scan.warnings.isEmpty)
    }

    func testBridgeWindowsDepotUsesMacSteamAndDoesNotDuplicateMacGames() throws {
        _ = try application("Steam/steamapps/common/Mac/Game.app")
        try write("Steam/steamapps/common/Windows/game.exe", data: Data([0x4d, 0x5a, 0, 0]))
        for (id, directory) in [("100", "Mac"), ("200", "Windows")] {
            try write("Steam/steamapps/appmanifest_\(id).acf", text: "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"\(directory)\" \"installdir\" \"\(directory)\" \"StateFlags\" \"4\" }")
        }
        let steam = root.appendingPathComponent("Steam")
        let mac = SteamLibrary.scan(root: steam, client: .macOS)
        let windows = SteamLibrary.scan(root: steam, client: .windows)
        XCTAssertEqual(mac.games.map(\.appID), ["100"])
        XCTAssertEqual(windows.games.map(\.appID), ["200"])
        let library = GameLibrary.merge(mac: mac.games, windows: windows.games, profileID: RuntimeProfile.steamBridgeID, added: [])
        XCTAssertEqual(library.first { $0.id == "steam:200" }?.installation(for: .windows), .macSteamWindows(windows.games[0]))
        XCTAssertTrue(windows.transfers.isEmpty)
    }

    func testMacLaunchTargetsValidateBeforeCallingLaunchServices() throws {
        let app = try application("Native.app")
        XCTAssertNoThrow(try NativeGameLaunch.validateApplication(app))
        XCTAssertThrowsError(try NativeGameLaunch.validateApplication(root.appendingPathComponent("game.exe")))
        XCTAssertThrowsError(try NativeGameLaunch.validateApplication(root.appendingPathComponent("Missing.app")))
        XCTAssertEqual(try NativeGameLaunch.steamURL(appID: "100").absoluteString, "steam://rungameid/100")
        for id in ["0", "-1", "100/quit", "100?command=uninstall", "4294967296"] {
            XCTAssertThrowsError(try NativeGameLaunch.steamURL(appID: id))
        }
    }

    func testPresentationTracksFavoritesHiddenGamesHistoryAndPlatformCounts() {
        let games = [
            SteamGame(appID: "100", name: "Alpha", library: root, artwork: nil, lastPlayed: 100),
            SteamGame(appID: "200", name: "Beta", library: root, artwork: nil, lastPlayed: 10),
            SteamGame(appID: "300", name: "Gamma", library: root, artwork: nil, lastPlayed: 0)
        ]
        var input = GameLibraryInput(mac: games, windows: [games[0]], profileID: "engine", added: [], catalog: [], hidden: ["steam:200"], favorites: ["steam:300"], recent: [:])
        let first = GameLibraryPresentation.build(input)
        XCTAssertEqual(first.library.map(\.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(first.quick.map(\.name), ["Gamma", "Alpha"])
        XCTAssertEqual(first.platformCounts, [.macOS: 3, .windows: 0])
        XCTAssertEqual(first.favoriteCount, 1)
        input.hidden = []; input.favorites = []; input.recent = ["steam:200": Date(timeIntervalSince1970: 200)]
        let next = GameLibraryPresentation.build(input)
        XCTAssertEqual(next.quick.map(\.name), ["Beta", "Alpha", "Gamma"])
        XCTAssertEqual(next.visible.count, 3)
        XCTAssertEqual(first.visible.count, 2)
        XCTAssertNotEqual(first, next)
        input.profileID = nil
        XCTAssertEqual(GameLibraryPresentation.build(input).platformCounts[.windows], 0)
    }
}

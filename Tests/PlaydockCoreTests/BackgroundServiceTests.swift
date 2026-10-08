import XCTest
@testable import PlaydockCore

final class BackgroundServiceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockActors-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        if file.pathExtension == "acf", let state = try? VDFParser.parse(text)["AppState"], let directory = state["installdir"]?.string {
            let game = file.deletingLastPathComponent().appendingPathComponent("common/" + directory + "/game.exe")
            try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x4d, 0x5a, 0, 0]).write(to: game)
        }
    }
    private var cache: SteamInstallationCache { SteamInstallationCache(directory: root.appendingPathComponent("cache")) }
    private var game: SteamGame { SteamGame(appID: "100", name: "Saved game", library: root, artwork: nil, lastPlayed: 10) }
    private func service() -> SteamLibraryService {
        SteamLibraryService(client: .windows, catalogCache: SteamCatalogCache(directory: root.appendingPathComponent("catalog")), installationCache: cache)
    }
    private final class ScanThread: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: Bool?
        func record() { lock.lock(); defer { lock.unlock() }; onMain = (onMain ?? false) || Thread.isMainThread }
        var ranOnMain: Bool? { lock.lock(); defer { lock.unlock() }; return onMain }
    }

    @MainActor func testActorScanRunsAwayFromTheUIActorAndStreamFinishes() async throws {
        try write("steamapps/appmanifest_100.acf", "\"AppState\" { \"appid\" \"100\" \"name\" \"Game\" \"StateFlags\" \"4\" \"installdir\" \"Game\" }")
        let worker = service(), thread = ScanThread()
        let scan = await worker.scan(root: root) { _ in thread.record() }
        XCTAssertEqual(scan.games.map(\.appID), ["100"])
        XCTAssertEqual(thread.ranOnMain, false)
        var last: SteamLibraryScan?
        for await snapshot in worker.updates(root: root) { last = snapshot }
        XCTAssertEqual(last?.games, scan.games)
        XCTAssertEqual(last?.transfers, scan.transfers)
    }

    func testInstalledCacheSeparatesAccountRootClientAndEnvironment() throws {
        try cache.save(games: [game], account: "1000", root: root, client: .windows, profileID: "a")
        XCTAssertEqual(try cache.load(account: "1000", root: root, client: .windows, profileID: "a")?.games, [game])
        XCTAssertNil(try cache.load(account: "2000", root: root, client: .windows, profileID: "a"))
        XCTAssertNil(try cache.load(account: "1000", root: root, client: .windows, profileID: "b"))
        XCTAssertNil(try cache.load(account: "1000", root: root, client: .macOS, profileID: nil))
        XCTAssertNil(try cache.load(account: "1000", root: root.appendingPathComponent("other"), client: .windows, profileID: "a"))
        XCTAssertThrowsError(try cache.save(games: [game, game], account: "1000", root: root, client: .windows, profileID: "a"))
    }

    func testActorAccountSwitchDoesNotPublishPreviousInstalledCache() async throws {
        try write("config/loginusers.vdf", "\"users\" { \"1000\" { \"MostRecent\" \"1\" } }")
        let worker = service()
        try await worker.saveInstallations(SteamLibraryScan(games: [game], warnings: []), account: "1000", root: root, profileID: "a")
        let first = await worker.account(root: root, profileID: "a", includeInstalled: true)
        XCTAssertEqual(first.installed?.games, [game])
        try write("config/loginusers.vdf", "\"users\" { \"2000\" { \"MostRecent\" \"1\" } }")
        let next = await worker.account(root: root, profileID: "a", includeInstalled: true)
        XCTAssertEqual(next.account, "2000")
        XCTAssertNil(next.installed)
        try await worker.saveInstallations(SteamLibraryScan(games: [], warnings: []), account: "1000", root: root, profileID: "a")
        XCTAssertEqual(try cache.load(account: "1000", root: root, client: .windows, profileID: "a")?.games, [game])
    }

    func testRescanReplacesRemovedGamesAndBadCacheFallsBackToFreshScan() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let worker = service()
        try cache.save(games: [game], account: nil, root: root, client: .windows, profileID: "a")
        let scan = await worker.scanAndSave(root: root, profileID: "a")
        XCTAssertTrue(scan.games.isEmpty)
        XCTAssertEqual(try cache.load(account: nil, root: root, client: .windows, profileID: "a")?.games, [])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil).first)
        try Data("invalid".utf8).write(to: file)
        let account = await worker.account(root: root, profileID: "a", includeInstalled: true)
        XCTAssertNil(account.installed)
        let fresh = await worker.scanAndSave(root: root, profileID: "a")
        XCTAssertTrue(fresh.games.isEmpty)
        XCTAssertNotNil(try cache.load(account: nil, root: root, client: .windows, profileID: "a"))
    }

    func testSettingsActorRejectsLateOlderSave() async throws {
        let store = ConfigurationStore(file: root.appendingPathComponent("settings.json")), worker = ConfigurationService(store: ConfigurationStore(file: root.appendingPathComponent("settings.json")))
        var newest = LauncherConfiguration(); newest.favoriteGameIDs = ["steam:100"]
        try await worker.save(newest, revision: 2)
        try await worker.save(LauncherConfiguration(), revision: 1)
        XCTAssertEqual(try store.load().favoriteGameIDs, ["steam:100"])
    }

    func testIdenticalInstalledSnapshotDoesNotRewriteCache() throws {
        let first = Date(timeIntervalSince1970: 100)
        try cache.save(games: [game], account: nil, root: root, client: .windows, profileID: "a", updatedAt: first)
        try cache.save(games: [game], account: nil, root: root, client: .windows, profileID: "a", updatedAt: first.addingTimeInterval(10))
        XCTAssertEqual(try cache.load(account: nil, root: root, client: .windows, profileID: "a")?.updatedAt, first)
    }

    func testImmediateProcessExitCanBeObservedAfterUIRegistration() async throws {
        let worker = ProcessService(), id = UUID()
        let launch = try await worker.start(LaunchCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []), id: id, logsDirectory: root.appendingPathComponent("logs"))
        XCTAssertEqual(launch.id, id)
        try await Task.sleep(for: .milliseconds(100))
        let result = try await worker.wait(id)
        XCTAssertEqual(result, 0)
        do { _ = try await worker.wait(id); XCTFail("A launch should be consumed only once.") }
        catch { }
    }
}

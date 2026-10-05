import XCTest
@testable import WayfarerCore

final class SteamClientTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WayfarerSteamClient-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func write(_ path: String, _ text: String = "", executable: Bool = false) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        return file
    }

    func testPlayUsesSilentRealSteamInExactEnvironmentAndKeepsLoginAccessible() throws {
        let runtime = RuntimeInstallation(kind: .crossOver, executable: try write("engine/bin/wine", executable: true))
        let profile = RuntimeProfile(runtime: runtime, prefix: root.appendingPathComponent("Bottles/Wayfarer"), name: "Wayfarer")
        try write("Bottles/Wayfarer/cxbottle.conf")
        try write("Bottles/Wayfarer/drive_c/Steam/steam.exe")
        let play = try CommandBuilder.steam(profile: profile, appID: "123", bigPicture: true)
        XCTAssertEqual(Array(play.arguments.suffix(3)), ["-silent", "-applaunch", "123"])
        XCTAssertFalse(play.arguments.contains("-bigpicture"))
        XCTAssertEqual(play.environment["WINEPREFIX"], profile.prefix.path)
        XCTAssertEqual(play.environment["CX_BOTTLE_PATH"], profile.prefix.deletingLastPathComponent().path)
        let login = try CommandBuilder.steam(profile: profile, bigPicture: false)
        XCTAssertFalse(login.arguments.contains("-silent"))
        XCTAssertFalse(login.arguments.contains("-applaunch"))
        for id in ["0", "-1", "123 -shutdown", "123/quit", "4294967296"] {
            XCTAssertThrowsError(try CommandBuilder.steam(profile: profile, appID: id))
        }
    }

    private func manifest(_ id: String, flags: UInt, download: UInt64 = 0, downloaded: UInt64 = 0, stage: UInt64 = 0, staged: UInt64 = 0) -> String {
        "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"Game \(id)\" \"StateFlags\" \"\(flags)\" \"installdir\" \"Game\(id)\" \"BytesToDownload\" \"\(download)\" \"BytesDownloaded\" \"\(downloaded)\" \"BytesToStage\" \"\(stage)\" \"BytesStaged\" \"\(staged)\" }"
    }

    func testTransferScanDoesNotTurnPartialMacDownloadsIntoPlayableOrLicensedGames() throws {
        try write("Steam/steamapps/appmanifest_100.acf", manifest("100", flags: 2, download: 100, downloaded: 25))
        try write("Steam/steamapps/appmanifest_101.acf", manifest("101", flags: 4, download: 100, downloaded: 0))
        try write("Steam/steamapps/appmanifest_102.acf", manifest("102", flags: 1))
        try write("Steam/steamapps/appmanifest_0.acf", manifest("0", flags: 2))
        try write("Steam/steamapps/appmanifest_228980.acf", manifest("228980", flags: 2))
        let scan = SteamLibrary.scanMac(root: root.appendingPathComponent("Steam"))
        XCTAssertTrue(scan.games.isEmpty)
        XCTAssertEqual(scan.transfers.map(\.appID), ["100"])
        XCTAssertEqual(scan.transfers.first?.client, .macOS)
        XCTAssertEqual(scan.transfers.first?.progress, 0.25)
    }

    func testWindowsTransfersUseMappedLibrariesAndUpdateWithoutWritingSteamFiles() throws {
        let steam = try write("prefix/drive_c/Steam/steam.exe")
        let second = root.appendingPathComponent("Second Library")
        try write("prefix/drive_c/Steam/steamapps/libraryfolders.vdf", "\"libraryfolders\" { \"0\" { \"path\" \"C:\\\\Steam\" } \"1\" { \"path\" \"\(second.path)\" } }")
        try write("prefix/drive_c/Steam/steamapps/appmanifest_100.acf", manifest("100", flags: 6, download: 200, downloaded: 100))
        let update = try write("Second Library/steamapps/appmanifest_200.acf", manifest("200", flags: 2, download: 100, downloaded: 100, stage: 300, staged: 150))
        let before = try Data(contentsOf: update)
        var scan = SteamLibrary.scan(steamExecutable: steam, prefix: root.appendingPathComponent("prefix"))
        XCTAssertEqual(scan.games.map(\.appID), ["100"])
        XCTAssertEqual(scan.games.first?.requiresUpdate, true)
        XCTAssertEqual(scan.transfers.count, 2)
        XCTAssertTrue(scan.transfers.allSatisfy { $0.client == .windows })
        XCTAssertEqual(scan.transfers.last?.phase, .install)
        XCTAssertEqual(scan.transfers.last?.progress, 0.5)
        XCTAssertEqual(try Data(contentsOf: update), before)
        try manifest("200", flags: 4, download: 100, downloaded: 100, stage: 300, staged: 300).write(to: update, atomically: true, encoding: .utf8)
        scan = SteamLibrary.scan(steamExecutable: steam, prefix: root.appendingPathComponent("prefix"))
        XCTAssertEqual(scan.transfers.map(\.appID), ["100"])
        XCTAssertEqual(scan.games.map(\.appID), ["100", "200"])
    }

    func testUnknownOrInvalidCountersDoNotProduceNaNOrInventTransferProgress() throws {
        let state = try VDFParser.parse("\"AppState\" { \"appid\" \"123\" \"name\" \"Game\" \"StateFlags\" \"2\" \"BytesDownloaded\" \"-1\" \"BytesToDownload\" \"bad\" }")["AppState"]!
        let transfer = try XCTUnwrap(SteamTransfer.from(state: state, library: root, artwork: nil, client: .windows))
        XCTAssertEqual(transfer.downloaded, 0)
        XCTAssertEqual(transfer.phase, .pending)
        XCTAssertNil(transfer.progress)
        let waiting = try VDFParser.parse(manifest("124", flags: 2, download: 100, downloaded: 200))["AppState"]!
        XCTAssertNil(SteamTransfer.from(state: waiting, library: root, artwork: nil, client: .windows)?.progress)
    }
}

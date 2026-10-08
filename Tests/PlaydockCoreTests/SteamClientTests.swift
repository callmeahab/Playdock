import XCTest
@testable import PlaydockCore

final class SteamClientTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockSteamClient-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func write(_ path: String, _ text: String = "", executable: Bool = false, installedApplication: Bool = true) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        if installedApplication, file.pathExtension == "acf", let state = try? VDFParser.parse(text)["AppState"], let directory = state["installdir"]?.string {
            try application(file.deletingLastPathComponent().appendingPathComponent("common/" + directory))
        }
        return file
    }
    private func application(_ directory: URL) throws {
        let contents = directory.appendingPathComponent("Game.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = ["CFBundleExecutable": "Game", "CFBundleIdentifier": "test.playdock.fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Game")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func manifest(_ id: String, flags: UInt, download: UInt64 = 0, downloaded: UInt64 = 0, stage: UInt64 = 0, staged: UInt64 = 0) -> String {
        "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"Game \(id)\" \"StateFlags\" \"\(flags)\" \"installdir\" \"Game\(id)\" \"BytesToDownload\" \"\(download)\" \"BytesDownloaded\" \"\(downloaded)\" \"BytesToStage\" \"\(stage)\" \"BytesStaged\" \"\(staged)\" }"
    }

    private final class ScanSnapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SteamLibraryScan] = []
        func append(_ snapshot: SteamLibraryScan) -> Bool {
            lock.lock(); defer { lock.unlock() }
            values.append(snapshot)
            return values.count == 1
        }
        var snapshots: [SteamLibraryScan] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    func testStreamingShowsGamesBeforeLaterLibrariesAreScanned() throws {
        let steam = root.appendingPathComponent("Steam")
        let second = root.appendingPathComponent("Second Library")
        try write("Steam/steamapps/libraryfolders.vdf", "\"libraryfolders\" { \"1\" { \"path\" \"\(second.path)\" } }")
        try write("Steam/steamapps/appmanifest_100.acf", manifest("100", flags: 6, download: 100, downloaded: 25))
        try write("Steam/steamapps/appmanifest_101.acf", manifest("101", flags: 4))
        try write("Second Library/steamapps/appmanifest_999.acf", "invalid {")
        let laterManifest = second.appendingPathComponent("steamapps/appmanifest_200.acf")
        try application(second.appendingPathComponent("steamapps/common/Game200"))
        let laterData = Data(manifest("200", flags: 4).utf8)
        let collector = ScanSnapshots()
        let final = SteamLibrary.scan(root: steam) { snapshot in
            // Create a file after the first update to verify incremental enumeration.
            if collector.append(snapshot) { try? laterData.write(to: laterManifest) }
        }
        let first = try XCTUnwrap(collector.snapshots.first)
        XCTAssertEqual(first.games.map(\.appID), ["100"])
        XCTAssertTrue(first.warnings.isEmpty)
        XCTAssertEqual(first.transfers.first?.progress, 0.25)
        XCTAssertEqual(final.games.map(\.appID), ["100", "101", "200"])
        XCTAssertEqual(final.warnings.count, 1)
        XCTAssertEqual(final.transfers, first.transfers)
        let ordinary = SteamLibrary.scan(root: steam)
        XCTAssertEqual(final.games, ordinary.games)
        XCTAssertEqual(final.warnings, ordinary.warnings)
    }

    func testEmptyMacStreamPublishesAnEmptyFinalSnapshot() async {
        var snapshots: [SteamLibraryScan] = []
        for await snapshot in SteamLibrary.updates(root: root.appendingPathComponent("AbsentSteam")) { snapshots.append(snapshot) }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].games.isEmpty)
        XCTAssertTrue(snapshots[0].warnings.isEmpty)
        XCTAssertTrue(snapshots[0].transfers.isEmpty)
    }

    func testCancelledScanDoesNotPublishOrReadInstalledGames() async throws {
        let steam = root.appendingPathComponent("Steam")
        try write("Steam/steamapps/appmanifest_100.acf", manifest("100", flags: 4))
        let collector = ScanSnapshots()
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return SteamLibrary.scan(root: steam) { _ = collector.append($0) }
        }.value
        XCTAssertTrue(result.games.isEmpty)
        XCTAssertTrue(collector.snapshots.isEmpty)
    }

    func testTransferScanDoesNotTurnPartialMacDownloadsIntoPlayableOrLicensedGames() throws {
        try write("Steam/steamapps/appmanifest_100.acf", manifest("100", flags: 2, download: 100, downloaded: 25), installedApplication: false)
        try write("Steam/steamapps/appmanifest_101.acf", manifest("101", flags: 4, download: 100, downloaded: 0), installedApplication: false)
        try write("Steam/steamapps/appmanifest_102.acf", manifest("102", flags: 1), installedApplication: false)
        try write("Steam/steamapps/appmanifest_0.acf", manifest("0", flags: 2), installedApplication: false)
        try write("Steam/steamapps/appmanifest_228980.acf", manifest("228980", flags: 2), installedApplication: false)
        let scan = SteamLibrary.scanMac(root: root.appendingPathComponent("Steam"))
        XCTAssertTrue(scan.games.isEmpty)
        XCTAssertEqual(scan.transfers.map(\.appID), ["100"])
        XCTAssertEqual(scan.transfers.first?.client, .macOS)
        XCTAssertEqual(scan.transfers.first?.progress, 0.25)
    }

    func testSharedSteamTransfersUseMacLibrariesAndUpdateWithoutWritingSteamFiles() throws {
        let steam = root.appendingPathComponent("Steam")
        let second = root.appendingPathComponent("Second Library")
        try write("Steam/steamapps/libraryfolders.vdf", "\"libraryfolders\" { \"0\" { \"path\" \"\(steam.path)\" } \"1\" { \"path\" \"\(second.path)\" } }")
        try write("Steam/steamapps/appmanifest_100.acf", manifest("100", flags: 6, download: 200, downloaded: 100))
        let update = try write("Second Library/steamapps/appmanifest_200.acf", manifest("200", flags: 2, download: 100, downloaded: 100, stage: 300, staged: 150))
        let before = try Data(contentsOf: update)
        var scan = SteamLibrary.scan(root: steam)
        XCTAssertEqual(scan.games.map(\.appID), ["100"])
        XCTAssertEqual(scan.games.first?.requiresUpdate, true)
        XCTAssertEqual(scan.transfers.count, 2)
        XCTAssertTrue(scan.transfers.allSatisfy { $0.client == .macOS })
        XCTAssertEqual(scan.transfers.last?.phase, .install)
        XCTAssertEqual(scan.transfers.last?.progress, 0.5)
        XCTAssertEqual(try Data(contentsOf: update), before)
        try manifest("200", flags: 4, download: 100, downloaded: 100, stage: 300, staged: 300).write(to: update, atomically: true, encoding: .utf8)
        scan = SteamLibrary.scan(root: steam)
        XCTAssertEqual(scan.transfers.map(\.appID), ["100"])
        XCTAssertEqual(scan.games.map(\.appID), ["100", "200"])
    }

    func testUnknownOrInvalidCountersDoNotProduceNaNOrInventTransferProgress() throws {
        let state = try VDFParser.parse("\"AppState\" { \"appid\" \"123\" \"name\" \"Game\" \"StateFlags\" \"2\" \"BytesDownloaded\" \"-1\" \"BytesToDownload\" \"bad\" }")["AppState"]!
        let transfer = try XCTUnwrap(SteamTransfer.from(state: state, library: root, artwork: nil, client: .macOS))
        XCTAssertEqual(transfer.downloaded, 0)
        XCTAssertEqual(transfer.phase, .pending)
        XCTAssertNil(transfer.progress)
        let waiting = try VDFParser.parse(manifest("124", flags: 2, download: 100, downloaded: 200))["AppState"]!
        XCTAssertNil(SteamTransfer.from(state: waiting, library: root, artwork: nil, client: .macOS)?.progress)
    }
}

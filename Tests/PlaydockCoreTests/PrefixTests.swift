import XCTest
@testable import PlaydockCore

final class PrefixTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydockPrefixes-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ file: URL, data: Data = Data(), executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
    }
    private func bridge(arm: Bool, machine: UInt16) throws -> RuntimeProfile {
        let runner = root.appendingPathComponent("runner")
        let loader = runner.appendingPathComponent(arm ? "lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine" : "lib/wine/x86_64-unix/wine")
        try write(loader, executable: true)
        try write(runner.appendingPathComponent(arm ? "bin/wineserver-arm64" : "bin/wineserver-x86"), executable: true)
        let prefix = root.appendingPathComponent("External Steam Library/steamapps/compatdata/10/pfx")
        try write(prefix.appendingPathComponent("system.reg"))
        var pe = Data(repeating: 0, count: 128)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 64
        pe[64] = 0x50; pe[65] = 0x45; pe[68] = UInt8(machine & 0xff); pe[69] = UInt8(machine >> 8)
        try write(prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll"), data: pe)
        var profile = RuntimeProfile(runtime: RuntimeInstallation(kind: .crossOver, executable: runner.appendingPathComponent("bin/wine")), prefix: prefix, name: "Steam game")
        profile.nativeSteamBridge = true
        return profile
    }
    func testFEXToolsUseTheGamePrefixAndItsExistingSynchronizationMode() throws {
        let profile = try bridge(arm: true, machine: 0xaa64)
        try write(profile.prefix.deletingLastPathComponent().appendingPathComponent("playdock-msync"), data: Data("1".utf8))
        let command = try PrefixCommandBuilder.command(.configuration, profile: profile)
        XCTAssertTrue(command.executable.path.hasSuffix("aarch64-unix/wine.app/Contents/MacOS/wine"))
        XCTAssertEqual(command.environment["WINEPREFIX"], profile.prefix.path)
        XCTAssertEqual(command.environment["WINEMSYNC"], "1")
        XCTAssertEqual(command.arguments, ["winecfg.exe"])
        XCTAssertTrue(command.environment["WINESERVER"]!.hasSuffix("wineserver-arm64"))
    }
    func testX86RunnerCanOpenRegistryWithoutStartingSteamOrTheGame() throws {
        let profile = try bridge(arm: false, machine: 0x8664)
        let command = try PrefixCommandBuilder.command(.registry, profile: profile)
        XCTAssertTrue(command.executable.path.hasSuffix("x86_64-unix/wine"))
        XCTAssertEqual(command.arguments, ["regedit.exe"])
        XCTAssertEqual(command.environment["WINEMSYNC"], "0")
        XCTAssertTrue(command.environment["WINESERVER"]!.hasSuffix("wineserver-x86"))
    }
    func testForeignArchitectureAndUninitializedPrefixesAreRejectedWithoutMutation() throws {
        var profile = try bridge(arm: true, machine: 0x8664)
        let registry = profile.prefix.appendingPathComponent("system.reg")
        let before = try Data(contentsOf: registry)
        XCTAssertThrowsError(try PrefixCommandBuilder.command(.configuration, profile: profile))
        XCTAssertEqual(try Data(contentsOf: registry), before)
        profile.prefix = root.appendingPathComponent("not-created")
        XCTAssertThrowsError(try PrefixCommandBuilder.command(.registry, profile: profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.prefix.path))
    }
    func testPrefixInspectorFindsFilesInTheActualExternalSteamLibrary() async throws {
        let profile = try bridge(arm: true, machine: 0xaa64)
        let user = profile.prefix.appendingPathComponent("drive_c/users/steamuser")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let log = profile.prefix.deletingLastPathComponent().appendingPathComponent("playdock-run.log")
        try write(log)
        let snapshot = await GamePrefixService().snapshot(profile)
        XCTAssertTrue(snapshot.exists); XCTAssertTrue(snapshot.initialized)
        XCTAssertEqual(snapshot.prefix, profile.prefix)
        XCTAssertEqual(snapshot.userFiles?.path, user.path); XCTAssertEqual(snapshot.log, log)
        let steam = SteamGame(appID: "10", name: "Test", library: root.appendingPathComponent("External Steam Library"), artwork: nil, lastPlayed: 0)
        XCTAssertEqual(steam.bridgePrefix, profile.prefix)
    }
    func testCrossOverToolsUseTheirBottleWithoutOtherGamesLaunchArguments() throws {
        let wine = root.appendingPathComponent("CrossOver/bin/wine"), prefix = root.appendingPathComponent("bottles/My Game")
        try write(wine, executable: true); try write(prefix.appendingPathComponent("system.reg")); try write(prefix.appendingPathComponent("cxbottle.conf"))
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        let profile = RuntimeProfile(runtime: RuntimeInstallation(kind: .crossOver, executable: wine), prefix: prefix, name: "My Game")
        let command = try PrefixCommandBuilder.command(.registry, profile: profile)
        XCTAssertEqual(command.arguments, ["--bottle", "My Game", "--wait-children", "--cx-app", "regedit.exe"])
        XCTAssertEqual(command.environment["CX_BOTTLE_PATH"], prefix.deletingLastPathComponent().path)
    }
}
